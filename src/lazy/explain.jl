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
    joins = _JoinNote[]
    ph = physical(_hasjoin(plan) ? _explain_lower(plan, joins, Int(morsel)) : plan)
    _section(io, "logical plan")
    _printplan(io, q.plan, "  ")
    _section(io, "optimized plan")
    _printplan(io, plan, "  ")
    _section(io, "rules fired")
    isempty(log.fired) && println(io, "  none")
    foreach(r -> println(io, "  - ", r), log.fired)
    foreach(p -> println(io, "  - fixpoint cap hit: ", p, " (kept the last plan)"), log.capped)
    _section(io, "physical plan")
    _printjoins(io, joins; kernel)
    _printphysical(io, ph; kernel)
    _section(io, "pruning")
    _printpruning(io, ph, Int(morsel))
    _section(io, "rendered kernel")
    ex = render_kernel(ph)
    if any(s -> s isa ProbeStep, ph.stage)
        println(io, "  not rendered (the stage holds a join probe)")
    elseif ex === nothing
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
    _unbuilt_probe(ph) && return _explain_rest_atcollect(io, ph)
    return _explain_rest(io, ph)
end

# The stage holds a join probe whose build side is still a plan (explain's symbolic lowering,
# `_explain_lower`): `explain` runs nothing, so the stage's output schema, and with it the
# hash-aggregate sink decision (`_hashagg_plan`), is known only at `collect`, which collects the
# build side first (review minor: explain said "no hash-aggregate sink" where collect uses it).
_unbuilt_probe(ph::Physical) = any(s -> s isa ProbeStep && s.build isa PlanNode, ph.stage)
function _explain_rest_atcollect(io::IO, ph::Physical)
    # only the reason that needs the stage's output: a reason found from the steps alone stands
    _hashagg_plan(ph) == "the stage's output schema is not known" || return _explain_rest(io, ph)
    println(io, "  then materialize (concatenate in morsel order)")
    println(io, "  then eagerly: ", join(string.(ph.rest), " ⨟ "))
    println(io, "    hash-aggregate sink for the summary: decided at collect, once the join's build side is collected (explain collects nothing)")
    _explain_windows(io, ph.rest, 1)
    return nothing
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
    ph = physical(_hasjoin(plan) ? _explain_lower(plan, _JoinNote[], DEFAULT_MORSEL) : plan)
    ex = any(s -> s isa ProbeStep, ph.stage) ? nothing : render_kernel(ph)
    ex === nothing && return println(io, "no streamed stage: nothing to render")
    println(io, "# rendered kernel: one partition's columns as `cols`")
    show(io, MIME("text/plain"), lower_kernel(ex))
    println(io)
    return nothing
end

# ---------------------------------------------------------------------------------------------
# Joins in `explain` (phase-4 spec §1.4): the plan is lowered symbolically (nothing runs), one
# note per join, innermost first.

struct _JoinNote
    label::String
    strategy::Symbol         # :broadcast, :partitioned or :cross
    build::Symbol
    p::Int
    why::String
    est::SideEstimate        # the build (collected) side's estimate
    collected::Any           # the collected side's lowered plan
    collected_side::Symbol
    resolved::Bool           # names resolved when the query was built
    static::Bool             # both sides' key types static
end

_placeholder_names() = JoinNames(Pair{Symbol, Symbol}[], false, Symbol[], Symbol[], Symbol[], Symbol[], Symbol[], Symbol[], Symbol[], nothing)

_explain_lower(n::ScanNode, notes::Vector{_JoinNote}, m::Int) = n
_explain_lower(n::StepNode, notes::Vector{_JoinNote}, m::Int) = StepNode(n.step, _explain_lower(n.child, notes, m))
function _explain_lower(j::JoinNode, notes::Vector{_JoinNote}, m::Int)
    s = j.spec
    names = j.names === nothing ? _placeholder_names() : j.names
    resolved = j.names !== nothing
    label = _joinlabel(j)
    if s.kind === :cross
        ylow = _explain_lower(j.right, notes, m)
        push!(notes, _JoinNote(label, :cross, :y, 0, "a cross join has no hash table", _plan_estimate(j.right), ylow, :y, resolved, true))
        return StepNode(ProbeStep(:y, j.right, s, names, false), _explain_lower(j.left, notes, m))
    end
    static = resolved && names.compare !== nothing
    xe, ye = _plan_estimate(j.left), _plan_estimate(j.right)
    strategy, build, p, why = join_decision(s, xe, ye)
    if strategy === :broadcast && build === :y
        ylow = _explain_lower(j.right, notes, m)
        main = _explain_lower(j.left, notes, m)
        push!(notes, _JoinNote(label, strategy, build, p, why, ye, ylow, :y, resolved, static))
        tail = _needs_ytail(s)
        node = StepNode(ProbeStep(:y, j.right, s, names, tail), main)
        return tail ? StepNode(JoinTailStep(:y, j.right, s, names), node) : node
    elseif strategy === :broadcast
        xlow = _explain_lower(j.left, notes, m)
        main = _explain_lower(j.right, notes, m)
        push!(notes, _JoinNote(label, strategy, build, p, why, xe, xlow, :x, resolved, static))
        return StepNode(JoinTailStep(:x, j.left, s, names), StepNode(ProbeStep(:x, j.left, s, names, true), main))
    end
    ylow = _explain_lower(j.right, notes, m)
    main = _explain_lower(j.left, notes, m)
    push!(notes, _JoinNote(label, strategy, build, p, why, build === :x ? xe : ye, ylow, :y, resolved, static))
    return StepNode(PartitionedJoinStep(j.right, s, names, build, p, Type[], m, true), main)
end

function _estimate_str(e::SideEstimate)
    rows = e.rows === nothing ? "unknown rows" : string(e.exact ? "" : "at most ", e.rows, " rows")
    b = _estimated_bytes(e)
    return string(rows, ", ", b === nothing ? "unknown bytes" : "$(b) bytes")
end

function _printjoins(io::IO, notes::Vector{_JoinNote}; kernel::Bool = false)
    isempty(notes) && return nothing
    for (k, n) in enumerate(notes)
        println(io, "  join ", k, ": ", n.label)
        if n.strategy === :cross
            println(io, "    y is collected and every x morsel is paired with it, in x order (no hash table, no sort)")
        else
            println(io, "    strategy: ", n.strategy === :broadcast ? "broadcast" : "partitioned into 2^$(n.p)", ", build ", n.build, " (estimated ", _estimate_str(n.est), ")")
            if n.strategy === :broadcast && n.build === :y
                println(io, "    the probe streams x; the order-restoring sort is skipped (the pairs come out in order)")
            elseif n.strategy === :broadcast
                println(io, "    the probe streams y; join_tail runs the order-restoring sort")
            else
                println(io, "    no side streams (x is gathered, y collected); the order-restoring sort runs")
            end
            println(io, "    ", n.why == "forced by _FORCE_JOIN" ? "forced by _FORCE_JOIN" : "predicted from estimates; confirmed on the collected build side")
            n.resolved || println(io, "    names: resolved at collect (a side's schema is not static)")
            n.resolved && !n.static && println(io, "    key types are not static: those sides are collected first, at collect")
        end
        println(io, "    ", n.collected_side, ", collected", n.strategy === :partitioned ? " when the step runs" : " first", ":")
        sub = sprint(io2 -> _printphysical(io2, physical(n.collected); kernel))
        for line in split(chomp(sub), '\n')
            println(io, "    ", line)
        end
    end
    println(io, "  main pipeline:")
    return nothing
end
