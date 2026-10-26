# The physical plan and the morsel executor (spec §1, §6; ADR-0003 rules 5-7; ADR-0004 rules 3,
# 4, 10). A physical plan is one pipeline, `scan → streamed stage → [limit] → materialize`, then
# the rest of the steps run on the materialized frame through the eager operators.

# ---------------------------------------------------------------------------------------------
# Which steps stream (run per partition, independently): ungrouped per-row verbs.

_streamable(x::Col) = true
_streamable(x::Lit) = x.scalar
_streamable(x::Call) = all(_streamable, x.args)
_streamable(x::CaseWhen) = all(_streamable, x.conds) && all(_streamable, x.vals) && _streamable(x.default)
_streamable(::Any) = false

"Can `s` run on each partition of an ungrouped input independently (spec §6)?"
isstreamable(::Step) = false
isstreamable(s::FilterStep) = all(_streamable, s.preds)
isstreamable(s::Union{RenameStep, RenameWithStep, RelocateStep}) = true
isstreamable(s::SelectStep) = all(it -> !(it isa Pair) || _streamable(it.second), s.items)
isstreamable(s::MutateStep) = s.by === nothing && s.keep === :all &&
    all(o -> o isa Pair && (o.second === nothing || _streamable(o.second)), s.outs)

"""
    Physical

The physical plan of a query: the `scan`, the streamed `stage` (per partition), an optional
row `limit` (a `head(n)`, n ≥ 0) applied in morsel order, whether the scan may `stop_early`
once it has the limit's rows (every step below it is total, spec §1 R-total), and the `rest`
of the steps (run on the materialized frame).
"""
struct Physical
    scan::ScanNode
    stage::Vector{Step}
    limit::Union{Nothing, Int}
    stop_early::Bool
    rest::Vector{Step}
    engine::Vector{Node}   # the scan's predicates the source is not handed (applied by the engine)
end
Physical(scan, stage, limit, stop, rest) = Physical(scan, stage, limit, stop, rest, enginepreds(scan))

function physical(plan)
    scan, steps = linearize(plan)
    stage = Step[]
    i = 1
    if isempty(scan.groups)
        while i <= length(steps) && isstreamable(steps[i])
            push!(stage, steps[i])
            i += 1
        end
    end
    limit = nothing
    stop = false
    if i <= length(steps) && steps[i] isa HeadStep && steps[i].n >= 0 && isempty(scan.groups)
        limit = steps[i].n
        stop = all_total(scan, stage)
        i += 1
    end
    return Physical(scan, stage, limit, stop, steps[i:end])
end

"Is every step of `stage` (above the scan's own total predicates) total (spec §1)?"
function all_total(scan::ScanNode, stage)
    plan = scan
    for s in stage
        _steptotal(s, plan) || return false
        plan = StepNode(s, plan)
    end
    return true
end
function _steptotal(s::Step, below)
    s isa Union{RenameStep, RenameWithStep, RelocateStep} && return node_schema(StepNode(s, below)) !== nothing
    s isa SelectStep && return _isnameonly(s) && node_schema(StepNode(s, below)) !== nothing
    if s isa FilterStep
        sch = node_schema(below)
        sch === nothing && return false
        types = _typedict(sch)
        return all(p -> istotal(p, types), s.preds)
    end
    return false
end

# ---------------------------------------------------------------------------------------------
# Execution

"Counters an execution reports to `explain` (partitions planned, pruned, read; the sink that consumed the morsels: `:none` (gathered) or `:hashagg`)."
mutable struct ExecStats
    planned::Int
    pruned::Int
    read::Int
    parallel::Bool
    tasks::Int
    sink::Symbol
end
ExecStats() = ExecStats(0, 0, 0, false, 0, :none)


# A `FrameSource` is handed no filter: its residual would apply it through Tables.jl's generic
# row path, slower than the engine's own `filter` on the same in-memory columns.
_pushesfilters(::Source) = true
_pushesfilters(::FrameSource) = false

