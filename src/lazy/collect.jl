# Running a lazy query: `collect` (spec §1, §2; CF-008; ADR-0003 rule 7).

"""
    collect(q::LazyFrame; morsel = 65_536, threads = true) -> Frame

Optimize and run `q` (CF-008): the result agrees with running the same verbs eagerly. `morsel`
is the partition size asked of the source (a `lazy(frame)` source splits into `morsel`-row
partitions); `threads = false` runs every partition on the calling task.

If the lazy run throws, the unoptimized plan is replayed eagerly and its exception is the one
raised, so both paths raise the same exception type (spec §1). If the replay succeeds, the lazy
failure was an engine defect and the replay's (eager) result is returned. A pure pipeline
(CF-008) gives the same result either way, so the replay costs only a second run on failure.
Planning (`optimize`, and the lowering of joins, which runs their build sides) runs inside the
same guard; only this top-level call guards, so a failure inside a join's subplan replays the
whole plan once.
"""
function Base.collect(q::LazyFrame; morsel::Integer = DEFAULT_MORSEL, threads::Bool = true)
    morsel >= 1 || throw(ArgumentError("collect: morsel must be at least 1, got $morsel"))
    m = Int(morsel)
    return try
        execute(physical(_lower_joins(optimize(q).plan; morsel = m, threads)); morsel = m, threads)
    catch err
        lazyerr = err isa MorselError ? err.err : _taskerror(err)
        lazyerr isa InterruptException && rethrow()
        # The eager run throws the eager exception when eager throws. When it does not, the lazy
        # failure is an engine defect, and the eager result is the correct one (CF-008).
        r = reference(q.plan)
        @debug "lazy run failed where eager succeeds; returning the eager result" exception = lazyerr
        r
    end
end

"`collect(s::Source; kw...)`: the whole source as a frame, through the lazy engine (CF-016's `collect(scan_file(path))`)."
Base.collect(s::Source; kw...) = collect(lazy(s); kw...)

"""
    reference(plan) -> Frame

The unoptimized plan run eagerly: the source read whole (as `read_source` does, or the frame
itself), regrouped as given, then every step through the eager operators. This is the eager
meaning of a lazy query (CF-008), used to replay a failing run. A join replays as the eager
join of its two replayed sides, with the names resolved when the node was built (no second
`@info` or `@warn`) and the compare types recomputed from those frames' column types.
"""
function reference(plan)
    steps, bottom = _chain(plan)
    f = _reference_bottom(bottom)
    for s in steps
        f = apply(s, f)
    end
    return f
end
_reference_bottom(scan::ScanNode) = _readall(scan)
function _reference_bottom(j::JoinNode)
    x = reference(j.left)
    y = _ungrouped(reference(j.right))
    names = j.names === nothing ? _resolve_names(j.spec, x.names, y.names; log = false) : _withcompare(j.names, nothing)
    return _join_frames(j.spec, names, x, y)
end
_readall(scan::ScanNode) = scan.source isa FrameSource ? scan.source.frame : read_source(scan.source)
