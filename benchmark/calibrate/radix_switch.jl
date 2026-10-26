# radix_switch.jl: calibrates `RADIX_SWITCH` (src/engine/hashagg.jl; phase-4 spec §2.3, §5). A lazy
# `group_by ⨟ summarise` (the hash-aggregate sink) over n = 4·10^6 rows with G groups, Int and
# String keys, the radix limit forced through `_FORCE_RADIX_SWITCH` (spec §0.3). Prints the min
# and median of 3 timed runs and the bytes one run allocates. Not in SUITE.
#
#   [PATCH=1] julia -t T --project=<env with ChuiFrames developed> benchmark/calibrate/radix_switch.jl
#
# PATCH=1 first applies patch_concat.jl (a what-if, in this process only). Results:
# docs/research/performance-phase4.md P4-03.
using ChuiFrames, Statistics, Random, Printf
const CF = ChuiFrames
const PATCH = get(ENV, "PATCH", "0") == "1"
PATCH && include(joinpath(@__DIR__, "patch_concat.jl"))
println("PATCH=", PATCH ? 1 : 0)
n = 4_000_000
limits = PATCH ? [2^14, 2^16, 2^18, 2^20, 2^30] : [2^12, 2^14, 2^16, 2^18, 2^20, 2^30]
groups = [10_000, 100_000, 500_000, 2_000_000]
println("julia ", VERSION, " threads ", Threads.nthreads(), " n ", n, " load ", round.(Sys.loadavg(); digits = 2))
function measure(f, reps)
    f()
    ts = Float64[]
    bytes = 0
    for _ in 1:reps
        GC.gc()
        s = @timed f()
        push!(ts, s.time)
        bytes = s.bytes
    end
    return minimum(ts), median(ts), bytes
end
for kind in (:Int, :String), G in groups
    rng = Xoshiro(7)
    kv = rand(rng, 1:G, n)
    key = kind === :Int ? kv : string.("u", kv)
    f = Frame((key = key, x = randn(rng, n)))
    q = lazy(f) |> group_by(:key) |> summarise(sx = sum(c.x), cnt = n_rows())
    ref = nothing
    for L in limits
        CF._FORCE_RADIX_SWITCH[] = L
        r = collect(q)
        ref === nothing ? (ref = r) : @assert isequal(CF.getcol(r, :cnt), CF.getcol(ref, :cnt))
        tmin, tmed, b = measure(() -> collect(q), 3)
        @printf(
            "%-6s G=%-8d limit=2^%-2d  min %8.1f ms  med %8.1f ms  %8.1f MiB  load %.2f\n",
            kind, G, round(Int, log2(L)), 1.0e3tmin, 1.0e3tmed, b / 2^20, Sys.loadavg()[1]
        )
    end
    CF._FORCE_RADIX_SWITCH[] = 0
end
println("load after ", round.(Sys.loadavg(); digits = 2))
