# partition_bits.jl: the partitioned join (shape c) at each partition-bit count p, to inform the
# formula `_partition_bits` (src/engine/join.jl: p = clamp(⌈log2 rows⌉ - 13, 4, 8) of the larger
# side). Calls the internal `_partitioned_join` directly with a chosen p (this script only).
# Inner join, x = 4·10^6 rows with keys in 1:b, y = b distinct keys, build y; min of 3 runs and
# the bytes one run allocates.
#
#   [PATCH=1] julia -t T --project=<env> benchmark/calibrate/partition_bits.jl
#
# Results: docs/research/performance-phase4.md P4-07.
using ChuiFrames, Random, Printf
const CF = ChuiFrames
const PATCH = get(ENV, "PATCH", "0") == "1"
PATCH && include(joinpath(@__DIR__, "patch_concat.jl"))
println("julia ", VERSION, " threads ", Threads.nthreads(), " PATCH=", PATCH ? 1 : 0, " load ", round.(Sys.loadavg(); digits = 2))
function best(f, reps)
    f()
    t = Inf
    for _ in 1:reps
        GC.gc()
        t = min(t, @elapsed f())
    end
    return t
end
nx = 4_000_000
for b in (2^14, 2^17, 2^20, 2^22)
    rng = Xoshiro(5)
    x = Frame((key = rand(rng, 1:b, nx), a = randn(rng, nx)))
    y = Frame((key = randperm(rng, b), v1 = rand(rng, b)))
    s = inner_join(y; by = :key)
    names = CF._resolve_names(s, x.names, y.names; log = false)
    T = CF._join_compare_types(names, x, y)
    pnow = CF._partition_bits(max(nx, b))
    for p in (2, 4, 6, 8, 10, 12)
        run() = CF._partitioned_join(s, names, x, y, T, :y, p, true)
        t = best(run, 3)
        bytes = (@timed run()).bytes
        @printf(
            "b=2^%-2d p=%-2d%s  %8.1f ms  %8.1f MiB  load %.2f\n",
            round(Int, log2(b)), p, p == pnow ? " (current formula)" : "                  ", 1.0e3t, bytes / 2^20, Sys.loadavg()[1]
        )
    end
end
println("load after ", round.(Sys.loadavg(); digits = 2))
