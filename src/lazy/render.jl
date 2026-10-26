# The rendered kernel (spec §7; ADR-0003 rule 13): the streamed stage as a Julia function
# expression over one partition's columns (a NamedTuple of vectors). `code_lowered(q)` lowers it
# with `Meta.lower`. It is rendered for reading; the engine runs the interpreter or a compiled
# closure kernel (kernels.jl), whose own lowered code is the same generic loop for every plan.
# Property tests evaluate it in the test process and check it against the interpreter and the
# compiled kernel.

# Nodes the renderer spells out; anything else is evaluated through the interpreter.
_rnode(x::Col) = :(cols.$(x.name))
_rnode(x::Lit) = x.scalar ? (x.value isa Symbol ? QuoteNode(x.value) : x.value) : _rinterp(x)
_rnode(x::Call) = Expr(:call, :broadcast, x.f, (_rnode(a) for a in x.args)...)
_rnode(x::Node) = _rinterp(x)
_rinterp(x::Node) = :($(GlobalRef(@__MODULE__, :_evalnode))($(QuoteNode(x)), cols))

"`_evalnode(x, cols)`: node `x` over the columns `cols` (a NamedTuple), one value per row."
_evalnode(x::Node, cols::NamedTuple) = (f = Frame(cols); eval_column(x, Env(f), nothing))

const _FIT = GlobalRef(@__MODULE__, :_fitrows)
"Recycle a scalar result to `n` rows (as `mutate` does)."
_fitrows(v::AbstractVector, n::Int) = v
_fitrows(v, n::Int) = fill(v, n)

# Each method appends the step's code to `body`; `probe` is an empty frame with the step's input
# names and types (for selector resolution).
function _rstep!(body, s::FilterStep, probe::Frame)
    ps = [_rnode(p) for p in s.preds]
    for (k, p) in enumerate(ps)
        push!(body, :($(Symbol(:p, k)) = $(_FIT)($p, n)))
    end
    mask = GlobalRef(@__MODULE__, s.out ? :_notalltrue : :_alltrue)
    push!(body, Expr(:(=), :keep, Expr(:call, mask, (Symbol(:p, k) for k in eachindex(ps))...)))
    push!(body, :(cols = $(GlobalRef(@__MODULE__, :_keeprows))(cols, keep)))
    push!(body, :(n = count(keep)))
    return body
end

"Rows where every condition is exactly `true` (a filter; `missing` and `false` drop the row)."
_alltrue(ps::AbstractVector...) = BitVector(all(p -> p[i] === true, ps) for i in eachindex(first(ps)))
"Rows where the conditions are not all `true` (a `filter_out`)."
_notalltrue(ps::AbstractVector...) = .!_alltrue(ps...)
"The rows `keep` of every column."
_keeprows(cols::NamedTuple, keep::BitVector) = map(v -> v[keep], cols)
"`cols` without column `nm` (`mutate(nm = nothing)`)."
function _dropcol(cols::NamedTuple, nm::Symbol)
    ks = Tuple(k for k in keys(cols) if k !== nm)
    return NamedTuple{ks}(Tuple(cols[k] for k in ks))
end
"The row count of a partition's columns."
_nrows(cols::NamedTuple) = isempty(cols) ? 0 : length(first(cols))
function _rstep!(body, s::MutateStep, probe::Frame)
    for o in s.outs
        nm = o.first
        if o.second === nothing
            push!(body, :(cols = $(GlobalRef(@__MODULE__, :_dropcol))(cols, $(QuoteNode(nm)))))
        else
            push!(body, :(cols = merge(cols, NamedTuple{($(QuoteNode(nm)),)}(($(_FIT)($(_rnode(o.second)), n),)))))
        end
    end
    return body
end
function _rstep!(body, s::SelectStep, probe::Frame)
    outs = Symbol[]
    vals = Any[]
    for it in s.items
        if it isa Pair
            push!(outs, it.first)
            push!(vals, :($(_FIT)($(_rnode(it.second)), n)))
        else
            for i in resolve(it, probe)
                nm = probe.names[i]
                nm in outs && continue
                push!(outs, nm)
                push!(vals, :(cols.$nm))
            end
        end
    end
    push!(body, :(cols = NamedTuple{$(Tuple(outs))}(($(vals...),))))
    return body
