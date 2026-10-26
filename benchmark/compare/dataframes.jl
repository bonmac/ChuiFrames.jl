# dataframes.jl: the db-benchmark-like queries on DataFrames.jl (same data, Arrow IPC input).
#
#   julia --project=<env with DataFrames, Arrow> benchmark/compare/dataframes.jl DATADIR OUT.toml
#
# Same timing protocol and TOML rows as chui.jl. `groupby(...; sort = true)` so the result order
# matches ChuiFrames' (sorted groups); `innerjoin`/`leftjoin` with `makeunique = true` for the
# clashing non-key columns.
using DataFrames, Arrow
using Statistics: mean, median
using TOML: TOML

const DIR = ARGS[1]
rd(name) = DataFrame(Arrow.Table(joinpath(DIR, name)); copycols = true)
const G1 = rd("G1.arrow")
const X = rd("X.arrow")
const SMALL = rd("SMALL.arrow")
const MEDIUM = rd("MEDIUM.arrow")

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
    return [minimum(ts), median(ts), nrow(r)]
end

const Q = Pair{String, Function}[
    "groupby q1" => () -> combine(groupby(G1, :id1; sort = true), :v1 => sum => :v1),
    "groupby q2" => () -> combine(groupby(G1, [:id1, :id2]; sort = true), :v1 => sum => :v1),
    "groupby q3" => () -> combine(groupby(G1, :id3; sort = true), :v1 => sum => :v1, :v3 => mean => :v3),
    "groupby q4" => () -> combine(groupby(G1, :id4; sort = true), :v1 => mean => :v1, :v2 => mean => :v2, :v3 => mean => :v3),
    "groupby q5" => () -> combine(groupby(G1, :id6; sort = true), :v1 => sum => :v1, :v2 => sum => :v2, :v3 => sum => :v3),
    "join q1" => () -> innerjoin(X, SMALL; on = :id1, makeunique = true),
    "join q2" => () -> innerjoin(X, MEDIUM; on = :id2, makeunique = true),
    "join q3" => () -> leftjoin(X, MEDIUM; on = :id2, makeunique = true),
    "join q1r" => () -> innerjoin(SMALL, X; on = :id1, makeunique = true),
]

load0 = Sys.loadavg()
rows = Dict{String, Any}()
for (name, f) in Q
    rows[name] = timeit(f)
    println(rpad(name, 12), " min ", round(rows[name][1]; digits = 3), " s  median ", round(rows[name][2]; digits = 3), " s  rows ", Int(rows[name][3]), "  load ", round(Sys.loadavg()[1]; digits = 2))
end
meta = Dict(
    "julia" => string(VERSION), "threads" => Threads.nthreads(), "dataframes" => string(pkgversion(DataFrames)),
    "load_before" => collect(load0), "load_after" => collect(Sys.loadavg()), "N" => nrow(G1),
)
open(ARGS[2], "w") do io
    TOML.print(io, Dict("meta" => meta, "rows" => rows))
end
