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
The decision verdicts again, keyed by `_shapehash(ph)` (no allocation), for small inputs: they
only ask "compiled before?". A hash collision can only compile a stage early (each morsel's
program is still checked under the exact `String` key), never change a result.
"""
const _KERNEL_SMALL = Dict{UInt, Bool}()
"Whether `_KERNEL_SMALL` holds any `true` verdict (small inputs skip the lookup when not)."
const _KERNEL_ANY_COMPILED = Threads.Atomic{Bool}(false)

"Empty the session's kernel cache (the precompile workload does, as its keys hold `objectid`s)."
function _kernel_cache_clear!()
    lock(_KERNEL_LOCK) do
        empty!(_KERNEL_CACHE)
        empty!(_KERNEL_SMALL)
        _KERNEL_ANY_COMPILED[] = false
    end
    return nothing
end

"""
Estimated rows from which a stage whose shape is not compiled yet is compiled at `collect`
(ADR-0003 rule 12): below it the interpreter runs. Set from docs/research/codegen-phase4.md:
a new shape costs about 20-45 ms to compile for 1-10-step stages, which the per-row saving
repays at 1.6×10⁵-1.3×10⁶ rows (median about 5×10⁵ on Julia 1.13 and on 1.10).
"""
const INTERP_THRESHOLD = 500_000

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
    kind, why = _decide(ph, est_rows)
    return (kind, _whytext(why, est_rows))
end

# The decision with its reason as a Symbol (or the compile check's message), so `stage_kernel`
# formats no text. Small inputs (below `INTERP_THRESHOLD`, or of unknown size) only look the
# shape up: with nothing compiled in the session they do no work at all, and otherwise no probe
# check or build (the lazy `n=10` overhead rows, ADR-0022 rule 3).
function _decide(ph, est_rows::Union{Nothing, Integer})
    force = _FORCE_KERNEL[]
    # fail closed: a mistyped switch must not silently mean :auto
    force in (:auto, :compiled, :interpreter) ||
        throw(ArgumentError("_FORCE_KERNEL must be :auto, :compiled or :interpreter, got $(repr(force))"))
    isempty(ph.stage) && return (:interpreter, :nostage)
    force === :interpreter && return (:interpreter, :forced)
    if force === :auto && (est_rows === nothing || est_rows < INTERP_THRESHOLD)
        _KERNEL_ANY_COMPILED[] || return (:interpreter, :small)
        h = _shapehash(ph)
        lock(_KERNEL_LOCK)
        verdict = try
            get(_KERNEL_SMALL, h, nothing)
        finally
            unlock(_KERNEL_LOCK)
        end
        verdict === true && return (:compiled, :cached)
        return (:interpreter, verdict === false ? :rejected : :small)
    end
    probe = _stage_probe(ph)
    probe === nothing && return (:interpreter, :noschema)
    why = _compile_check(ph.stage, probe)
    why === nothing || return (:interpreter, why)
    verdict = lock(() -> get(_KERNEL_CACHE, _decision_key(ph.stage, probe), nothing), _KERNEL_LOCK)
    force === :compiled && return (:compiled, verdict === true ? :cached : :atcollect)
    verdict === false && return (:interpreter, :rejected)
    return (:compiled, verdict === true ? :cached : :atcollect)
end

_whytext(why::String, est_rows) = why
function _whytext(why::Symbol, est_rows)
    why === :nostage && return "no streamed stage"
    why === :forced && return "forced"
    why === :noschema && return "the source schema is not known"
    why === :cached && return "cached"
    why === :atcollect && return "compiled at collect"
    why === :rejected && return "the compiled kernel was rejected for this shape"
    est_rows === nothing && return "row count unknown and shape not compiled yet"
    return "estimated $(est_rows) rows < INTERP_THRESHOLD = $(INTERP_THRESHOLD) and shape not compiled yet"
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
    kind, _ = _decide(ph, est_rows)
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

# Shapes, cache keys (`_stageshape`, `_shapehash`, `_cache_set!`, `_small_set!`) and the stage
# size (`_stage_nodes`) are in kernels_build.jl.

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

# The builder (`_build`: a stage and a probe frame → a `StageProgram`) is in kernels_build.jl.

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
    _small_set!(k.ph, false)
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
    _small_set!(k.ph, ok)
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