end
function _rstep!(body, s::Step, probe::Frame)       # rename, rename_with, relocate
    m = name_map(s, probe.names, _coltypes(probe))
    m === nothing && throw(ArgumentError("cannot render $(s)"))
    outs = Tuple(p.first for p in m)
    push!(body, :(cols = NamedTuple{$outs}(($((:(cols.$(p.second)) for p in m)...),))))
    return body
end

"""
    render_kernel(ph::Physical) -> Union{Nothing, Expr}

The streamed stage of `ph` as `cols -> (…; cols)`: the scan's predicates, then each step, over
a NamedTuple of column vectors. `nothing` when there is no stage, or when a step cannot be
rendered on the declared schema.
"""
function render_kernel(ph::Physical)
    scan = ph.scan
    steps = Step[]
    isempty(scan.preds) || push!(steps, FilterStep(scan.preds, false))
    append!(steps, ph.stage)
    isempty(steps) && return nothing
    sch = source_schema(scan.source)
    probe = apply_scan(empty_frame(sch), scan.select === nothing ? Tables.Scan() : Tables.Scan(; select = scan.select))
    body = Any[:(n = $(GlobalRef(@__MODULE__, :_nrows))(cols))]
    try
        for s in steps
            _rstep!(body, s, probe)
            probe = apply(s, probe)
        end
    catch
        return nothing
    end
    push!(body, :cols)
    return Expr(:->, :cols, Expr(:block, body...))
end

"The lowered code (`CodeInfo`) of a rendered kernel's body, `cols` bound to the partition."
function lower_kernel(ex::Expr)
    body = ex.args[2]
    th = Meta.lower(@__MODULE__, Expr(:let, Expr(:(=), :cols, :partition), body))
    return th isa Expr && th.head === :thunk ? th.args[1] : th
end

# =============================================================================================
# Building the compiled closure kernel (spec §3.2-3.3; its blocks, row loop and `StageProgram`
# are in kernels.jl). Like `render_kernel`, it walks the stage step by step over the columns'
# names and types; here each node becomes a callable block instead of an expression. (In this
# file because kernels.jl is at the `src/*.jl` size ratchet.)

mutable struct _Builder
    probe::Frame
    ins::Vector{Int}
    regtypes::Vector{Type}
    scalars::Vector{Any}
    ops::Vector{Any}
    hasfilter::Bool
end

# A state: the current columns, each `(:in, position in the morsel)` or `(:reg, register)`.
const _Slot = Tuple{Symbol, Int}

_slottype(b::_Builder, s::_Slot) = s[1] === :in ? eltype(b.probe.columns[s[2]]) : b.regtypes[s[2]]
_ctx(b::_Builder, names, slots) = SelectCtx(copy(names), Type[_slottype(b, s) for s in slots], Symbol[])

function _injidx(b::_Builder, pos::Int)
    j = findfirst(==(pos), b.ins)
    j === nothing || return j
    push!(b.ins, pos)
    return length(b.ins)
end

# The element type is concrete, or `Union{Missing, T}` with `T` concrete.
_okT(T) = T !== Any && T !== Union{} && isconcretetype(nonmissingtype(T)) &&
    (T === nonmissingtype(T) || T == Union{Missing, nonmissingtype(T)})
# A register's values become `column(values)`; downstream they are read back as the values
# themselves, so the column's element type must be the register's (not so for strings: a
# `String` value comes back as a `StrView`).
_okreg(T) = _okT(T) && eltype(column(Vector{T}())) === T

_isscalar(x::Lit) = x.scalar
_isscalar(x::Call) = all(_isscalar, x.args)
_isscalar(::Any) = false

# Check every Call and CaseWhen node's static type (§3.2) and build the row callable.
function _knode(b::_Builder, x::Node, env::Dict{Symbol, _Slot}, ctx::SelectCtx)
    _checktypes(x, ctx)
    return _kbuild(b, x, env, ctx)
end
_checktypes(::Union{Col, Lit}, ::SelectCtx) = nothing
function _checktypes(x::Call, ctx::SelectCtx)
    _okT(static_type(x, ctx)) || throw(_NotCompilable("$(x) has no concrete static type"))
    foreach(a -> _checktypes(a, ctx), x.args)
    return nothing
