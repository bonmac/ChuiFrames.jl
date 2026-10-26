# Stage kernels (phase-4 spec §3; ADR-0003 rule 12). `stage_kernel(ph, est_rows)` returns the
# callable every morsel of the streamed stage runs through: a compiled kernel, or the
# interpreter. `kernel_decision` chooses, for `collect` and `explain` alike.
#
# A compiled kernel is a composition of small callable structs (closures with named types): one
# per expression node and one per step, their types encoding the stage's shape, literals held
# as fields (runtime values, so a new constant reuses the compiled code). One fused row loop
# runs the steps in order on each row: filters mark the row dead, mutate and select outputs are
# written to typed vectors allocated per call. No `eval`, `invokelatest`, `@generated` or
# RuntimeGeneratedFunctions: Julia compiles the row loop once per combination of these types.
#
# Exactness (critic B2, N3, n1, n2): the kernel computes every value the interpreter computes, on
# the same rows (no short-circuit: every filter conjunct, every case_when condition, value and
# default), and scalar-only subexpressions once per morsel even when no row is left. Output
# columns are built as the interpreter builds them, and a probe check compares `typeof(col)` per
# output column with the interpreter's once per compile. On an exception the morsel re-runs
# through the interpreter (its exception is the one raised), except `InterruptException`.

"The interpreter over the streamed stage of `ph`: each step through its eager operator."
interpret_stage(ph) = f -> _interpret(ph.stage, f)
function _interpret(stage, f)
    for s in stage
        f = apply(s, f)
    end
    return f
end

"""
Forcing switch for tests (spec §0.3), read once per `collect` by `stage_kernel`: `:auto`
(`kernel_decision`'s rules), `:compiled` (compile every compilable stage), `:interpreter`. Set
it only through the test helper `withforce`.
"""
const _FORCE_KERNEL = Ref{Symbol}(:auto)

"""
Morsels where the compiled kernel threw, the interpreter re-run succeeded and its result was
used: a kernel bug (spec §3.3, §7). Cumulative over the session: tests compare the value before
and after (critic n7).
"""
const _KERNEL_DISAGREE = Threads.Atomic{Int}(0)

"""
The session's kernel cache, guarded by `_KERNEL_LOCK`: `(shape, input names, column types)` →
whether the compiled kernel passed its probe check (`true`) or was rejected (`false`), and
`(:decision, shape, names, element types)` → the same verdict, for `kernel_decision`. The shape
holds every node's kind, function and literal type, never literal values.
"""
const _KERNEL_CACHE = Dict{Any, Any}()
const _KERNEL_LOCK = ReentrantLock()
const _KERNEL_CACHE_MAX = 4096

"""
Estimated rows from which a stage whose shape is not compiled yet is compiled at `collect`
(ADR-0003 rule 12): below it the interpreter runs. Set from docs/research/codegen-phase4.md
(compile time per new shape against the per-row saving, Julia 1.13 and 1.10).
"""
const INTERP_THRESHOLD = 100_000

"Stages with more expression nodes than this run the interpreter (ADR-0003 rule 12, EN-08)."
const MAX_KERNEL_NODES = 50

# ---------------------------------------------------------------------------------------------
# The decision

"""
    kernel_decision(ph::Physical, est_rows) -> (kind::Symbol, why::String)

`(:compiled | :interpreter, why)` for `ph`'s streamed stage, given the source's estimated row
count (`nothing`: unknown). Forced by `_FORCE_KERNEL`; otherwise a compilable stage (§3.2) is
compiled when its shape is in the session cache, or when `est_rows >= INTERP_THRESHOLD`.
"""
function kernel_decision(ph, est_rows::Union{Nothing, Integer})
    isempty(ph.stage) && return (:interpreter, "no streamed stage")
    force = _FORCE_KERNEL[]
    force === :interpreter && return (:interpreter, "forced")
    probe = _stage_probe(ph)
    probe === nothing && return (:interpreter, "the source schema is not known")
    why = _compile_check(ph.stage, probe)
    why === nothing || return (:interpreter, why)
    verdict = lock(() -> get(_KERNEL_CACHE, _decision_key(ph.stage, probe), nothing), _KERNEL_LOCK)
    if force === :compiled
        return (:compiled, verdict === true ? "cached" : "compiled at collect")
    end
    verdict === false && return (:interpreter, "the compiled kernel was rejected for this shape")
    verdict === true && return (:compiled, "cached")
    est_rows === nothing && return (:interpreter, "row count unknown and shape not compiled yet")
    est_rows < INTERP_THRESHOLD &&
        return (:interpreter, "estimated $(est_rows) rows < INTERP_THRESHOLD = $(INTERP_THRESHOLD) and shape not compiled yet")
    return (:compiled, "compiled at collect")
