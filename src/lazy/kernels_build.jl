# Building the compiled closure kernel (phase-4 spec §3.2-3.3; ADR-0003 rule 12): a stage and a
# probe frame (the morsels' names and column types) become a `StageProgram`. The blocks, the row
# loop, `StageProgram` and the decision are in kernels.jl. Like `render_kernel` (render.jl), the
# builder walks the stage step by step over the columns' names and types; here each node becomes
# a callable block instead of an expression. The shape keys and the cache setters follow.

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

# §3.2's whitelist of steps and nodes, checked from the stage's structure alone (no schema, no
# shape key, no hash): the steps and nodes `_bstep!`/`_checktypes` can build. A stage that fails
# it never compiles, so `_decide` rejects it before it computes a shape key or hash, or touches
# the cache (p4-join review m5: a `ProbeStep` carries its build table, so its key would be new
# on every `collect`). The type checks (static types, the probe check) still need the schema.
# Each returns `nothing` when on the whitelist, else why not (the builder's own wording).
_wlnode(::Col) = nothing
_wlnode(x::Lit) = x.scalar ? nothing : "a vector literal"
_wlnode(x::Call) = _wlfirst(_wlnode, x.args)
_wlvalue(v) = (v isa Col || (v isa Lit && v.scalar)) ? nothing :
    "case_when values must be columns or scalar literals, got $(v)"
_wlnode(x::CaseWhen) = something(_wlfirst(_wlnode, x.conds), _wlfirst(_wlvalue, x.vals), _wlvalue(x.default), Some(nothing))
_wlnode(x) = "$(nameof(typeof(x))) nodes do not compile: $(x)"
function _wlout(o)
    o isa Pair || return "mutate with across"
    o.second === nothing && return nothing
    o.second isa Node || return "mutate output $(o.first) is not an expression"
    return _wlnode(o.second)
end
_wlstep(s::FilterStep) = _wlfirst(_wlnode, s.preds)
_wlstep(s::MutateStep) = (s.by === nothing && s.keep === :all) ? _wlfirst(_wlout, s.outs) : "mutate with by or keep"
_wlstep(s::SelectStep) = _wlfirst(it -> it isa Pair ? _wlnode(it.second) : nothing, s.items)
_wlstep(::Union{RenameStep, RenameWithStep, RelocateStep}) = nothing
_wlstep(s) = "$(nameof(typeof(s))) is not on the kernel whitelist (spec §3.2)"
# the first non-`nothing` reason of `f` over `xs`
function _wlfirst(f, xs)
    for x in xs
        r = f(x)
        r === nothing || return r
    end
    return nothing
end
"Why `stage` is off §3.2's whitelist (the first offending step or node), or `nothing`."
_offwhitelist(stage) = _wlfirst(_wlstep, stage)

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

# ---------------------------------------------------------------------------------------------
# Shapes, cache keys and the stage size (the cache itself is in kernels.jl)

# A shape is a `String`, so a new shape compiles no new `hash`/`isequal` methods (a tuple of the
# nodes' functions would be a new tuple type per shape). A function or value is keyed by its
# type's `objectid` and its `hash` (a singleton function: one per type; `WhenFold`: its fields;
# a selector: its contents); a literal by its type only.
_vkey(io::IO, @nospecialize(x)) = print(io, objectid(typeof(x)), '#', hash(x), ';')
# Names are printed with `repr` (`Symbol("a;c:b")`, quoted), so no name can mimic the key syntax.
_skey(io::IO, x::Col) = print(io, "c:", repr(x.name), ';')
_skey(io::IO, x::Lit) = print(io, "l:", objectid(typeof(x.value)), x.scalar ? 's' : 'v', ';')
function _skey(io::IO, x::Call)
    print(io, "f:")
    _vkey(io, x.f)
    print(io, '(')
    foreach(a -> _skey(io, a), x.args)
    return print(io, ')')
end
function _skey(io::IO, x::CaseWhen)
    print(io, "w(")
    foreach(a -> _skey(io, a), x.conds)
    print(io, '|')
    foreach(a -> _skey(io, a), x.vals)
    print(io, '|')
    _skey(io, x.default)
    return print(io, ')')
end
_skey(io::IO, @nospecialize(x)) = (print(io, "v:"); _vkey(io, x))
function _okey(io::IO, @nospecialize(o))
    if o isa Pair
        print(io, repr(o.first), '=')
        o.second === nothing ? print(io, "nothing;") : _skey(io, o.second)
    else
        _skey(io, o)
    end
    return nothing
end
function _stepkey(io::IO, s::FilterStep)
    print(io, s.out ? "filter_out[" : "filter[")
    foreach(p -> _skey(io, p), s.preds)
    return print(io, ']')
end
function _stepkey(io::IO, s::MutateStep)
    print(io, "mutate[")
    foreach(o -> _okey(io, o), s.outs)
    foreach(v -> _vkey(io, v), (s.by, s.keep, s.before, s.after))
    return print(io, ']')
end
function _stepkey(io::IO, s::SelectStep)
    print(io, "select[")
    foreach(it -> _okey(io, it), s.items)
    return print(io, ']')
end
_stepkey(io::IO, s::Step) = (print(io, nameof(typeof(s)), '['); _vkey(io, _stepvalue(s)); print(io, ']'))
_stepvalue(s::RenameStep) = s.pairs
_stepvalue(s::RenameWithStep) = (s.fn, s.sel)
_stepvalue(s::RelocateStep) = (s.sels, s.before, s.after)
_stepvalue(s::Step) = s
_stageshape(stage) = sprint(io -> foreach(s -> _stepkey(io, s), stage))

_decision_key(stage, probe::Frame) =
    (:decision, _stageshape(stage), copy(probe.names), Any[eltype(c) for c in probe.columns])
