# sort_share.jl: the order-restoring sort's share of shape-(b)/(c) joins (phase-4 spec §1.2 ★ K2,
# §5; the §7 trigger is 25 %). Instrumented in this process only: `ChuiFrames._sort_by_x` is
# replaced by a copy of its body that also records its own time and the time of one gather by
# the permutation (`px[perm]`; the shapes do two such gathers on the sorted pairs, so the share
# counts that gather twice). Shape (a) (broadcast build y) never sorts and is timed as the
# reference. Eager joins on the SUITE's `join_inputs` (1:1 and 1:n), 10^4 and 10^6 rows.
#
#   julia -t 1 --project=<env> benchmark/calibrate/sort_share.jl
#
# Results: docs/research/performance-phase4.md P4-06.
using ChuiFrames, Statistics, Random, Printf
const CF = ChuiFrames
include(joinpath(@__DIR__, "..", "benchmarks.jl"))   # join_inputs, forced
const SORT_NS = Ref(0)
const GATHER_NS = Ref(0)
const PAIRS = Ref(0)
const INSTRUMENT = Ref(false)
function sort_copy(px::Vector{Int}, nx::Int)   # verbatim body of src/engine/join.jl `_sort_by_x`
    counts = zeros(Int, nx + 1)
    @inbounds for x in px
        counts[x + 1] += 1
    end
    @inbounds for i in 2:(nx + 1)
        counts[i] += counts[i - 1]
    end
    perm = Vector{Int}(undef, length(px))
    @inbounds for (g, x) in enumerate(px)
        q = counts[x] + 1
        perm[q] = g
        counts[x] = q
    end
    return perm
end
@eval CF function _sort_by_x(px::Vector{Int}, nx::Int)
    $INSTRUMENT[] || return $sort_copy(px, nx)
    t0 = time_ns()
    perm = $sort_copy(px, nx)
    t1 = time_ns()
    g = px[perm]
    t2 = time_ns()
    $SORT_NS[] += t1 - t0
    $GATHER_NS[] += t2 - t1
    $PAIRS[] += length(g)
    return perm
end
println("julia ", VERSION, " threads ", Threads.nthreads(), " load ", round.(Sys.loadavg(); digits = 2))
function best(f, reps)
    f()
    t = Inf
    for _ in 1:reps
        GC.gc()
        t = min(t, @elapsed f())
    end
    return t
end
for n in (10_000, 1_000_000)
    J = join_inputs(n)
    reps = n == 10_000 ? 50 : 5
    for (verb, op) in (("inner", inner_join), ("left", left_join)), (card, x, y) in (("1:1", J.x11, J.y11), ("1:n", J.x1n, J.y1n))
        runm(m) = forced(() -> x |> op(y; by = :key), CF._FORCE_JOIN, m)
        ta = best(() -> runm(:broadcast_y), reps)
        for (shape, m) in (("b", :broadcast_x), ("c", :partitioned_y), ("c", :partitioned_x))
            T = best(() -> runm(m), reps)
            INSTRUMENT[] = true
            SORT_NS[] = 0
            GATHER_NS[] = 0
            PAIRS[] = 0
            for _ in 1:reps
                runm(m)
            end
            INSTRUMENT[] = false
            s = SORT_NS[] / reps / 1.0e9
            g = GATHER_NS[] / reps / 1.0e9
            @printf(
                "%-5s %-3s n=%-8d shape %s (%-13s) join %8.2f ms | sort %7.2f ms + 2 gathers %7.2f ms = %5.1f %% | shape a %8.2f ms | pairs %d | load %.2f\n",
                verb, card, n, shape, m, 1.0e3T, 1.0e3s, 2.0e3g, 100 * (s + 2g) / T, 1.0e3ta, PAIRS[] ÷ reps, Sys.loadavg()[1]
            )
        end
    end
end
println("load after ", round.(Sys.loadavg(); digits = 2))