"The `Tables.Scan` the scan node pushes to its source (ADR-0004 rules 1, 3)."
function pushed_scan(n::ScanNode)
    sch = scan_schema(ScanNode(n.source, nothing, Node[], nothing, n.groups, n.drop))
    filt = nothing
    allpushed = true
    if !_pushesfilters(n.source)
        allpushed = isempty(n.preds)
    elseif sch !== nothing
        types = _typedict(sch)
        for p in n.preds
            t = to_scan(p, types)
            if t === nothing
                allpushed = false
            else
                filt = filt === nothing ? t : (filt & t)
            end
        end
    else
        allpushed = isempty(n.preds)
    end
    sel = n.select === nothing ? Tables.Scan().select : Tables.Scan(; select = n.select).select
    limit = allpushed ? n.limit : nothing
    return Tables.Scan(; select = sel, filter = filt, limit = limit)
end

"""
    enginepreds(n::ScanNode) -> Vector{Node}

The scan predicates that do not translate to `Tables.Scan` (spec §4): the engine applies them
after the residual. Translated ones reach the source, which applies them or returns them in
the residual (CF-012); either way they are applied exactly once.
"""
function enginepreds(n::ScanNode)
    isempty(n.preds) && return Node[]
    _pushesfilters(n.source) || return copy(n.preds)
    sch = scan_schema(ScanNode(n.source, nothing, Node[], nothing, n.groups, n.drop))
    sch === nothing && return copy(n.preds)
    types = _typedict(sch)
    return Node[p for p in n.preds if to_scan(p, types) === nothing]
end

function _pruned(n::ScanNode, h)
    isempty(n.preds) && return false
    src = n.source
    stats = col -> try
        partition_stats(src, h, col)
    catch
        nothing
    end
    for p in n.preds
        ok = try
            may_match(p, stats)
        catch
            true
        end
        ok || return true
    end
    return false
end

# One partition: read it and apply the residual; then the engine's re-applied scan predicates
# and the streamed stage.
_readpart(ph::Physical, residual::Tables.Scan, h) =
    apply_scan(conform_types(_read(ph.scan.source, h), source_schema(ph.scan.source)), residual)
# A partition read for its column kinds only (`_needs_levels`): its empty slice, taken before
# the declared types, the residual and the stage, so no row is converted, filtered or computed.
_readkinds(ph::Physical, residual::Tables.Scan, h, kernel) =
    _runstage(ph, apply_scan(conform_types(take(_read(ph.scan.source, h), Int[]), source_schema(ph.scan.source)), residual), kernel)
function _runstage(ph::Physical, f::Frame, kernel = interpret_stage(ph))
    isempty(ph.engine) || (f = apply(FilterStep(ph.engine, false), f))
    return kernel(f)
end

_coltypes(f::Frame) = Type[eltype(c) for c in f.columns]

"""
    MorselError(index, err)

The exception of the first failing morsel (in morsel order) of a parallel run (ADR-0003 rule 7).
"""
struct MorselError
    index::Int
    err::Any
end

# Unwrap TaskFailedException / CompositeException to the original exception (ADR-0003 rule 7).
_taskerror(e::TaskFailedException) = _taskerror(e.task.exception)
_taskerror(e::CompositeException) = isempty(e.exceptions) ? e : _taskerror(first(e.exceptions))
_taskerror(e) = e

# Run `g(i)` for i in 1:n on `ntasks` tasks, each with a contiguous range of indices. Results go
# into a concretely typed vector by index. A failure at index k stops the ranges after k's range
# (they check between morsels); earlier ranges run to completion, so the first failure in index
# order is the one a serial run raises.
function _parallel_map(g, n::Int, ntasks::Int)
    out = Vector{Frame}(undef, n)
    errs = Vector{Any}(nothing, n)
    ntasks = max(1, min(ntasks, n))
    bounds = [(div((k - 1) * n, ntasks) + 1):div(k * n, ntasks) for k in 1:ntasks]
    failed = Threads.Atomic{Int}(typemax(Int))   # lowest failing range
    tasks = map(enumerate(bounds)) do (k, r)
        Threads.@spawn begin
            for i in r
                failed[] < k && break
                try
                    out[i] = g(i)
                catch err
                    errs[i] = err
                    Threads.atomic_min!(failed, k)
                    break
                end
            end
        end
    end
    for t in tasks
        try
            wait(t)
        catch err
            # a task can only fail outside the per-morsel try (a bug); surface the original
            throw(_taskerror(err))
        end
    end
    i = findfirst(!isnothing, errs)
    i === nothing || throw(MorselError(i, errs[i]))
    return out
end