end
function _checktypes(x::CaseWhen, ctx::SelectCtx)
    _okT(static_type(x, ctx)) || throw(_NotCompilable("$(x) has no concrete static type"))
    # values are read with their exact column types (a computed value's runtime type can differ)
    for v in Any[x.vals; x.default]
        v isa Col || (v isa Lit && v.scalar) ||
            throw(_NotCompilable("case_when values must be columns or scalar literals, got $(v)"))
    end
    foreach(a -> _checktypes(a, ctx), x.conds)
    return nothing
end
_checktypes(x::Node, ::SelectCtx) = throw(_NotCompilable("$(nameof(typeof(x))) nodes do not compile: $(x)"))

function _kbuild(b::_Builder, x::Col, env, ctx)
    s = get(env, x.name, nothing)
    s === nothing && throw(_NotCompilable("no column $(repr(x.name))"))
    return s[1] === :in ? KCol{_injidx(b, s[2])}() : KReg{s[2]}()
end
_kbuild(b::_Builder, x::Lit, env, ctx) = x.scalar ? KLit(x.value) : throw(_NotCompilable("a vector literal"))
function _kbuild(b::_Builder, x::Call, env, ctx)
    if _isscalar(x)            # the interpreter evaluates it once per call
        push!(b.scalars, _kscalar(x))
        return KSc{length(b.scalars)}()
    end
    return _kcall(x.f, Tuple(Any[_kbuild(b, a, env, ctx) for a in x.args]))
end
function _kbuild(b::_Builder, x::CaseWhen, env, ctx)
    E = static_type(x, ctx)
    conds = Tuple(Any[_kbuild(b, a, env, ctx) for a in x.conds])
    vals = Tuple(Any[_kbuild(b, a, env, ctx) for a in x.vals])
    return KCase{E}(conds, vals, _kbuild(b, x.default, env, ctx))
end
_kscalar(x::Lit) = KLit(x.value)
_kscalar(x::Call) = _kcall(x.f, Tuple(Any[_kscalar(a) for a in x.args]))
# The building blocks are built from `Vector{Any}`s and unspecialised constructors, so a new
# shape compiles only the blocks' own (tiny) constructors and the row loop, not the builder.
_kcall(@nospecialize(f), @nospecialize(args::Tuple)) = KCall{typeof(f), typeof(args)}(f, args)

function _addreg!(b::_Builder, T, @nospecialize(x))
    push!(b.regtypes, T)
    k = length(b.regtypes)
    push!(b.ops, KMut{k}(x))
    return k
end

"""
    _build(stage, probe::Frame) -> StageProgram

Compile `stage` for morsels shaped like `probe` (names and column types), or throw
`_NotCompilable` (§3.2).
"""
function _build(stage, probe::Frame)
    b = _Builder(probe, Int[], Type[], Any[], Any[], false)
    names = copy(probe.names)
    slots = _Slot[(:in, j) for j in eachindex(names)]
    for s in stage
        names, slots = _bstep!(b, s, names, slots)
    end
    R = Tuple{b.regtypes...}
    ops = Tuple(b.ops)
    scs = Tuple(b.scalars)
    return StageProgram(ops, scs, R, b.ins, names, slots, b.hasfilter)
end

_env(names, slots) = Dict{Symbol, _Slot}(zip(names, slots))

function _bstep!(b::_Builder, s::FilterStep, names, slots)
    ctx = _ctx(b, names, slots)
    env = _env(names, slots)
    preds = Any[]
    for p in s.preds
        _isboolish(static_type(p, ctx)) || throw(_NotCompilable("the condition $(p) is not statically Bool"))
        push!(preds, _knode(b, p, env, ctx))
    end
    push!(b.ops, KFilt{s.out}(Tuple(preds)))
    b.hasfilter = true
    return names, slots
end

