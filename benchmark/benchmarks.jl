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
using Random: Xoshiro, randn, rand, randperm
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
    # The lazy engine (phase 3): the same pipeline planned, optimized (the filter is pushed into
    # the scan, the projection to 3 columns) and run over 65 536-row morsels; at 10 rows this is
    # the planning overhead. `head` after a pushed filter stops the scan early. (Skipped against a
    # base without the lazy engine.)
    isdefined(ChuiFrames, :lazy) || continue
    SUITE["lazy"]["filter, mutate, select"][sz] = @benchmarkable(
        collect(lazy($f) |> filter(c.y .> 0.5) |> mutate(z = c.x .* 2) |> select(:id, :z)), seconds = secs(n),
    )
    n == 10 || (
        SUITE["lazy"]["filter, head 10"][sz] = @benchmarkable(
            collect(lazy($f) |> filter(c.y .> 0.5) |> head(10)), seconds = secs(n),
        )
    )
end

# ---------------------------------------------------------------------------------------------
# Phase 4 (spec docs/superpowers/specs/2026-10-26-phase4-joins-groupby-codegen-design.md §5):
# the fast group-by (eager GroupIndex on typed keys; lazy hash-aggregate sink), joins under each
# forced strategy and build side, a compiled streamed stage. Each block is skipped against a base
# without the feature, so `julia scripts/ci.jl bench` still runs against main. The forcing
# switches (`_FORCE_JOIN`, `_FORCE_KERNEL`) and `DictColumn` are internal: the spec asks for each
# build side forced, and no public constructor builds a dictionary column from vectors yet.

"Run `f()` with the forcing switch `ref` set to `v`, restoring it after (one Ref read per call)."
function forced(f, ref::Ref{Symbol}, v::Symbol)
    old = ref[]
    ref[] = v
    try
        return f()
    finally
        ref[] = old
    end
end

# Group-by keys: Int, String, dictionary String (same values as `s`/`ss`, as a DictColumn with
# UInt32 codes) and a two-column key (Int, String); "few" = 10 groups, "many" = n ÷ 10 groups.
const GB_KEYS = (
    ("Int", (:k,), (:kk,)), ("String", (:s,), (:ss,)), ("Dict String", (:ds,), (:dss,)),
    ("Int, String", (:k, :s), (:kk, :ss)),
)
function gb_frame(n)
    cols = bench_columns(n)
    many = max(n ÷ 10, 1)
    D = ChuiFrames.DictColumn
    return Frame(
        (
            x = cols.x, y = cols.y, k = cols.k, s = cols.s, kk = cols.kk, ss = cols.ss,
            ds = D(UInt32.(cols.k), ChuiFrames.column(string.("s", 1:10))),
            dss = D(UInt32.(cols.kk), ChuiFrames.column(string.("u", 1:many))),
        )
    )
end
if isdefined(ChuiFrames, :DictColumn) && isdefined(ChuiFrames, :lazy)
    for n in SIZES
        g = gb_frame(n)
        sz = label(n)
        # Per-verb overhead (ADR-0022 rule 3): `group_by` alone on 10 rows.
        n == 10 && for (variant, few, _) in GB_KEYS
            SUITE["group_by"][variant][sz] = @benchmarkable $g |> group_by($(few)...) seconds = secs(n)
        end
        for (variant, few, many) in GB_KEYS, (ng, key) in (("few", few), ("many", many))
            n == 10 && ng == "many" && continue
            # Eager Int and String keys are the `summarise/*` rows above; here the new key kinds.
            if variant in ("Dict String", "Int, String")
                SUITE["groupby"]["$variant $ng, eager"][sz] = @benchmarkable(
                    $g |> group_by($(key)...) |> summarise(sx = sum(c.x), my = mean(c.y), cnt = n_rows()),
                    seconds = secs(n),
                )
            end
            n == 10 && continue
            # Lazy: the hash-aggregate sink (the summary is simple, the keys plain columns).
            SUITE["groupby"]["$variant $ng, lazy"][sz] = @benchmarkable(
                collect(lazy($g) |> group_by($(key)...) |> summarise(sx = sum(c.x), my = mean(c.y), cnt = n_rows())),
                seconds = secs(n),
            )
        end
    end
end

# Joins. 1:1: x and y hold n rows each, keys a permutation of 1:n each. 1:n: x holds n ÷ 10 rows
# with distinct keys, y n rows whose keys are drawn from x's (about 10 y rows per x row, so the
# output has about n rows and the order-restoring sort has runs to keep together).
function join_inputs(n; seed = 20261026)
    rng = Xoshiro(seed)
    m = max(n ÷ 10, 1)
    return (
        x11 = Frame((key = randperm(rng, n), a = randn(rng, n))),
        y11 = Frame((key = randperm(rng, n), b = rand(rng, n))),
        x1n = Frame((key = randperm(rng, m), a = randn(rng, m))),
        y1n = Frame((key = rand(rng, 1:m, n), b = rand(rng, n))),
    )