function _gather(frames::Vector{Frame}, empty::Function, kinds::Vector{Frame} = frames)
    nonempty = Frame[f for f in frames if f.nrow > 0]
    out = if isempty(nonempty)
        isempty(frames) ? empty() : first(frames)
    elseif length(nonempty) == 1
        only(nonempty)
    else
        _concat(nonempty)         # keeps the row count of zero-column frames (review B1)
    end
    return _gathered_kinds(out, kinds)
end

# The gathered frame's dictionary columns with the kinds the eager read gives them
# (`_gathered_kind`, src/engine/hashagg.jl), from the non-pruned morsels' outputs `kinds`.
function _gathered_kinds(out::Frame, kinds::Vector{Frame})
    (isempty(out.groups) && any(c -> c isa DictColumn, out.columns)) || return out
    cols = copy(out.columns)
    for (j, nm) in enumerate(out.names)
        cols[j] isa DictColumn || continue
        cols[j] = _gathered_kind(cols[j], AbstractColumn[getcol(f, nm) for f in kinds if nm in f.names])
    end
    return Frame(copy(out.names), cols, Symbol[], nothing, out.nrow)
end

"""
    execute(ph::Physical; morsel, threads) -> Frame

Run a physical plan (spec §6). Partitions are planned with the pushed `Scan`, pruned from their
statistics, read (behind the source lock unless `isthreadsafe`), passed through the residual,
the re-applied scan predicates and the streamed stage, and gathered in morsel order. The stage
runs in parallel (contiguous morsel ranges) when it is stateless (`isstateless`) and there is no
limit; a limit runs sequentially through `foldxl`, stopping early only when allowed (R-total).

When the steps after the stage start with a summary the hash-aggregate sink computes
(`_hashagg_plan`, phase-4 spec §2.1), the morsels are folded per task into partial aggregates
instead of being gathered (`_run_hashagg`, src/lazy/sinks.jl); every morsel still runs through
`_runstage` with the stage's kernel. The steps after the summary then run eagerly.
"""
function execute(ph::Physical; morsel::Int = DEFAULT_MORSEL, threads::Bool = true, stats::ExecStats = ExecStats())
    scan = ph.scan
    src = scan.source
    handles, residual = plan_partitions(src, pushed_scan(scan); morsel)
    stats.planned = length(handles)
    pruned = Threads.Atomic{Int}(0)
    # The streamed stage's kernel: compiled or the interpreter (`stage_kernel`, kernels.jl).
    kernel = stage_kernel(ph, _estimated_rows(src))
    # Each morsel is pruned (from its statistics) when it is reached, so a stopped scan computes
    # no statistics for the morsels it never reads. Every partition is read with the declared
    # column types (`conform_types`, as `read_source` does), so the stage sees the eager types.
    emptyout = Ref{Union{Nothing, Frame}}(nothing)    # computed once, by the first pruned morsel
    emptylock = ReentrantLock()
    levels = _needs_levels(ph)
    function part(i)
        if _pruned(scan, handles[i])
            Threads.atomic_add!(pruned, 1)
            # A later step shows dictionary levels: the pruned partition's column kinds still
            # count (its empty slice through the stage), as eager `read_source` concatenates it.
            levels && return _readkinds(ph, residual, handles[i], kernel)
            return lock(emptylock) do
                emptyout[] === nothing && (emptyout[] = _process_empty(ph))
                emptyout[]::Frame
            end
        end
        return _runstage(ph, _readpart(ph, residual, handles[i]), kernel)
    end
    ispruned(f::Frame) = f === emptyout[]       # a pruned morsel's shared empty output
    sink = _hashagg_plan(ph)
    if sink isa Tuple
        spec, nsteps = sink
        agg = _run_hashagg(ph, spec, part, handles, threads, stats, ispruned)
        stats.pruned = pruned[]
        return run_rest(ph, agg; morsel, threads, from = nsteps + 1)
    end
    # the partitions an early-stopped limit never reached still count for the column kinds
    kindsonly = levels ? (i -> _readkinds(ph, residual, handles[i], kernel)) : nothing
    frames = _run(ph, part, length(handles), threads, stats, kindsonly)
    stats.pruned = pruned[]
    out = _gather(frames, () -> _process_empty(ph), Frame[f for f in frames if !ispruned(f)])
    ph.limit === nothing || (out = apply(HeadStep(ph.limit), out))
    return run_rest(ph, out; morsel, threads)
