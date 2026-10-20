# Running a lazy query: `collect` (spec §1, §2; CF-008; ADR-0003 rule 7).

"""
    collect(q::LazyFrame; morsel = 65_536, threads = true) -> Frame

Optimize and run `q` (CF-008): the result agrees with running the same verbs eagerly. `morsel`
is the partition size asked of the source (a `lazy(frame)` source splits into `morsel`-row
partitions); `threads = false` runs every partition on the calling task.

If the lazy run throws, the unoptimized plan is replayed eagerly and its exception is the one
raised, so both paths raise the same exception type (spec §1); a pure pipeline (CF-008) gives
the same result either way, so the replay costs only a second run on failure.
"""
function Base.collect(q::LazyFrame; morsel::Integer = DEFAULT_MORSEL, threads::Bool = true)
    morsel >= 1 || throw(ArgumentError("collect: morsel must be at least 1, got $morsel"))
    opt = optimize(q)
    return try
        execute(physical(opt.plan); morsel = Int(morsel), threads)
    catch err
        lazyerr = err isa MorselError ? err.err : _taskerror(err)
        lazyerr isa InterruptException && rethrow()
        reference(q.plan)            # throws the eager exception, if eager throws
        throw(lazyerr)
    end
end

"`collect(s::Source; kw...)`: the whole source as a frame, through the lazy engine (CF-016's `collect(scan_file(path))`)."
Base.collect(s::Source; kw...) = collect(lazy(s); kw...)

"""
    reference(plan) -> Frame

The unoptimized plan run eagerly: the source read whole (as `read_source` does, or the frame
itself), regrouped as given, then every step through the eager operators. This is the eager
meaning of a lazy query (CF-008), used to replay a failing run.
"""
function reference(plan)
    scan, steps = linearize(plan)
    f = _readall(scan)
    for s in steps
        f = apply(s, f)
    end
    return f
end
_readall(scan::ScanNode) = scan.source isa FrameSource ? scan.source.frame : read_source(scan.source)
