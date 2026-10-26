# chui.jl: the db-benchmark-like queries on ChuiFrames, eager and lazy.
#
#   julia --project=<env with ChuiFrames developed> benchmark/compare/chui.jl DATADIR OUT.toml
#
# Runs against any ChuiFrames checkout the environment develops: a checkout without joins (main
# before phase 4) skips the join queries. Each query: one warm-up run, then `reps` timed runs
# (3, or 1 when the warm-up took over 20 s); the TOML row is [min_s, median_s, result_rows].
# Group-by results are sorted by key (ChuiFrames always sorts groups; the other tools do not).
using ChuiFrames
using Statistics: mean, median
using TOML: TOML

const DIR = ARGS[1]
const G1 = read_arrow(joinpath(DIR, "G1.arrow"))
const X = read_arrow(joinpath(DIR, "X.arrow"))
const SMALL = read_arrow(joinpath(DIR, "SMALL.arrow"))
const MEDIUM = read_arrow(joinpath(DIR, "MEDIUM.arrow"))

nr(f::Frame) = ChuiFrames.nrows(f)
function timeit(f)
    GC.gc()
    t0 = time()
    r = f()
    w = time() - t0
    reps = w > 20 ? 1 : 3
    ts = Float64[]
    for _ in 1:reps
        GC.gc()
        push!(ts, @elapsed f())
    end
    return [minimum(ts), median(ts), nr(r)]
end

const Q = Pair{String, Function}[
    "groupby q1 eager" => () -> G1 |> group_by(:id1) |> summarise(v1 = sum(c.v1)),
    "groupby q2 eager" => () -> G1 |> group_by(:id1, :id2) |> summarise(v1 = sum(c.v1)),
    "groupby q3 eager" => () -> G1 |> group_by(:id3) |> summarise(v1 = sum(c.v1), v3 = mean(c.v3)),
    "groupby q4 eager" => () -> G1 |> group_by(:id4) |> summarise(v1 = mean(c.v1), v2 = mean(c.v2), v3 = mean(c.v3)),
    "groupby q5 eager" => () -> G1 |> group_by(:id6) |> summarise(v1 = sum(c.v1), v2 = sum(c.v2), v3 = sum(c.v3)),
]
if isdefined(ChuiFrames, :lazy)
    append!(
        Q, [
            "groupby q1 lazy" => () -> collect(lazy(G1) |> group_by(:id1) |> summarise(v1 = sum(c.v1))),
            "groupby q2 lazy" => () -> collect(lazy(G1) |> group_by(:id1, :id2) |> summarise(v1 = sum(c.v1))),
            "groupby q3 lazy" => () -> collect(lazy(G1) |> group_by(:id3) |> summarise(v1 = sum(c.v1), v3 = mean(c.v3))),
            "groupby q4 lazy" => () -> collect(lazy(G1) |> group_by(:id4) |> summarise(v1 = mean(c.v1), v2 = mean(c.v2), v3 = mean(c.v3))),
            "groupby q5 lazy" => () -> collect(lazy(G1) |> group_by(:id6) |> summarise(v1 = sum(c.v1), v2 = sum(c.v2), v3 = sum(c.v3))),
        ]
    )
end
if isdefined(ChuiFrames, :inner_join)
    append!(
        Q, [
            "join q1 eager" => () -> X |> inner_join(SMALL; by = :id1),
            "join q2 eager" => () -> X |> inner_join(MEDIUM; by = :id2),
            "join q3 eager" => () -> X |> left_join(MEDIUM; by = :id2),
            "join q1r eager" => () -> SMALL |> inner_join(X; by = :id1),
            "join q1 lazy" => () -> collect(lazy(X) |> inner_join(lazy(SMALL); by = :id1)),
            "join q2 lazy" => () -> collect(lazy(X) |> inner_join(lazy(MEDIUM); by = :id2)),
            "join q3 lazy" => () -> collect(lazy(X) |> left_join(lazy(MEDIUM); by = :id2)),
            "join q1r lazy" => () -> collect(lazy(SMALL) |> inner_join(lazy(X); by = :id1)),
        ]
    )
end

load0 = Sys.loadavg()
rows = Dict{String, Any}()
for (name, f) in Q
    rows[name] = timeit(f)
    println(rpad(name, 20), " min ", round(rows[name][1]; digits = 3), " s  median ", round(rows[name][2]; digits = 3), " s  rows ", Int(rows[name][3]), "  load ", round(Sys.loadavg()[1]; digits = 2))
end
meta = Dict(
    "julia" => string(VERSION), "threads" => Threads.nthreads(), "chuiframes" => pathof(ChuiFrames),
    "load_before" => collect(load0), "load_after" => collect(Sys.loadavg()), "N" => nr(G1),
)
open(ARGS[2], "w") do io
    TOML.print(io, Dict("meta" => meta, "rows" => rows))
end