end

"""
    _needs_levels(ph) -> Bool

Does a step after the streamed stage show dictionary levels (a `group_by(...; drop = false)`, or
a `drop = false` scan)? Then a gathered dictionary column must have exactly the kind the eager
read gives it (`_gathered_kind`): eager `read_source` concatenates every partition, so a
partition pruned by statistics still decides whether the column stays a dictionary column
(review MAJOR 1, CF-008). Such a pruned partition is read and its empty slice runs through the
stage: no rows are processed, its column kinds are seen (`_readkinds`). So do the partitions a
row limit's early stop never reaches, when a gathered column is a dictionary column
(`_sequential_limit`).
"""
_needs_levels(ph) = !ph.scan.drop || any(s -> s isa GroupByStep && s.drop === false, ph.rest)

"""
The source's row count (an upper bound when not exact) when it reports one, else `nothing`
(for `stage_kernel`). `row_count` returns `nothing` when unknown (src/io/interface.jl).
"""
function _estimated_rows(src)
    n = row_count(src)
    return n === nothing ? nothing : Int(first(n))
end

# The stage's output on no rows: the declared schema through the scan's projection and the stage.
function _process_empty(ph::Physical)
    scan = ph.scan
    sel = scan.select === nothing ? Tables.Scan() : Tables.Scan(; select = scan.select)
    # a frame's own empty slice keeps its column kinds (a dictionary column keeps its levels,
    # review B4); any other source gives the declared schema
    src = scan.source
    f = apply_scan(src isa FrameSource ? take(src.frame, Int[]) : empty_frame(source_schema(src)), sel)
    isempty(scan.groups) || (f = regroup(f, scan.groups; drop = scan.drop))
    isempty(scan.preds) || (f = apply(FilterStep(scan.preds, false), f))
    return interpret_stage(ph)(f)
end

# A row limit in morsel order: a sequential foldxl over the kept partitions. Once the frames
# hold `limit` rows the fold returns `Reduced` (sequential, never under a parallel fold;
# ChuiCore S1), but only when `stop_early`; otherwise every partition is processed, so a
# non-total step raises on the same rows as eager (spec §1).
#
# After an early stop, `kindsonly(i)` (given when `_needs_levels`) adds each unreached morsel's
# empty output (`_readkinds`), so the gather sees every partition's column kinds as eager
# `read_source` does (CF-008). Safe: these frames have no rows, so the gathered rows, the
# limit's rows and the R-total semantics do not change (the stage runs on no rows, so it cannot
# raise where eager would not). Only when a gathered frame holds a dictionary column: otherwise
# no kind can change (`_gathered_kinds`) and the scan still stops early.
function _sequential_limit(ph::Physical, part, n::Int, stats::ExecStats, kindsonly = nothing)
    limit = ph.limit::Int
    rows = Ref(0)
    function rf(acc::Vector{Frame}, f::Frame)
        push!(acc, f)
        stats.read += 1
        rows[] += f.nrow
        return (ph.stop_early && rows[] >= limit) ? UP.Reduced(acc) : acc
    end
    acc = UP.foldxl(rf, UP.Map(part), 1:n; init = Frame[])
    (kindsonly === nothing || length(acc) >= n) && return acc
    any(f -> any(c -> c isa DictColumn, f.columns), acc) || return acc
    for i in (length(acc) + 1):n
        push!(acc, kindsonly(i)::Frame)
        stats.read += 1
    end
    return acc
end

# Run `part(i)` for the morsels 1:n: with a limit sequentially; else in parallel when the stage,
# as a transducer over morsels, is stateless (ADR-0003 rule 6) and threads are available; else
# sequentially.
function _run(ph::Physical, part, n::Int, threads::Bool, stats::ExecStats, kindsonly = nothing)
    ph.limit === nothing || return _sequential_limit(ph, part, n, stats, kindsonly)
    xf = UP.Map(part)
    if threads && Threads.nthreads() > 1 && n > 1 && UP.isstateless(xf)
        stats.parallel = true
        stats.tasks = min(Threads.nthreads(), n)
        stats.read = n
        return _parallel_map(part, n, stats.tasks)
    end
    stats.read = n
    return UP.foldxl(push!, xf, 1:n; init = Frame[])
end