end

"""
    stage_kernel(ph::Physical, est_rows::Union{Nothing, Int}) -> callable

The kernel for `ph`'s streamed stage, given the source's estimated row count (`nothing`: not
reported). Each morsel `f::Frame` runs as `kernel(f)` after the engine's scan predicates.

The callable is shared by every task of a parallel run: it must be reentrant, allocating its
outputs per call (never buffers preallocated once per `stage_kernel` call). Its output column
types must equal the interpreter's on the same morsel, including an empty one (empty and pruned
morsels run through `interpret_stage`, in `_process_empty`).
"""
function stage_kernel(ph, est_rows::Union{Nothing, Int})
    kind, _ = kernel_decision(ph, est_rows)
    return kind === :compiled ? CompiledStage(ph) : interpret_stage(ph)
end

"""
`explain`'s kernel line for `ph`'s streamed stage, printed only when `kernel = true` (so the
default `explain` output does not depend on the session's kernel cache).
"""
function _explain_kernel(io::IO, ph; kernel::Bool = false)
    kernel || return nothing
    kind, why = kernel_decision(ph, _estimated_rows(ph.scan.source))
    println(io, "  kernel: ", kind === :compiled ? "compiled" : "interpreter", " (", why, ")")
    return nothing
end

# The stage's input on no rows, with the morsels' column kinds where the source fixes them (a
# frame's own empty slice, as `_process_empty`), else the declared schema.
function _stage_probe(ph)
    scan = ph.scan
    src = scan.source
    sel = scan.select === nothing ? Tables.Scan() : Tables.Scan(; select = scan.select)
    return try
        apply_scan(src isa FrameSource ? take(src.frame, Int[]) : empty_frame(source_schema(src)), sel)
    catch err
        err isa InterruptException && rethrow()
        nothing
    end
end

# `nothing` when the stage compiles on `probe`, else why not.
function _compile_check(stage, probe::Frame)
    _stage_nodes(stage) > MAX_KERNEL_NODES && return "more than $(MAX_KERNEL_NODES) expression nodes"
    try
        _build(stage, probe)
    catch err
        err isa InterruptException && rethrow()
        return err isa _NotCompilable ? err.why : "a step does not apply to the declared schema"
    end
    return nothing
end

# ---------------------------------------------------------------------------------------------
# Shapes and cache keys

# A shape is a `String`, so a new shape compiles no new `hash`/`isequal` methods (a tuple of the
# nodes' functions would be a new tuple type per shape). A function or value is keyed by its
# type's `objectid` and its `hash` (a singleton function: one per type; `WhenFold`: its fields;
# a selector: its contents); a literal by its type only.
_vkey(io::IO, @nospecialize(x)) = print(io, objectid(typeof(x)), '#', hash(x), ';')
_skey(io::IO, x::Col) = print(io, "c:", x.name, ';')
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
        print(io, o.first, '=')
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

function _cache_set!(key, verdict::Bool)
    return lock(_KERNEL_LOCK) do
        length(_KERNEL_CACHE) >= _KERNEL_CACHE_MAX && empty!(_KERNEL_CACHE)
        _KERNEL_CACHE[key] = verdict
    end
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

# ---------------------------------------------------------------------------------------------
# Row-level building blocks. Each is called as `node(c, i)`: `c = (inputs, registers, scalars)`,
# `i` the row. They are the "closures" of ADR-0003 rule 12, with names.

"Why a stage does not compile (§3.2)."
struct _NotCompilable <: Exception
    why::String
