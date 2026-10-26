# broadcast_limits.jl: calibrates `BROADCAST_MAX_ROWS` / `BROADCAST_MAX_BYTES` (src/engine/join.jl;
# phase-4 spec §1.2, §5) and asks whether a parallel eager probe would help. Not in SUITE.
#
#   [PATCH=1] julia -t T --project=<env> benchmark/calibrate/broadcast_limits.jl         # part A
#   PARB=1    julia -t T --project=<env> benchmark/calibrate/broadcast_limits.jl         # part B
#
# Part A: an inner join of a 4·10^6-row probe side x (keys drawn from 1:b) against a build side
# y of b distinct keys, forced broadcast build y (shape a) against partitioned build y (shape c),
# eager and lazy, narrow (key + 1 Float64: 16 nominal bytes per row) and wide (key + 8 Float64:
# 72 bytes) build sides; min of 3 runs and the bytes one run allocates.
# Part B: the eager broadcast-build-y probe runs on the calling task at any size; here the same
# probe (src's `ProbeStep`, applied to contiguous slices of x sharing one `JoinBuild`) runs on k
# tasks and the slices are concatenated (internal API, this script only).
# PATCH=1 applies patch_concat.jl first. Results: docs/research/performance-phase4.md P4-04, P4-07.
using ChuiFrames, Statistics, Random, Printf
const CF = ChuiFrames
const PATCH = get(ENV, "PATCH", "0") == "1"
PATCH && include(joinpath(@__DIR__, "patch_concat.jl"))
println("julia ", VERSION, " threads ", Threads.nthreads(), " PATCH=", PATCH ? 1 : 0, " load ", round.(Sys.loadavg(); digits = 2))
function withjoin(f, m)
    CF._FORCE_JOIN[] = m
    try
        return f()
    finally
        CF._FORCE_JOIN[] = :auto
    end
end
function best(f, reps)
    f()
    t = Inf
    for _ in 1:reps
        GC.gc()
        t = min(t, @elapsed f())
    end
    return t
end
meas(f) = (f(); b = (@timed f()).bytes; (best(f, 3), b))

function part_a()
    nx = 4_000_000
    for width in (:narrow, :wide), b in (2^14, 2^16, 2^17, 2^18, 2^20, 2^22)
        rng = Xoshiro(11)
        x = Frame((key = rand(rng, 1:b, nx), a = randn(rng, nx)))
        y = if width === :narrow
            Frame((key = randperm(rng, b), v1 = rand(rng, b)))
        else
            Frame(
                (
                    key = randperm(rng, b), v1 = rand(rng, b), v2 = rand(rng, b), v3 = rand(rng, b), v4 = rand(rng, b),
                    v5 = rand(rng, b), v6 = rand(rng, b), v7 = rand(rng, b), v8 = rand(rng, b),
                )
            )
        end
        for (path, run) in ((:eager, () -> x |> inner_join(y; by = :key)), (:lazy, () -> collect(lazy(x) |> inner_join(lazy(y); by = :key))))
            tb, bb = meas(() -> withjoin(run, :broadcast_y))
            tp, bp = meas(() -> withjoin(run, :partitioned_y))
            @printf(
                "%-6s b=2^%-2d %-5s broadcast %8.1f ms %8.1f MiB | partitioned %8.1f ms %8.1f MiB | time part/broad %.2f  load %.2f\n",
                width, round(Int, log2(b)), path, 1.0e3tb, bb / 2^20, 1.0e3tp, bp / 2^20, tp / tb, Sys.loadavg()[1]
            )
        end
    end
    return nothing
end

function par_probe(x, y, k)
    s = inner_join(y; by = :key)
    names = CF._resolve_names(s, x.names, y.names; log = false)
    T = CF._join_compare_types(names, x, y)
    bld = CF.JoinBuild(y, CF._ykeys(names), T, false)
    p = CF.ProbeStep(:y, bld, s, names, false)
    n = CF.nrows(x)
    k == 1 && return CF.apply(p, x)
    parts = [CF.take(x, collect((div((i - 1) * n, k) + 1):div(i * n, k))) for i in 1:k]
    outs = Vector{Any}(undef, k)
    @sync for i in 1:k
        Threads.@spawn outs[i] = CF.apply(p, parts[i])
    end
    o1 = outs[1]
    cols = CF.AbstractColumn[CF.vcat_columns(CF.AbstractColumn[o.columns[j] for o in outs]) for j in eachindex(o1.columns)]
    return Frame(copy(o1.names), cols)
end

function part_b()
    for n in (2^14, 2^16, 2^18, 1_000_000, 4_000_000), b in (2^10, 2^17)
        rng = Xoshiro(3)
        x = Frame((key = rand(rng, 1:b, n), a = randn(rng, n)))
        y = Frame((key = randperm(rng, b), v1 = rand(rng, b)))
        @assert isequal(par_probe(x, y, 4), x |> inner_join(y; by = :key))
        t_auto = best(() -> withjoin(() -> x |> inner_join(y; by = :key), :broadcast_y), 5)
        ts = [best(() -> par_probe(x, y, k), 5) for k in (1, 2, 4, 6)]
        @printf(
            "nx=%-8d b=2^%-2d eager %8.2f ms | 1 task %8.2f  2 tasks %8.2f  4 tasks %8.2f  6 tasks %8.2f | best speed-up %.2f  load %.2f\n",
            n, round(Int, log2(b)), 1.0e3t_auto, (1.0e3 .* ts)..., ts[1] / minimum(ts[2:end]), Sys.loadavg()[1]
        )
    end
    return nothing
end

get(ENV, "PARB", "0") == "1" ? part_b() : part_a()
println("load after ", round.(Sys.loadavg(); digits = 2))