function _bstep!(b::_Builder, s::MutateStep, names, slots)
    (s.by === nothing && s.keep === :all) || throw(_NotCompilable("mutate with by or keep"))
    names = copy(names)
    slots = copy(slots)
    created = Symbol[]
    for o in s.outs
        o isa Pair || throw(_NotCompilable("mutate with across"))
        nm, x = o.first, o.second
        i = findfirst(==(nm), names)
        if x === nothing
            i === nothing || (deleteat!(names, i); deleteat!(slots, i))
            continue
        end
        x isa Node || throw(_NotCompilable("mutate output $(nm) is not an expression"))
        env = _env(names, slots)
        slot = if x isa Col          # the column itself, as `apply(::MutateStep)` keeps it
            sl = get(env, x.name, nothing)
            sl === nothing && throw(_NotCompilable("no column $(repr(x.name))"))
            sl
        else
            ctx = _ctx(b, names, slots)
            T = static_type(x, ctx)
            _okreg(T) || throw(_NotCompilable("mutate output $(nm) has static type $(T)"))
            (:reg, _addreg!(b, T, _knode(b, x, env, ctx)))
        end
        if i === nothing
            push!(names, nm)
            push!(slots, slot)
            push!(created, nm)
        else
            slots[i] = slot
        end
    end
    if (s.before !== nothing || s.after !== nothing) && !isempty(created)
        p = _stateprobe(b, names, slots)
        moving = [i for (i, n) in enumerate(p.names) if n in created]
        names, slots = _byidentity(p, _relocate(p, moving, s.before, s.after), slots)
    end
    return names, slots
end

function _bstep!(b::_Builder, s::SelectStep, names, slots)
    ctx = _ctx(b, names, slots)
    env = _env(names, slots)
    outnames = Symbol[]
    outslots = _Slot[]
    function add!(nm, sl)
        i = findfirst(==(nm), outnames)
        return if i === nothing
            push!(outnames, nm)
            push!(outslots, sl)
        else
            outslots[i] = sl
        end
    end
    for it in s.items
        if it isa Pair
            nm, x = it.first, it.second
            if x isa Col
                sl = get(env, x.name, nothing)
                sl === nothing && throw(_NotCompilable("no column $(repr(x.name))"))
                add!(nm, sl)
            else
                # `apply(::SelectStep)` builds `column(values)`: its element type is the values'
                # (a non-nullable one only when it is concrete)
                T = static_type(x, ctx)
                (isconcretetype(T) && _okreg(T)) || throw(_NotCompilable("select output $(nm) has static type $(T)"))
                add!(nm, (:reg, _addreg!(b, T, _knode(b, x, env, ctx))))
            end
        else
            for i in resolve(it, ctx)
                names[i] in outnames || add!(names[i], slots[i])
            end
        end
    end
    return outnames, outslots
end

function _bstep!(b::_Builder, s::Union{RenameStep, RenameWithStep, RelocateStep}, names, slots)
    m = name_map(s, copy(names), Type[_slottype(b, sl) for sl in slots])
    m === nothing && throw(_NotCompilable("$(s) does not apply to the stage's columns"))
    pos = Dict(zip(names, eachindex(names)))
    return Symbol[p.first for p in m], _Slot[slots[pos[p.second]] for p in m]
end

_bstep!(b::_Builder, s::Step, names, slots) = throw(_NotCompilable("$(nameof(typeof(s))) steps do not compile"))

# An empty frame with the state's names and types, every column a distinct object.
_stateprobe(b::_Builder, names, slots) =
    Frame(copy(names), AbstractColumn[column(Vector{_slottype(b, s)}()) for s in slots])
function _byidentity(p::Frame, q::Frame, slots)
    outslots = _Slot[]
    for col in q.columns
        i = findfirst(x -> x === col, p.columns)
        i === nothing && throw(_NotCompilable("cannot follow the columns through a relocation"))
        push!(outslots, slots[i])
    end
    return copy(q.names), outslots
end

# TTFX workload for the compiled stage kernels (kernels.jl; here because it needs the physical
# plan of execute.jl): the kernel machinery (the decision, the builder, the probe check, the
# guarded run, the output assembly) is compiled into the package image, so the first compiled
# kernel of a session pays only for its own shape (docs/research/codegen-phase4.md). The session
# cache is emptied afterwards: its keys hold `objectid`s, which differ between sessions.
@setup_workload begin
    nt = (x = [1.5, -0.0, NaN, 2.0], y = [1, 2, 3, 4], s = ["a", "b", "a", "c"])
    @compile_workload begin
        f = Frame(nt)
        ph = physical(mutate(z = c.x .* 2.0 .+ c.y)(filter(c.y .> 1)(lazy(f))).plan)
        kernel_decision(ph, 0)
        CompiledStage(ph)(f)
        lock(() -> empty!(_KERNEL_CACHE), _KERNEL_LOCK)
    end
end
