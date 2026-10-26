# `explain` and `code_lowered` (spec §7; ADR-0003 rule 13; CF-017 open item: the output is not
# promised).

"""
    explain([io,] q::LazyFrame; morsel = 65_536, kernel = false)

Print how `q` runs, in sections: `logical plan` (the verbs as written, last first),
`optimized plan`, `rules fired`, `physical plan` (the pipeline, the streamed stage, parallel or
sequential and why, the limit), `pruning` (partitions kept and pruned by statistics, from the
source's `partition_stats`; no data is read) and `rendered kernel` (the streamed stage as
Julia code, see `code_lowered`). With `kernel = true` the physical plan also says which kernel
runs the streamed stage. Planning only: `explain` reads no data.
"""
explain(q::LazyFrame; kw...) = explain(stdout, q; kw...)
function explain(io::IO, q::LazyFrame; morsel::Integer = DEFAULT_MORSEL, kernel::Bool = false)
    plan, log = optimize_plan(q.plan)
    ph = physical(plan)
    _section(io, "logical plan")
    _printplan(io, q.plan, "  ")
    _section(io, "optimized plan")
    _printplan(io, plan, "  ")
    _section(io, "rules fired")
    isempty(log.fired) && println(io, "  none")
    foreach(r -> println(io, "  - ", r), log.fired)
    foreach(p -> println(io, "  - fixpoint cap hit: ", p, " (kept the last plan)"), log.capped)
    _section(io, "physical plan")
    _printphysical(io, ph; kernel)
    _section(io, "pruning")
    _printpruning(io, ph, Int(morsel))
    _section(io, "rendered kernel")
    ex = render_kernel(ph)
    if ex === nothing
        println(io, "  none (no streamed stage)")
    else
        println(io, "  ", replace(_exprstring(ex), "\n" => "\n  "))
    end
    return nothing
end

_section(io::IO, title::String) = println(io, "== ", title, " ==")

function _printphysical(io::IO, ph::Physical; kernel::Bool = false)
    scan = ph.scan
    println(io, "  scan: ", source_label(scan.source))
    q = pushed_scan(scan)
    q.filter === nothing || println(io, "    pushed to the source: ", q.filter)
    q.limit === nothing || println(io, "    pushed limit: ", q.limit, " rows per partition")
    q.filter === nothing && q.limit === nothing || println(io, "    the source applies these, or returns them in its residual")
    if isempty(ph.stage) && isempty(ph.engine)
        println(io, "  streamed stage: none")
    else
        parts = String[]
        isempty(ph.engine) || push!(parts, "filter(" * join(string.(ph.engine), ", ") * ") (scan predicates the engine applies)")
        append!(parts, string.(ph.stage))
        println(io, "  streamed stage, per morsel: ", join(parts, " ⨟ "))
    end
    if ph.limit !== nothing
        println(
            io, "  limit: head(", ph.limit, ") in morsel order, sequential (foldxl); ",
            ph.stop_early ? "stops the scan early" : "reads every partition (a step below it is not total)"
        )
    else
        println(io, "  execution: parallel over contiguous morsel ranges when threads > 1 (the stage is stateless); else sequential")
    end
    _explain_kernel(io, ph; kernel)
    return _explain_rest(io, ph)
end

function _printpruning(io::IO, ph::Physical, morsel::Int)
    scan = ph.scan
    if isempty(scan.preds)
        return println(io, "  no scan predicates: every partition is read")
    end
    handles, _ = plan_partitions(scan.source, pushed_scan(scan); morsel)
    pruned = count(h -> _pruned(scan, h), handles)
    return println(io, "  partitions: ", length(handles) - pruned, " of ", length(handles), " kept, ", pruned, " pruned by statistics")
end

_exprstring(ex::Expr) = string(Base.remove_linenums!(deepcopy(ex)))

"""
    code_lowered([io,] q::LazyFrame)

Print the `CodeInfo` of the **rendered kernel** of `q` (ADR-0003 rule 13): its streamed stage as
a Julia expression over one partition's columns, lowered with `Meta.lower`. It is not the code
the engine runs (the interpreter, until phase 4's compiled kernels), and its output is not
promised (CF-017 open items).
"""
Base.code_lowered(q::LazyFrame) = code_lowered(stdout, q)
function Base.code_lowered(io::IO, q::LazyFrame)
    plan, _ = optimize_plan(q.plan)
    ex = render_kernel(physical(plan))
    ex === nothing && return println(io, "no streamed stage: nothing to render")
    println(io, "# rendered kernel: one partition's columns as `cols`")
    show(io, MIME("text/plain"), lower_kernel(ex))
    println(io)
    return nothing
end