end
"A computed value whose type is not the column's declared type: the kernel declines the morsel."
struct _KernelBail <: Exception end

struct KCol{J} end                 # input column J of the kernel
struct KReg{K} end                 # register K: a value computed earlier on this row
struct KSc{K} end                  # scalar-only subexpression K, evaluated once per morsel
struct KLit{T}
    v::T
end
struct KCall{F, A <: Tuple}
    f::F
    args::A
end
struct KCase{E, C <: Tuple, V <: Tuple, D}
    conds::C
    vals::V
    default::D
end
KCase{E}(@nospecialize(c::Tuple), @nospecialize(v::Tuple), @nospecialize(d)) where {E} =
    KCase{E, typeof(c), typeof(v), typeof(d)}(c, v, d)

@inline (::KCol{J})(c, i) where {J} = @inbounds c[1][J][i]
@inline (::KReg{K})(c, i) where {K} = @inbounds c[2][K][i]
@inline (::KSc{K})(c, i) where {K} = c[3][K]
@inline (k::KLit)(c, i) = k.v
@inline (k::KCall)(c, i) = k.f(_evall(k.args, c, i)...)
@inline function (k::KCase{E})(c, i) where {E}
    cv = _evall(k.conds, c, i)
    vv = _evall(k.vals, c, i)
    d = k.default(c, i)
    return _cwpick(E, cv, vv, d)
end

# Every block of `t` on row `i`, in order (no closure: Julia 1.10's inference keeps these
# nested calls concrete, where `map` with a closure capturing `c` and `i` did not).
@inline _evall(::Tuple{}, c, i) = ()
@inline _evall(t::Tuple{Any}, c, i) = (t[1](c, i),)
@inline _evall(t::Tuple{Any, Any}, c, i) = (t[1](c, i), t[2](c, i))
@inline _evall(t::Tuple{Any, Any, Any}, c, i) = (t[1](c, i), t[2](c, i), t[3](c, i))
@inline _evall(t::Tuple, c, i) = (t[1](c, i), _evall(_tail(t), c, i)...)

# The kernel's own errors carry a fixed message: the morsel then re-runs through the
# interpreter, whose exception (with the full message) is the one raised.
@noinline _kerror(msg::String) = throw(ArgumentError(msg))

@inline _tail(t::Tuple) = _droptail(t...)
@inline _droptail(x, rest...) = rest

# case_when on one row, as `ev(::CaseWhen)`: the conditions are checked in order up to the first
# `true` (every one was evaluated already), the chosen value converted as `_cwvalue` does.
@inline _cwpick(::Type{E}, ::Tuple{}, ::Tuple{}, d) where {E} = _kcw(E, d)
@inline function _cwpick(::Type{E}, cv::Tuple, vv::Tuple, d) where {E}
    b = first(cv)
    b isa Union{Bool, Missing} || _kerror("case_when conditions must be Bool or missing")
    b === true && return _kcw(E, first(vv))
    return _cwpick(E, _tail(cv), _tail(vv), d)
end
@inline function _kcw(::Type{E}, x) where {E}
    r = _kcwvalue(E, x)
    r isa E || _kerror("case_when: a value is not of the common type of the values")
    return r
end
# `_cwvalue` (interpreter.jl), specialised on `E`.
@inline function _kcwvalue(::Type{E}, x) where {E}
    x isa E && return x
    x isa AbstractString && return String(x)
    y = try
        convert(nonmissingtype(E), x)
    catch err
        err isa InexactError || rethrow()
        nothing
    end
    (y !== nothing && isequal(y, x)) || _kerror("case_when: a value cannot be represented in the common type of the values")
    return y
end

# Steps on one row: `KMut` writes register K, `KFilt` says whether the row stays.
struct KMut{K, X}
    x::X
end
KMut{K}(@nospecialize(x)) where {K} = KMut{K, typeof(x)}(x)
struct KFilt{OUT, P <: Tuple}
    preds::P
end
KFilt{OUT}(@nospecialize(p::Tuple)) where {OUT} = KFilt{OUT, typeof(p)}(p)

