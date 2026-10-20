# ChuiFrames benchmark suite (ADR-0022; ecosystem ADR-0011). AirspeedVelocity, `julia
# scripts/ci.jl bench` and `benchmark/run.jl` all load this file and run `SUITE`, a BenchmarkTools
# group. Public API only, so the same file runs against the merge base. Inputs are built once here
# (fixed seeds), outside the timed expressions, and interpolated with `$`.
#
#   julia benchmark/run.jl [--check]                                  # table + budgets (ADR-0022)
#   benchpkg ChuiFrames --rev=main,dirty --path=. --filter=filter      # AirspeedVelocity (ADR-0011)
#
# Keys are `family/variant/n=<rows>`. Sizes: 10 rows (per-verb overhead, ADR-0003 rule 2), 10^4
# and 10^6 rows. The "many groups" variants skip 10 rows (there they equal "few groups"); the I/O
# family uses one mid-size frame of 10^5 rows. The comparison scripts for DataFrames.jl and Polars
# (docs/research/performance.md) run the same operations on the same data.
using BenchmarkTools
using ChuiFrames
using Random: Xoshiro, randn, rand
using Statistics: mean

const SUITE = BenchmarkGroup()

const SIZES = (10, 10_000, 1_000_000)
label(n) = n == 10 ? "n=10" : n == 10_000 ? "n=10^4" : n == 100_000 ? "n=10^5" : n == 1_000_000 ? "n=10^6" : "n=$n"
# Time per benchmark: enough samples for a stable median, the whole suite in about 4 minutes.
secs(n) = n <= 10_000 ? 1.0 : 3.0

"""
    bench_columns(n; seed = 20261020) -> NamedTuple

The benchmark input: `id` (1:n), `x` (standard normal), `y` (uniform [0, 1)), `k` and `s` (10
groups, Int and String), `kk` and `ss` (n ÷ 10 groups, Int and String). Same seed, same data on one
Julia version (Xoshiro streams are not promised stable across versions).
"""
function bench_columns(n; seed = 20261020)
    rng = Xoshiro(seed)
    many = max(n ÷ 10, 1)
    k = rand(rng, 1:10, n)
    kk = rand(rng, 1:many, n)
    return (
        id = collect(1:n), x = randn(rng, n), y = rand(rng, n), k = k, kk = kk,
        s = string.("s", k), ss = string.("u", kk),
    )
end

const FRAMES = Dict(n => Frame(bench_columns(n)) for n in SIZES)

for n in SIZES
    f = FRAMES[n]
    sz = label(n)
    SUITE["filter"]["x > 0"][sz] = @benchmarkable $f |> filter(c.x .> 0) seconds = secs(n)
    SUITE["select"]["2 columns"][sz] = @benchmarkable $f |> select(:x, :k) seconds = secs(n)
    SUITE["mutate"]["z = 2x + y"][sz] = @benchmarkable $f |> mutate(z = c.x .* 2 .+ c.y) seconds = secs(n)
    SUITE["arrange"]["Float64"][sz] = @benchmarkable $f |> arrange(c.x) seconds = secs(n)
    SUITE["arrange"]["Int, desc Float64"][sz] = @benchmarkable $f |> arrange(c.k, desc(c.x)) seconds = secs(n)
    SUITE["arrange"]["String"][sz] = @benchmarkable $f |> arrange(c.ss) seconds = secs(n)
    for (variant, key) in (("Int few", :k), ("String few", :s), ("Int many", :kk), ("String many", :ss))
        n == 10 && endswith(variant, "many") && continue
        SUITE["summarise"][variant][sz] = @benchmarkable(
            $f |> group_by($key) |> summarise(sx = sum(c.x), my = mean(c.y), cnt = n_rows()),
            seconds = secs(n),
        )
    end
    SUITE["window"]["row_number, cumsum by Int few"][sz] = @benchmarkable(
        $f |> group_by(:k) |> mutate(r = row_number(), cs = cumsum(c.x)), seconds = secs(n),
    )
    SUITE["distinct"]["Int, String"][sz] = @benchmarkable $f |> distinct(:k, :s) seconds = secs(n)
    SUITE["slice_head"]["n = 10"][sz] = @benchmarkable $f |> slice_head(n = 10) seconds = secs(n)
    SUITE["count_by"]["String few"][sz] = @benchmarkable $f |> count_by(:s) seconds = secs(n)
    SUITE["pipeline"]["filter, mutate, select"][sz] = @benchmarkable(
        $f |> filter(c.y .> 0.5) |> mutate(z = c.x .* 2) |> select(:id, :z), seconds = secs(n),
    )
end

# I/O: one mid-size frame (10^5 rows; Int, Float64 and String columns). The files read are written
# here once; the write benchmarks overwrite their own files.
const IO_N = 100_000
const IO_FRAME = let cols = bench_columns(IO_N)
    Frame((id = cols.id, x = cols.x, y = cols.y, k = cols.k, s = cols.ss))
end
const IO_DIR = mktempdir()
const IO_CSV = joinpath(IO_DIR, "in.csv")
const IO_ARROW = joinpath(IO_DIR, "in.arrow")
write_csv(IO_FRAME, IO_CSV)
write_arrow(IO_FRAME, IO_ARROW)
let sz = label(IO_N), out_csv = joinpath(IO_DIR, "out.csv"), out_arrow = joinpath(IO_DIR, "out.arrow")
    SUITE["io"]["read_csv"][sz] = @benchmarkable read_csv($IO_CSV) seconds = 3.0
    SUITE["io"]["write_csv"][sz] = @benchmarkable write_csv($IO_FRAME, $out_csv) seconds = 3.0
    SUITE["io"]["read_arrow"][sz] = @benchmarkable read_arrow($IO_ARROW) seconds = 3.0
    SUITE["io"]["write_arrow"][sz] = @benchmarkable write_arrow($IO_FRAME, $out_arrow) seconds = 3.0
end