_morsel_key(shape::String, f::Frame) = (shape, copy(f.names), Any[typeof(c) for c in f.columns])

function _small_set!(ph, verdict::Bool)
    h = _shapehash(ph)
    lock(_KERNEL_LOCK) do
        length(_KERNEL_SMALL) >= _KERNEL_CACHE_MAX && empty!(_KERNEL_SMALL)
        _KERNEL_SMALL[h] = verdict
        verdict && (_KERNEL_ANY_COMPILED[] = true)
    end
    return verdict
end

# The shape (as `_stageshape`, literal values left out), the projection and, for a frame source,
# its column names and kinds; for any other source its type and declared schema (codegen review
# n1: without them a verdict cached for one source's types showed as "compiled (cached)" for
# another source with the same stage and other column types). Hashed into one accumulator. The
# helpers return `nothing`, so the dynamic dispatch over steps and nodes boxes no `UInt` (the
# lazy `n=10` rows count allocations).
mutable struct _HAcc
    h::UInt
end
function _shapehash(ph)
    acc = _HAcc(hash(:chui_kernel_shape))
    for s in ph.stage
        _hstep!(acc, s)
    end
    acc.h = hash(ph.scan.select, acc.h)
    src = ph.scan.source
    if src isa FrameSource
        for (n, col) in zip(src.frame.names, src.frame.columns)
            acc.h = hash(typeof(col), hash(n, acc.h))
        end
    else
        _hmix!(acc, typeof(src))
        _hschema!(acc, src)
    end
    return acc.h
end
_hmix!(acc::_HAcc, x::Union{Symbol, Bool, DataType}) = (acc.h = hash(x, acc.h); nothing)
# a non-frame source's declared column names and element types (none when it reports no schema)
function _hschema!(acc::_HAcc, src)
    sch = try
        source_schema(src)
    catch err
        err isa InterruptException && rethrow()
        nothing
    end
    if sch isa Tables.Schema
        for (n, T) in zip(sch.names, sch.types)
            acc.h = hash(T, hash(n, acc.h))
        end
    else
        _hmix!(acc, :noschema)
    end
    return nothing
end
# a value of unknown type (a selector, a `before`/`after`): `nothing` without a dynamic call
_hany!(acc::_HAcc, @nospecialize(x)) = (acc.h = x === nothing ? hash(:nothing, acc.h) : hash(x, acc.h)::UInt; nothing)
_hnode!(acc::_HAcc, x::Col) = (_hmix!(acc, :c); _hmix!(acc, x.name))
_hnode!(acc::_HAcc, x::Lit) = (_hmix!(acc, :l); _hmix!(acc, x.scalar); _hmix!(acc, typeof(x.value)))
function _hnode!(acc::_HAcc, x::Call)
    _hmix!(acc, :f)
    acc.h = hash(x.f, acc.h)
    for a in x.args
        _hnode!(acc, a)
    end
    return _hmix!(acc, :end)
end
function _hnode!(acc::_HAcc, x::CaseWhen)
    _hmix!(acc, :w)
    for a in x.conds
        _hnode!(acc, a)
    end
    for a in x.vals
        _hnode!(acc, a)
    end
    _hnode!(acc, x.default)
    return _hmix!(acc, :end)
end
_hnode!(acc::_HAcc, @nospecialize(x)) = (_hmix!(acc, :v); _hany!(acc, x))
function _hout!(acc::_HAcc, o::Pair)
    _hmix!(acc, o.first::Symbol)
    o.second === nothing ? _hmix!(acc, :nothing) : _hnode!(acc, o.second)
    return nothing
end
_hout!(acc::_HAcc, @nospecialize(o)) = _hany!(acc, o)
function _hstep!(acc::_HAcc, s::FilterStep)
    _hmix!(acc, :filter)
    _hmix!(acc, s.out)
    for p in s.preds
        _hnode!(acc, p)
    end
    return nothing
end
function _hstep!(acc::_HAcc, s::MutateStep)
    _hmix!(acc, :mutate)
    for o in s.outs
        _hout!(acc, o)
    end
    _hany!(acc, s.by)
    _hmix!(acc, s.keep)
    _hany!(acc, s.before)
    _hany!(acc, s.after)
    return nothing
end
function _hstep!(acc::_HAcc, s::SelectStep)
    _hmix!(acc, :select)
    for it in s.items
        _hout!(acc, it)
    end
    return nothing
end
_hstep!(acc::_HAcc, s::Step) = (_hmix!(acc, nameof(typeof(s))); _hany!(acc, _stepvalue(s)))

function _cache_set!(key, verdict::Bool)
    lock(_KERNEL_LOCK) do
        length(_KERNEL_CACHE) >= _KERNEL_CACHE_MAX && empty!(_KERNEL_CACHE)
        _KERNEL_CACHE[key] = verdict
    end
    return verdict
end

# Expression nodes = operations (Call and case_when nodes); columns and literals are leaves.
_nodes(x::Union{Col, Lit}) = 0
_nodes(x::Call) = 1 + sum(_nodes, x.args; init = 0)
_nodes(x::CaseWhen) = 1 + sum(_nodes, x.conds; init = 0) + sum(_nodes, x.vals; init = 0) + _nodes(x.default)
_nodes(::Any) = 1
_stepnodes(s::FilterStep) = sum(_nodes, s.preds; init = 0)
_stepnodes(s::MutateStep) = sum(o -> o isa Pair && o.second isa Node ? _nodes(o.second) : 0, s.outs; init = 0)
_stepnodes(s::SelectStep) = sum(it -> it isa Pair ? _nodes(it.second) : 0, s.items; init = 0)
_stepnodes(::Step) = 0
_stage_nodes(stage) = sum(_stepnodes, stage; init = 0)