@inline function _runop(op::KMut{K}, c, i) where {K}
    y = op.x(c, i)
    out = c[2][K]
    y isa eltype(out) || throw(_KernelBail())
    @inbounds out[i] = y
    return true
end
# `apply(::FilterStep)`'s three-valued AND over every condition (1 true, 0 false, -1 missing).
@inline function _runop(op::KFilt{OUT}, c, i) where {OUT}
    st = _fstate(_evall(op.preds, c, i), Int8(1))
    return OUT ? st != Int8(1) : st == Int8(1)
end
@inline _fstate(::Tuple{}, st::Int8) = st
@inline function _fstate(vs::Tuple, st::Int8)
    b = first(vs)
    if b === false
        st = Int8(0)
    elseif ismissing(b)
        st == Int8(1) && (st = Int8(-1))
    elseif b !== true
        _kerror("filter: conditions must be Bool or missing")
    end
    return _fstate(_tail(vs), st)
end

@inline _runops(::Tuple{}, c, i) = true
@inline function _runops(ops::Tuple, c, i)
    _runop(first(ops), c, i) || return false
    return _runops(_tail(ops), c, i)
end

"""
    _rowloop(ops, c, n, hasfilter) -> Vector{Int}

The fused row loop: every step of `ops` on rows `1:n` in order, a row leaving at the first
filter that drops it. Returns the kept rows when the stage filters (else an empty vector).
"""
function _rowloop(ops::Tuple, c::Tuple, n::Int, hasfilter::Bool)
    keep = Vector{Int}(undef, hasfilter ? n : 0)
    m = 0
    for i in 1:n
        if _runops(ops, c, i) && hasfilter
            m += 1
            @inbounds keep[m] = i
        end
    end
    return resize!(keep, m)
end

_allocregs(::Type{R}, n::Int) where {R <: Tuple} = ntuple(k -> Vector{fieldtype(R, k)}(undef, n), Val(fieldcount(R)))
_evalscalars(t::Tuple) = map(s -> s(nothing, 0), t)

# ---------------------------------------------------------------------------------------------
# The program of a stage on given input columns

"""
A stage compiled for one set of input column types: the row steps `ops`, the scalar-only
subexpressions, the register element types `R` (a `Tuple` type), the input columns read
(`ins`, positions in the morsel), and the output columns (`names`, each from an input column or
a register). Not parametric: per shape, only `_kernelrun` (and the row loop) is compiled.
"""
struct StageProgram
    ops::Tuple
    scalars::Tuple
    R::Type
    ins::Vector{Int}
    names::Vector{Symbol}
    slots::Vector{Tuple{Symbol, Int}}
    hasfilter::Bool
end

function (p::StageProgram)(f::Frame)
    ins = Tuple(f.columns[j] for j in p.ins)
    regs, keep = _kernelrun(p.ops, p.scalars, p.R, ins, f.nrow, p.hasfilter)
    return _assemble(p, f, regs, keep)
end

# The compiled part of one call (a function barrier: one method instance per shape and input
# column types). Scalar-only subexpressions are evaluated once per morsel, also on no rows (n2);
# the registers are allocated per call (the kernel is reentrant).
function _kernelrun(ops::Tuple, scalars::Tuple, ::Type{R}, ins::Tuple, n::Int, hasfilter::Bool) where {R <: Tuple}
    sc = _evalscalars(scalars)
    regs = _allocregs(R, n)
    keep = _rowloop(ops, (ins, regs, sc), n, hasfilter)
    return regs, keep
end

# The output frame: input columns as they are (or `take`n when the stage filters, so a
# dictionary column keeps its dictionary, N3); registers as `column(values)`, which is what
# `typed_column` gives for values already of the declared type. Not specialised on the register
# types: only the row loop is compiled per shape.
function _assemble(p::StageProgram, f::Frame, @nospecialize(regs::Tuple), keep::Vector{Int})
    built = Dict{Tuple{Symbol, Int}, AbstractColumn}()
    cols = AbstractColumn[]
    for s in p.slots
        col = get!(built, s) do
            kind, k = s
            if kind === :in
                p.hasfilter ? take(f.columns[k], keep) : f.columns[k]
            else
                v = regs[k]
                column(p.hasfilter ? v[keep] : v)
            end
        end
        push!(cols, col)
    end
    return Frame(copy(p.names), cols, Symbol[], nothing, p.hasfilter ? length(keep) : f.nrow, true)