end
const JOIN_MODES = (
    ("broadcast build x", :broadcast_x), ("broadcast build y", :broadcast_y),
    ("partitioned build x", :partitioned_x), ("partitioned build y", :partitioned_y),
)
if isdefined(ChuiFrames, :inner_join) && isdefined(ChuiFrames, :_FORCE_JOIN)
    const FJ = ChuiFrames._FORCE_JOIN
    let J = join_inputs(10), sz = "n=10"
        # Per-verb overhead (ADR-0022 rule 3): every join verb on 10-row frames, strategy :auto.
        x, y = J.x11, J.y11
        for (verb, op) in (
                ("inner", inner_join), ("left", left_join), ("right", right_join), ("full", full_join),
                ("semi", semi_join), ("anti", anti_join), ("nest", nest_join),
            )
            SUITE["join"]["$verb, auto"][sz] = @benchmarkable $x |> $op($y; by = :key) seconds = 1.0
        end
        SUITE["join"]["cross, auto"][sz] = @benchmarkable $x |> cross_join($y) seconds = 1.0
    end
    for n in (10_000, 1_000_000)
        J = join_inputs(n)
        sz = label(n)
        for (verb, op) in (("inner", inner_join), ("left", left_join)),
                (card, x, y) in (("1:1", J.x11, J.y11), ("1:n", J.x1n, J.y1n)),
                (mode, sym) in JOIN_MODES
            SUITE["join"]["$verb $card, $mode"][sz] = @benchmarkable(
                forced(() -> $x |> $op($y; by = :key), $FJ, $sym), seconds = secs(n),
            )
        end
        let x = J.x11, y = J.y11
            SUITE["join"]["nest 1:1, auto"][sz] = @benchmarkable $x |> nest_join($y; by = :key) seconds = secs(n)
        end
        # Lazy, inner 1:n, each shape: (a) broadcast build y streams x, (b) broadcast build x
        # streams y with the order-restoring sort in the tail, (c) partitioned.
        n == 1_000_000 && for (mode, sym) in JOIN_MODES
            x, y = J.x1n, J.y1n
            SUITE["lazy"]["inner join 1:n, $mode"][sz] = @benchmarkable(
                forced(() -> collect(lazy($x) |> inner_join(lazy($y); by = :key)), $FJ, $sym),
                seconds = secs(n),
            )
        end
    end
    # Small x, large y (spec §5): 10^3 x rows with distinct keys, 10^6 y rows with keys in
    # 1:10^4 (about 10 % of y matches), strategy :auto (broadcast, build x).
    let rng = Xoshiro(20261027), sz = "n=10^6"
        xs = Frame((key = collect(1:1000), a = randn(rng, 1000)))
        yl = Frame((key = rand(rng, 1:10_000, 1_000_000), b = rand(rng, 1_000_000)))
        SUITE["join"]["inner small x (10^3), auto"][sz] = @benchmarkable $xs |> inner_join($yl; by = :key) seconds = 3.0
        SUITE["lazy"]["inner join small x (10^3), auto"][sz] = @benchmarkable(
            collect(lazy($xs) |> inner_join(lazy($yl); by = :key)), seconds = 3.0,
        )
        # A non-key `mutate` above x (critic pass-3 p1, spec §7): x's key types are then not
        # static, so x is collected before the join instead of streaming; the same work with the
        # `mutate` after the join is the comparison. x: 10^6 rows, keys in 1:10^4; y: 10^4 rows.
        xm = Frame((key = rand(rng, 1:10_000, 1_000_000), a = randn(rng, 1_000_000)))
        ym = Frame((key = collect(1:10_000), b = rand(rng, 10_000)))
        SUITE["lazy"]["inner join, non-key mutate before"][sz] = @benchmarkable(
            collect(lazy($xm) |> mutate(a2 = c.a .* 2) |> inner_join(lazy($ym); by = :key)), seconds = 3.0,
        )
        SUITE["lazy"]["inner join, non-key mutate after"][sz] = @benchmarkable(
            collect(lazy($xm) |> inner_join(lazy($ym); by = :key) |> mutate(a2 = c.a .* 2)), seconds = 3.0,
        )
    end
    let J = join_inputs(1000), x = J.x11, y = J.y11
        SUITE["join"]["cross, auto"]["n=10^3"] = @benchmarkable $x |> cross_join($y) seconds = 1.0
    end
end

# A compiled streamed stage at 10^6 rows (above INTERP_THRESHOLD, so `:auto` compiles it; the
# shape is cached after the first run), and the same stage forced through the interpreter.
if isdefined(ChuiFrames, :_FORCE_KERNEL)
    let f = FRAMES[1_000_000], sz = "n=10^6", FK = ChuiFrames._FORCE_KERNEL
        for (variant, sym) in (("compiled", :auto), ("interpreted", :interpreter))
            SUITE["lazy"]["mutate, filter, select stage, $variant"][sz] = @benchmarkable(
                forced(
                    () -> collect(lazy($f) |> mutate(z = c.x .* 2 .+ c.y) |> filter(c.z .> 0) |> select(:id, :z)),
                    $FK, $sym,
                ),
                seconds = 3.0,
            )
        end
    end
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