end

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

# ---------------------------------------------------------------------------------------------
# The compiled kernel of one run

"""
    CompiledStage(ph)

The compiled kernel of `ph`'s streamed stage for one run. Each morsel is run by the
`StageProgram` for its column types (built once per run under the stage's lock, after a probe
check on the first build in the session), through `_run_guarded`. Column types that do not
compile run the interpreter.
"""
struct CompiledStage{P}
    ph::P                    # the `Physical` plan (defined after this file)
    shape::String
    progs::Dict{Any, Any}
    lock::ReentrantLock
end
CompiledStage(ph::P) where {P} = CompiledStage{P}(ph, _stageshape(ph.stage), Dict{Any, Any}(), ReentrantLock())

function (k::CompiledStage)(f::Frame)
    prog = _program(k, f)
    prog === nothing && return interpret_stage(k.ph)(f)
    return _run_guarded(prog, k.ph, f, () -> _decline!(k, f))
end

# A declined morsel (a value of another type than declared, e.g. `/` on Int columns): these
# column types run the interpreter for the rest of the run and the session.
function _decline!(k::CompiledStage, f::Frame)
    key = _morsel_key(k.shape, f)
    lock(() -> (k.progs[key] = nothing), k.lock)
    _cache_set!(key, false)
    _cache_set!(_decision_key(k.ph.stage, f), false)
    return nothing
end

function _program(k::CompiledStage, f::Frame)
    key = _morsel_key(k.shape, f)
    return lock(k.lock) do
        haskey(k.progs, key) && return k.progs[key]
        prog = _compile(k, f, key)
        k.progs[key] = prog
        prog
    end
end

# Build the program for `f`'s column types; on the first build in the session, check its output
# column types against the interpreter's on an empty probe (§3.2, critic N3) and cache the
# verdict. `nothing` when it does not compile or fails the check.
function _compile(k::CompiledStage, f::Frame, key)
    verdict = lock(() -> get(_KERNEL_CACHE, key, nothing), _KERNEL_LOCK)
    verdict === false && return nothing
    probe = take(f, Int[])
    prog = try
        _build(k.ph.stage, probe)
    catch err
        err isa InterruptException && rethrow()
        _cache_set!(key, false)
        return nothing
    end
    verdict === true && return prog
    expect = try
        interpret_stage(k.ph)(probe)
    catch err
        # the interpreter throws on no rows (a scalar subexpression, a plan-time check): it
        # will on every morsel, so it runs them all; nothing is cached (it may depend on values)
        err isa InterruptException && rethrow()
        return nothing
    end
    ok = try
        _sametypes(prog(probe), expect)
    catch err
        err isa InterruptException && rethrow()
        false
    end
    _cache_set!(key, ok)
    _cache_set!(_decision_key(k.ph.stage, probe), ok)
    return ok ? prog : nothing
end

_sametypes(a::Frame, b::Frame) = a.names == b.names && a.nrow == b.nrow && a.groups == b.groups &&
    length(a.columns) == length(b.columns) && all(i -> typeof(a.columns[i]) === typeof(b.columns[i]), eachindex(a.columns))

"""
    _run_guarded(kernel, ph, f, ondecline = () -> nothing) -> Frame

`kernel(f)`; on an exception other than `InterruptException` (rethrown at once, critic n1) the
morsel re-runs through the interpreter, whose exception, if any, is the one raised (critic B2).
When the interpreter succeeds its result is used, and `_KERNEL_DISAGREE` counts it, unless the
kernel only declined a value of an unexpected type (`_KernelBail`; then `ondecline()` runs).
"""
function _run_guarded(kernel, ph, f::Frame, ondecline = () -> nothing)
    return try
        kernel(f)
    catch err
        err isa InterruptException && rethrow()
        err isa _KernelBail && ondecline()
        r = interpret_stage(ph)(f)
        err isa _KernelBail || Threads.atomic_add!(_KERNEL_DISAGREE, 1)
        r
    end
end
