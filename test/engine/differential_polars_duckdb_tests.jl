# Differential tests of the eager verbs against Polars and DuckDB (tag :differential, plus
# :polars_duckdb to run this item alone: `julia scripts/ci.jl test -- polars_duckdb`). Python runs
# only through `uv` (pinned versions below), in a `mktempdir()`. The Julia side writes the fixed
# data as Arrow IPC with ChuiFrames' own writer (NaN, -0.0 and null survive the trip, checked
# below); Polars reads it natively, DuckDB through a pyarrow table. The results come back as a
# text file whose values are typed tokens (`f` + Python `repr` for floats, so NaN, -0.0 and ±Inf
# are exact; hex for strings).
#
# Each case is (name, frame, Julia pipeline, Polars expression on `df`, DuckDB SQL on the
# frame's table, Polars kind, DuckDB kind). A kind is :exact, or one or more encoded divergences
# (see `check` below). Every divergence is documented, with its cause, in
# docs/research/differentials-polars-duckdb.md. An encoded divergence that stops occurring fails
# the test, so the document cannot go stale silently.

@testitem "differential: Polars and DuckDB" tags = [:differential, :polars_duckdb] begin
    using Tables, Statistics
    const ⨟ = ChuiFrames.Upstream.:⨟

    const POLARS = "2.0.0"
    const DUCKDB = "1.5.6"
    const PYARROW = "26.0.0"

    function run_differential()
        uv = Sys.which("uv")
        if uv === nothing
            @info "differential: uv not found on PATH; skipping the Polars and DuckDB comparison"
            @test_skip false
            return
        end

        # ---- fixed data -----------------------------------------------------------------------------
        n = 40
        XS = Union{Missing, Float64}[1.5, NaN, missing, -0.0, 0.0, 3.0, -2.0, 1.0, Inf, -Inf]
        GS = Union{Missing, String}["a", "b", "c", missing]
        KS = Union{Missing, Float64}[0.0, -0.0, NaN, missing, 1.0]
        SS = Union{Missing, String}["b", "B", "a", "A", "Z", "z", "_", "1", "ab", "Ab", missing]
        d = (
            id = collect(1:n),
            g = Union{Missing, String}[GS[mod(i * 3, 4) + 1] for i in 1:n],
            k = Union{Missing, Float64}[KS[mod(i * 2 + div(i, 5), 5) + 1] for i in 1:n],
            x = Union{Missing, Float64}[XS[mod(i * 7, 10) + 1] for i in 1:n],
            y = [mod(i * 5, 7) - 3 for i in 1:n],
            s = Union{Missing, String}[SS[mod(i * 4, 11) + 1] for i in 1:n],
        )
        F = Union{Missing, Float64}
        S = Union{Missing, String}
        frames = Dict{String, Any}(
            "d" => d,
            "w" => (id = [1, 2, 3, 4], x_1 = F[1.5, missing, NaN, -2.0], x_2 = F[4.0, -0.0, missing, missing]),
            "lg" => (id = [2, 1, 2, 1, 3, 4], k = S["b", "a", "a", "c", "b", "c"], v = F[1.0, 2.0, NaN, missing, 5.0, -0.0]),
        )
        xnan(i) = !ismissing(d.x[i]) && isnan(d.x[i])
        xinf(i) = isequal(d.x[i], Inf)
        # -0.0 and 0.0 interleave in `k` (so a sort that split them would reorder rows)
        zs = [signbit(v) for v in d.k if !ismissing(v) && iszero(v)]
        @test any(zs) && !issorted(zs) && !issorted(zs; rev = true)

        # ---- cases ----------------------------------------------------------------------------------
        # Kinds (a Symbol, a Tuple, or a Vector of them):
        #   :exact                 same columns, same rows in the same order
        #   :error                 the engine raises (no equivalent); the error text is recorded
        #   (:jl_only, p)          rows whose input row satisfies predicate `p` (by `id`) appear
        #                          only in Julia; the rest match exactly
        #   (:fr_only, p)          the same, rows only in the foreign engine
        #   (:jl_only_missing, col) Julia's rows whose `col` is missing are absent in the foreign
        #                          result; the rest match exactly
        #   (:sort_tail, col)      arrange: same rows; the rows whose `col` is neither NaN nor
        #                          missing are in the same order; NaN/missing are placed differently
        #   (:nan_rows, col, cols) rows whose input `col` is NaN differ in `cols`; all else matches
        #   (:cols, cols)          the named columns differ (each must really differ); all else matches
        kn(c) = (:nan_rows, :x, c)
        cases = [
            # filter (ADR-0002 rule 12: IEEE comparisons; Polars and DuckDB order NaN above +Inf)
            ("filter_gt", "d", filter(c.x .> 1), "df.filter(pl.col('x') > 1)", "SELECT * FROM d WHERE x > 1 ORDER BY id", (:fr_only, xnan), (:fr_only, xnan)),
            (   # DuckDB on the registered Arrow view: the pushed-down filter uses IEEE NaN semantics
                "duckdb_arrow_pushdown", "d", filter(c.x .> 1), "df.filter(pl.col('x') > 1)",
                "SELECT * FROM d_arrow WHERE x > 1 ORDER BY id", (:fr_only, xnan), :exact,
            ),
            ("filter_not_gt", "d", filter(.!(c.x .> 1)), "df.filter(~(pl.col('x') > 1))", "SELECT * FROM d WHERE NOT (x > 1) ORDER BY id", (:jl_only, xnan), (:jl_only, xnan)),
            ("filter_ne", "d", filter(c.x .!= 1), "df.filter(pl.col('x') != 1)", "SELECT * FROM d WHERE x <> 1 ORDER BY id", :exact, :exact),
            ("filter_le", "d", filter(c.x .<= 0), "df.filter(pl.col('x') <= 0)", "SELECT * FROM d WHERE x <= 0 ORDER BY id", :exact, :exact),
            ("filter_isnan", "d", filter(isnan.(c.x)), "df.filter(pl.col('x').is_nan())", "SELECT * FROM d WHERE isnan(x) ORDER BY id", :exact, :exact),
            ("filter_and", "d", filter(c.x .> -3, c.y .>= 0), "df.filter(pl.col('x') > -3, pl.col('y') >= 0)", "SELECT * FROM d WHERE x > -3 AND y >= 0 ORDER BY id", (:fr_only, xnan), (:fr_only, xnan)),
            ("filter_empty", "d", filter(c.y .> 100), "df.filter(pl.col('y') > 100)", "SELECT * FROM d WHERE y > 100", :exact, :exact),
            ("filter_out", "d", filter_out(c.x .> 1), "df.remove(pl.col('x') > 1)", "SELECT * FROM d WHERE (x > 1) IS NOT TRUE ORDER BY id", (:jl_only, xnan), (:jl_only, xnan)),
            (
                "filter_grouped", "d", group_by(:g) ⨟ filter(c.y .== maximum(c.y)) ⨟ ungroup(),
                "df.filter(pl.col('y') == pl.col('y').max().over('g'))",
                "SELECT * FROM d QUALIFY y = max(y) OVER (PARTITION BY g) ORDER BY id", :exact, :exact,
            ),
            # select / rename / relocate
            (
                "select_rename", "d", select(:y, :g) ⨟ rename(G = :g) ⨟ relocate(:G),
                "df.select('y', 'g').rename({'g': 'G'}).select('G', 'y')", "SELECT g AS G, y FROM d ORDER BY id", :exact, :exact,
            ),
            # mutate
            (
                "mutate_arith", "d", mutate(a = c.x .* 2 .+ c.y, b = c.y ./ 2, z = c.x .* 0) ⨟ select(:id, :a, :b, :z),
                "df.with_columns(a = pl.col('x') * 2 + pl.col('y'), b = pl.col('y') / 2, z = pl.col('x') * 0).select('id', 'a', 'b', 'z')",
                "SELECT id, x * 2 + y AS a, y / 2 AS b, x * 0 AS z FROM d ORDER BY id", :exact, :exact,
            ),
            (   # Julia: div truncates, fld/mod floor; Polars // and % floor; DuckDB // truncates, % truncates
                "mutate_intdiv", "d", mutate(dv = div.(c.y, 2), fd = fld.(c.y, 2), md = mod.(c.y, 3), rm = rem.(c.y, 3)) ⨟ select(:id, :dv, :fd, :md, :rm),
                "df.select('id', dv = (pl.col('y') / 2).cast(pl.Int64), fd = pl.col('y') // 2, md = pl.col('y') % 3, rm = pl.col('y') - (pl.col('y') / 3).cast(pl.Int64) * 3)",
                "SELECT id, y // 2 AS dv, floor(y / 2)::BIGINT AS fd, ((y % 3) + 3) % 3 AS md, y % 3 AS rm FROM d ORDER BY id", :exact, :exact,
            ),
            (   # the same operators under their native names: Polars % floors, DuckDB % truncates
                "mutate_native_mod", "d", mutate(m = mod.(c.y, 3), q = div.(c.y, 2)) ⨟ select(:id, :m, :q),
                "df.select('id', m = pl.col('y') % 3, q = pl.col('y') // 2)",
                "SELECT id, y % 3 AS m, y // 2 AS q FROM d ORDER BY id", (:cols, [:q]), (:cols, [:m]),
            ),
            (
                "mutate_missing", "d", mutate(a = c.x .+ c.y, b = coalesce.(c.x, 0.0), e = c.x .== c.x) ⨟ select(:id, :a, :b, :e),
                "df.select('id', a = pl.col('x') + pl.col('y'), b = pl.col('x').fill_null(0.0), e = pl.col('x') == pl.col('x'))",
                "SELECT id, x + y AS a, coalesce(x, 0.0) AS b, x = x AS e FROM d ORDER BY id", kn([:e]), kn([:e]),
            ),
            (
                "case_when", "d", mutate(cw = case_when((c.x .> 1) => "big", (c.x .<= 0) => "neg"; default = "other")) ⨟ select(:id, :cw),
                "df.select('id', cw = pl.when(pl.col('x') > 1).then(pl.lit('big')).when(pl.col('x') <= 0).then(pl.lit('neg')).otherwise(pl.lit('other')))",
                "SELECT id, CASE WHEN x > 1 THEN 'big' WHEN x <= 0 THEN 'neg' ELSE 'other' END AS cw FROM d ORDER BY id", kn([:cw]), kn([:cw]),
            ),
            (
                "if_else", "d", mutate(ie = ifelse.(c.y .> 0, "pos", "nonpos"), sg = sign.(c.y)) ⨟ select(:id, :ie, :sg),
                "df.select('id', ie = pl.when(pl.col('y') > 0).then(pl.lit('pos')).otherwise(pl.lit('nonpos')), sg = pl.col('y').sign())",
                "SELECT id, if(y > 0, 'pos', 'nonpos') AS ie, sign(y) AS sg FROM d ORDER BY id", :exact, :exact,
            ),
            # arrange (ADR-0002 rule 13: NaN and missing tied at the end in both directions; ±0 tied)
            (
                "arrange_x", "d", arrange(c.x) ⨟ select(:id),
                "df.sort('x', nulls_last=True, maintain_order=True).select('id')",
                "SELECT id FROM d ORDER BY x NULLS LAST, id", (:sort_tail, :x), (:sort_tail, :x),
            ),
            (
                "arrange_desc", "d", arrange(desc(c.x)) ⨟ select(:id),
                "df.sort('x', descending=True, nulls_last=True, maintain_order=True).select('id')",
                "SELECT id FROM d ORDER BY x DESC NULLS LAST, id", (:sort_tail, :x), (:sort_tail, :x),
            ),
            (
                "arrange_k", "d", arrange(c.k) ⨟ select(:id),
                "df.sort('k', nulls_last=True, maintain_order=True).select('id')",
                "SELECT id FROM d ORDER BY k NULLS LAST, id", (:sort_tail, :k), (:sort_tail, :k),
            ),
            (
                "arrange_multi", "d", arrange(c.g, desc(c.y), c.s) ⨟ select(:id),
                "df.sort(['g', 'y', 's'], descending=[False, True, False], nulls_last=True, maintain_order=True).select('id')",
                "SELECT id FROM d ORDER BY g NULLS LAST, y DESC, s NULLS LAST, id", :exact, :exact,
            ),
            (
                "arrange_strings", "d", arrange(c.s) ⨟ select(:id, :s),
                "df.sort('s', nulls_last=True, maintain_order=True).select('id', 's')",
                "SELECT id, s FROM d ORDER BY s NULLS LAST, id", :exact, :exact,
            ),
            # distinct
            (
                "distinct_gk", "d", distinct(:g, :k),
                "df.unique(['g', 'k'], keep='first', maintain_order=True).select('g', 'k')",
                "SELECT g, k FROM d GROUP BY g, k ORDER BY min(id)", :exact, :exact,
            ),
            (
                "distinct_x", "d", distinct(:x),
                "df.unique(['x'], keep='first', maintain_order=True).select('x')",
                "SELECT x FROM d GROUP BY x ORDER BY min(id)", :exact, :exact,
            ),
            (   # the first zero seen in `k` is -0.0 (in `x` it is 0.0); all three show the first seen
                "distinct_k", "d", distinct(:k),
                "df.unique(['k'], keep='first', maintain_order=True).select('k')",
                "SELECT k FROM d GROUP BY k ORDER BY min(id)", :exact, :exact,
            ),
            (   # DuckDB's ORDER BY returns the sort column's -0.0 values as 0.0
                "arrange_zero_values", "d", arrange(c.x) ⨟ filter(c.x .== 0) ⨟ select(:id, :x),
                "df.sort('x', maintain_order=True).filter(pl.col('x') == 0).select('id', 'x')",
                "SELECT id, x FROM d WHERE x = 0 ORDER BY x, id", :exact, (:cols, [:x]),
            ),
            # slices (dplyr: grouped slices come out in group-key order; the foreign side sorts by it)
            (
                "slice_head", "d", group_by(:g) ⨟ slice_head(n = 2) ⨟ ungroup() ⨟ select(:id),
                "df.group_by('g', maintain_order=True).head(2).sort('g', nulls_last=True, maintain_order=True).select('id')",
                "SELECT id FROM d QUALIFY row_number() OVER (PARTITION BY g ORDER BY id) <= 2 ORDER BY g NULLS LAST, id", :exact, :exact,
            ),
            (
                "slice_tail", "d", group_by(:g) ⨟ slice_tail(n = 1) ⨟ ungroup() ⨟ select(:id),
                "df.group_by('g', maintain_order=True).tail(1).sort('g', nulls_last=True, maintain_order=True).select('id')",
                "SELECT id FROM d QUALIFY row_number() OVER (PARTITION BY g ORDER BY id DESC) <= 1 ORDER BY g NULLS LAST, id", :exact, :exact,
            ),
            (
                "slice_min_ties", "d", group_by(:g) ⨟ slice_min(c.y; n = 2) ⨟ ungroup() ⨟ select(:id),
                "df.filter(pl.col('y').rank('min').over('g') <= 2).sort(['g', 'y'], nulls_last=True, maintain_order=True).select('id')",
                "SELECT id FROM d QUALIFY rank() OVER (PARTITION BY g ORDER BY y) <= 2 ORDER BY g NULLS LAST, y, id", :exact, :exact,
            ),
            (
                "slice_max_noties", "d", slice_max(c.y; n = 3, with_ties = false) ⨟ select(:id),
                "df.sort('y', descending=True, maintain_order=True).head(3).select('id')",
                "SELECT id FROM d ORDER BY y DESC, id LIMIT 3", :exact, :exact,
            ),
            (
                "slice_min_x", "d", slice_min(c.x; n = 4) ⨟ select(:id),
                "df.filter(pl.col('x').rank('min') <= 4).sort('x', maintain_order=True).select('id')",
                "SELECT id FROM d QUALIFY rank() OVER (ORDER BY x) <= 4 ORDER BY x, id", :exact, :exact,
            ),
            (
                "slice_max_x", "d", slice_max(c.x; n = 3) ⨟ select(:id),
                "df.filter(pl.col('x').rank('min', descending=True) <= 3).sort('x', descending=True, maintain_order=True).select('id')",
                "SELECT id FROM d WHERE x IS NOT NULL QUALIFY rank() OVER (ORDER BY x DESC) <= 3 ORDER BY x DESC, id", [(:fr_only, xnan), (:jl_only, xinf)], [(:fr_only, xnan), (:jl_only, xinf)],
            ),
            # count
            (
                "count_g", "d", count_by(:g),
                "df.group_by('g').agg(n = pl.len()).sort('g', nulls_last=True)",
                "SELECT g, count(*) AS n FROM d GROUP BY g ORDER BY g NULLS LAST", :exact, :exact,
            ),
            (
                "count_k_sorted", "d", count_by(:k; sort = true),
                "df.group_by('k').agg(n = pl.len()).sort('k', nulls_last=True).sort('n', descending=True, maintain_order=True)",
                "SELECT k, count(*) AS n FROM d GROUP BY k ORDER BY n DESC, k NULLS LAST", :exact, (:cols, [:k]),
            ),
            (
                "count_wt", "d", count_by(:g; wt = c.y),
                "df.group_by('g').agg(n = pl.col('y').sum()).sort('g', nulls_last=True)",
                "SELECT g, sum(y) AS n FROM d GROUP BY g ORDER BY g NULLS LAST", :exact, :exact,
            ),
            (
                "add_count", "d", add_count(:g) ⨟ select(:id, :n),
                "df.select('id', n = pl.len().over('g'))",
                "SELECT id, count(*) OVER (PARTITION BY g) AS n FROM d ORDER BY id", :exact, :exact,
            ),
            # group_by + summarise
            (
                "summarise_y", "d",
                group_by(:g) ⨟ summarise(n = n_rows(), s = sum(c.y), m = mean(c.y), mn = minimum(c.y), mx = maximum(c.y), v = var(c.y), sd = std(c.y), md = median(c.y)),
                "df.group_by('g').agg(n = pl.len(), s = pl.col('y').sum(), m = pl.col('y').mean(), mn = pl.col('y').min(), mx = pl.col('y').max(), v = pl.col('y').var(), sd = pl.col('y').std(), md = pl.col('y').median()).sort('g', nulls_last=True)",
                "SELECT g, count(*) AS n, sum(y) AS s, avg(y) AS m, min(y) AS mn, max(y) AS mx, var_samp(y) AS v, stddev_samp(y) AS sd, median(y) AS md FROM d GROUP BY g ORDER BY g NULLS LAST", :exact, :exact,
            ),
            (   # first/last/n_distinct over a column holding NaN, missing and ±0
                "summarise_x_order", "d",
                group_by(:g) ⨟ summarise(f = first(c.x), l = last(c.x), nd = n_distinct(c.x)),
                "df.group_by('g').agg(f = pl.col('x').first(), l = pl.col('x').last(), nd = pl.col('x').n_unique()).sort('g', nulls_last=True)",
                "SELECT g, first(x ORDER BY id) AS f, last(x ORDER BY id) AS l, count(DISTINCT x) AS nd FROM d GROUP BY g ORDER BY g NULLS LAST", :exact, (:cols, [:nd]),
            ),
            (   # reductions over NaN and missing: Julia propagates both unless skipmissing is asked for
                "summarise_x_stats", "d",
                group_by(:g) ⨟ summarise(s = sum(c.x), m = mean(c.x), mn = minimum(c.x), mx = maximum(c.x)),
                "df.group_by('g').agg(s = pl.col('x').sum(), m = pl.col('x').mean(), mn = pl.col('x').min(), mx = pl.col('x').max()).sort('g', nulls_last=True)",
                "SELECT g, sum(x) AS s, avg(x) AS m, min(x) AS mn, max(x) AS mx FROM d GROUP BY g ORDER BY g NULLS LAST",
                (:cols, [:s, :m, :mn, :mx]), (:cols, [:s, :m, :mn, :mx]),
            ),
            (   # skipmissing = SQL/Polars null skipping; min/max still differ on NaN
                "summarise_x_skip", "d",
                group_by(:g) ⨟ summarise(s = sum(skipmissing(c.x)), m = mean(skipmissing(c.x)), mn = minimum(skipmissing(c.x)), mx = maximum(skipmissing(c.x))),
                "df.group_by('g').agg(s = pl.col('x').sum(), m = pl.col('x').mean(), mn = pl.col('x').min(), mx = pl.col('x').max()).sort('g', nulls_last=True)",
                "SELECT g, sum(x) AS s, avg(x) AS m, min(x) AS mn, max(x) AS mx FROM d GROUP BY g ORDER BY g NULLS LAST",
                (:cols, [:mn, :mx]), (:cols, [:mn]),
            ),
            (   # Polars' NaN-propagating nan_min / nan_max are Julia's minimum / maximum
                "summarise_x_nanprop", "d",
                group_by(:g) ⨟ summarise(mn = minimum(skipmissing(c.x)), mx = maximum(skipmissing(c.x))),
                "df.group_by('g').agg(mn = pl.col('x').nan_min(), mx = pl.col('x').nan_max()).sort('g', nulls_last=True)",
                "SELECT g, CASE WHEN bool_or(isnan(x)) THEN 'NaN'::DOUBLE ELSE min(x) END AS mn, max(x) AS mx FROM d GROUP BY g ORDER BY g NULLS LAST",
                :exact, :exact,
            ),
            (
                "summarise_k", "d", group_by(:k) ⨟ summarise(n = n_rows(), s = sum(c.y)),
                "df.group_by('k').agg(n = pl.len(), s = pl.col('y').sum()).sort('k', nulls_last=True)",
                "SELECT k, count(*) AS n, sum(y) AS s FROM d GROUP BY k ORDER BY k NULLS LAST", :exact, (:cols, [:k]),
            ),
            (
                "summarise_gk", "d", group_by(:g, :k) ⨟ summarise(n = n_rows()) ⨟ ungroup(),
                "df.group_by('g', 'k').agg(n = pl.len()).sort(['g', 'k'], nulls_last=True)",
                "SELECT g, k, count(*) AS n FROM d GROUP BY g, k ORDER BY g NULLS LAST, k NULLS LAST", :exact, (:cols, [:k]),
            ),
            (
                "summarise_empty_grouped", "d", filter(c.y .> 100) ⨟ group_by(:g) ⨟ summarise(n = n_rows(), s = sum(c.y)),
                "df.filter(pl.col('y') > 100).group_by('g').agg(n = pl.len(), s = pl.col('y').sum())",
                "SELECT g, count(*) AS n, sum(y) AS s FROM d WHERE y > 100 GROUP BY g", :exact, :exact,
            ),
            (
                "summarise_empty", "d", filter(c.y .> 100) ⨟ summarise(n = n_rows(), s = sum(c.y), m = mean(c.y)),
                "df.filter(pl.col('y') > 100).select(n = pl.len(), s = pl.col('y').sum(), m = pl.col('y').mean())",
                "SELECT count(*) AS n, sum(y) AS s, avg(y) AS m FROM d WHERE y > 100", (:cols, [:m]), (:cols, [:s, :m]),
            ),
            (
                "summarise_singleton", "d", filter(c.id .<= 3) ⨟ group_by(:id) ⨟ summarise(v = var(c.y), sd = std(c.y), md = median(c.y)),
                "df.filter(pl.col('id') <= 3).group_by('id').agg(v = pl.col('y').var(), sd = pl.col('y').std(), md = pl.col('y').median()).sort('id')",
                "SELECT id, var_samp(y) AS v, stddev_samp(y) AS sd, median(y) AS md FROM d WHERE id <= 3 GROUP BY id ORDER BY id", :exact, :exact,
            ),
            # grouped windows
            (
                "window", "d",
                group_by(:g) ⨟ mutate(dm = c.y .- mean(c.y), r = row_number(), l = lag(c.y), ld = lead(c.y, 1; default = 0), cs = cumsum(c.y), cm = cummean(c.y)) ⨟ ungroup() ⨟ select(:id, :dm, :r, :l, :ld, :cs, :cm),
                "df.select('id', dm = (pl.col('y') - pl.col('y').mean()).over('g'), r = (pl.int_range(pl.len()) + 1).over('g'), l = pl.col('y').shift(1).over('g'), ld = pl.col('y').shift(-1, fill_value=0).over('g'), cs = pl.col('y').cum_sum().over('g'), cm = (pl.col('y').cum_sum() / pl.col('y').cum_count()).over('g'))",
                "SELECT id, y - avg(y) OVER (PARTITION BY g) AS dm, row_number() OVER w AS r, lag(y) OVER w AS l, lead(y, 1, 0) OVER w AS ld, sum(y) OVER w AS cs, avg(y) OVER w AS cm FROM d WINDOW w AS (PARTITION BY g ORDER BY id ROWS BETWEEN UNBOUNDED PRECEDING AND CURRENT ROW) ORDER BY id",
                :exact, :exact,
            ),
            (
                "ranks_y", "d", group_by(:g) ⨟ mutate(rn = row_number(c.y), mr = min_rank(c.y), dr = dense_rank(c.y), md = min_rank(desc(c.y))) ⨟ ungroup() ⨟ select(:id, :rn, :mr, :dr, :md),
                "df.select('id', rn = pl.col('y').rank('ordinal').over('g'), mr = pl.col('y').rank('min').over('g'), dr = pl.col('y').rank('dense').over('g'), md = pl.col('y').rank('min', descending=True).over('g'))",
                "SELECT id, row_number() OVER (PARTITION BY g ORDER BY y, id) AS rn, rank() OVER (PARTITION BY g ORDER BY y) AS mr, dense_rank() OVER (PARTITION BY g ORDER BY y) AS dr, rank() OVER (PARTITION BY g ORDER BY y DESC) AS md FROM d ORDER BY id",
                :exact, :exact,
            ),
            (   # ranks of a column with NaN, missing and ±0 (missing keeps a missing rank)
                "ranks_x", "d", mutate(rn = row_number(c.x), mr = min_rank(c.x), dr = dense_rank(c.x)) ⨟ select(:id, :rn, :mr, :dr),
                "df.select('id', rn = pl.col('x').rank('ordinal'), mr = pl.col('x').rank('min'), dr = pl.col('x').rank('dense'))",
                "SELECT id, CASE WHEN x IS NULL THEN NULL ELSE row_number() OVER (PARTITION BY x IS NULL ORDER BY x, id) END AS rn, CASE WHEN x IS NULL THEN NULL ELSE rank() OVER (PARTITION BY x IS NULL ORDER BY x) END AS mr, CASE WHEN x IS NULL THEN NULL ELSE dense_rank() OVER (PARTITION BY x IS NULL ORDER BY x) END AS dr FROM d ORDER BY id",
                kn([:rn, :mr, :dr]), kn([:rn, :mr, :dr]),
            ),
            (
                "rank_tail_y", "d", mutate(pr = percent_rank(c.y), cd = cume_dist(c.y), nt = ntile(c.y, 3)) ⨟ select(:id, :pr, :cd, :nt),
                "df.select('id', pr = (pl.col('y').rank('min') - 1) / (pl.len() - 1), cd = pl.col('y').rank('max') / pl.len(), nt = ((pl.col('y').rank('ordinal') - 1) * 3 // pl.len() + 1))",
                "SELECT id, percent_rank() OVER (ORDER BY y) AS pr, cume_dist() OVER (ORDER BY y) AS cd, ntile(3) OVER (ORDER BY y, id) AS nt FROM d ORDER BY id",
                :exact, :exact,
            ),
            (
                "rank_tail_grouped", "d", group_by(:g) ⨟ mutate(pr = percent_rank(c.y), cd = cume_dist(c.y), nt = ntile(c.y, 2)) ⨟ ungroup() ⨟ select(:id, :pr, :cd, :nt),
                "df.select('id', pr = ((pl.col('y').rank('min') - 1) / (pl.len() - 1)).over('g'), cd = (pl.col('y').rank('max') / pl.len()).over('g'), nt = ((pl.col('y').rank('ordinal') - 1) * 2 // pl.len() + 1).over('g'))",
                "SELECT id, percent_rank() OVER (PARTITION BY g ORDER BY y) AS pr, cume_dist() OVER (PARTITION BY g ORDER BY y) AS cd, ntile(2) OVER (PARTITION BY g ORDER BY y, id) AS nt FROM d ORDER BY id",
                :exact, :exact,
            ),
            # tidyr pivots
            (
                "pivot_longer", "w", pivot_longer(r"^x"),
                "df.unpivot(index='id', on=['x_1', 'x_2'], variable_name='name', value_name='value').sort('id', maintain_order=True)",
                "SELECT * FROM (UNPIVOT w ON x_1, x_2 INTO NAME name VALUE value) ORDER BY id, name", :exact, (:jl_only_missing, :value),
            ),
            (
                "pivot_longer_include_nulls", "w", pivot_longer(r"^x"),
                "df.unpivot(index='id', on=['x_1', 'x_2'], variable_name='name', value_name='value').sort('id', maintain_order=True)",
                "SELECT id, name, value FROM w UNPIVOT INCLUDE NULLS (value FOR name IN (x_1, x_2)) ORDER BY id, name", :exact, :exact,
            ),
            (
                "pivot_longer_drop_na", "w", pivot_longer(r"^x"; values_drop_na = true),
                "df.unpivot(index='id', on=['x_1', 'x_2'], variable_name='name', value_name='value').drop_nulls('value').sort('id', maintain_order=True)",
                "SELECT * FROM (UNPIVOT w ON x_1, x_2 INTO NAME name VALUE value) ORDER BY id, name", :exact, :exact,
            ),
            (
                "pivot_wider", "lg", pivot_wider(names_from = :k, values_from = :v, id_cols = :id),
                "df.pivot(on='k', index='id', values='v')",
                "WITH t AS (SELECT *, row_number() OVER () AS rn FROM lg), o AS (SELECT id, min(rn) AS r FROM t GROUP BY id), p AS (PIVOT (SELECT id, k, v FROM t) ON k IN ('b', 'a', 'c') USING first(v) GROUP BY id) SELECT p.* FROM p JOIN o ON p.id = o.id ORDER BY o.r",
                :exact, :exact,
            ),
            (
                "pivot_wider_sorted", "lg", pivot_wider(names_from = :k, values_from = :v, id_cols = :id, names_sort = true),
                "df.pivot(on='k', index='id', values='v', sort_columns=True)",
                "WITH t AS (SELECT *, row_number() OVER () AS rn FROM lg), o AS (SELECT id, min(rn) AS r FROM t GROUP BY id), p AS (PIVOT (SELECT id, k, v FROM t) ON k USING first(v) GROUP BY id) SELECT p.* FROM p JOIN o ON p.id = o.id ORDER BY o.r",
                :exact, :exact,
            ),
        ]

        # ---- run Python once ------------------------------------------------------------------------
        dir = mktempdir()
        for (nm, t) in frames
            write_arrow(t, joinpath(dir, nm * ".arrow"))
        end
        pystr(s) = "r'''" * s * "'''"
        pycases = join(["    ($(pystr(nm)), $(pystr(fr)), $(pystr(px)), $(pystr(sx)))," for (nm, fr, _, px, sx, _, _) in cases], "\n")
        py = """
        import sys, decimal
        import pyarrow.ipc as ipc
        import polars as pl
        import duckdb
        assert pl.__version__ == "$POLARS", pl.__version__
        assert duckdb.__version__ == "$DUCKDB", duckdb.__version__
        dirp = sys.argv[1]
        tabs = {nm: ipc.open_file(f"{dirp}/{nm}.arrow").read_all() for nm in $(repr(collect(keys(frames))))}
        con = duckdb.connect()
        for nm, t in tabs.items():
            # native tables: a WHERE on the registered Arrow view is pushed into the Arrow scan,
            # which compares NaN as IEEE does (case duckdb_arrow_pushdown)
            con.register(nm + "_arrow", t)
            con.sql(f"CREATE TABLE {nm} AS SELECT * FROM {nm}_arrow")
        dfs = {nm: pl.from_arrow(t) for nm, t in tabs.items()}
        CASES = [
        $pycases
        ]
        def enc(v):
            if v is None: return "N"
            if isinstance(v, bool): return "T" if v else "F"
            if isinstance(v, int): return "i" + str(v)
            if isinstance(v, float): return "f" + repr(v)
            if isinstance(v, decimal.Decimal): return "f" + repr(float(v))
            if isinstance(v, str): return "s" + v.encode().hex()
            return "?" + repr(v).encode().hex()
        hx = lambda s: str(s).encode().hex()
        with open(f"{dirp}/out.txt", "w") as out:
            out.write(f"VERSIONS\\t{pl.__version__}\\t{duckdb.__version__}\\t{sys.version.split()[0]}\\n")
            # the round trip of the input values themselves
            for nm, df in dfs.items():
                out.write(f"CASE\\tinput\\t{nm}\\t{df.height}\\n")
                for c in df.columns:
                    out.write("COL\\t" + c + "\\t" + "|".join(enc(v) for v in df[c].to_list()) + "\\n")
            for name, frame, pexpr, sql in CASES:
                for eng in ("polars", "duckdb"):
                    try:
                        if eng == "polars":
                            r = eval(pexpr, {"pl": pl, "df": dfs[frame]})
                            cols = [(c, r[c].to_list()) for c in r.columns]
                            nrow = r.height
                        else:
                            t = con.sql(sql).fetch_arrow_table()
                            cols = list(zip(t.column_names, [col.to_pylist() for col in t.columns]))
                            nrow = t.num_rows
                    except Exception as e:
                        out.write(f"ERR\\t{eng}\\t{name}\\t{hx(type(e).__name__ + ': ' + str(e).splitlines()[0][:300])}\\n")
                        continue
                    out.write(f"CASE\\t{eng}\\t{name}\\t{nrow}\\n")
                    for c, vals in cols:
                        out.write("COL\\t" + c + "\\t" + "|".join(enc(v) for v in vals) + "\\n")
        """
        pyfile = joinpath(dir, "cases.py")
        write(pyfile, py)
        cmd = `$uv run --no-project --python 3.13 --with polars==$POLARS --with duckdb==$DUCKDB --with pyarrow==$PYARROW python -I $pyfile $dir`
        run(pipeline(cmd; stderr = devnull))
        out = read(joinpath(dir, "out.txt"), String)

        # ---- parse ----------------------------------------------------------------------------------
        function dec(t)
            t == "N" && return missing
            t == "T" && return true
            t == "F" && return false
            h, r = t[1], t[2:end]
            h == 'i' && return parse(Int, r)
            h == 'f' && return parse(Float64, r)
            h == 's' && return String(hex2bytes(r))
            return "?" * String(hex2bytes(r))
        end
        res = Dict{Tuple{String, String}, Any}()
        cur = ("", "")
        versions = String[]
        for line in split(out, '\n'; keepempty = false)
            f = split(line, '\t')
            if f[1] == "VERSIONS"
                versions = String.(f[2:end])
            elseif f[1] == "CASE"
                cur = (String(f[2]), String(f[3]))
                res[cur] = (n = parse(Int, f[4]), cols = Pair{Symbol, Vector{Any}}[], err = nothing)
            elseif f[1] == "COL"
                vals = length(f) < 3 || isempty(f[3]) ? Any[] : Any[dec(String(s)) for s in split(f[3], '|')]
                push!(res[cur].cols, Symbol(f[2]) => vals)
            elseif f[1] == "ERR"
                res[(String(f[2]), String(f[3]))] = (n = -1, cols = Pair{Symbol, Vector{Any}}[], err = String(hex2bytes(f[4])))
            end
        end
        @test versions[1:2] == [POLARS, DUCKDB]

        # numbers: equal (NaN equals NaN) or within 1e-12, but a zero's sign must match
        numsame(a, b) = iszero(a) && iszero(b) ? signbit(a) == signbit(b) :
            isequal(a, b) || isapprox(a, b; rtol = 1.0e-12, atol = 1.0e-12)
        same(a, b) = (ismissing(a) && ismissing(b)) || (
            !ismissing(a) && !ismissing(b) && (
                (a isa Number && b isa Number && numsame(Float64(a), Float64(b))) ||
                    (!(a isa Number) && !(b isa Number) && string(a) == string(b))
            )
        )
        fmt(v) = "[" * join((ismissing(x) ? "missing" : x isa AbstractFloat ? repr(x) : x isa AbstractString ? repr(String(x)) : string(x) for x in v), ", ") * "]"
        colsame(u, v) = length(u) == length(v) && all(same(a, b) for (a, b) in zip(u, v))
        jlcols(t) = Pair{Symbol, Vector{Any}}[k => Any[x for x in Tables.getcolumn(t, k)] for k in Tables.columnnames(t)]

        # input round trip: ChuiFrames' Arrow writer -> Polars keeps NaN, -0.0 and null exactly
        for (nm, t) in frames
            r = res[("input", nm)]
            @test colsame([first(p) for p in r.cols], collect(Tables.columnnames(t))) || [first(p) for p in r.cols] == collect(Tables.columnnames(t))
            @test all(colsame(last(a), last(b)) for (a, b) in zip(jlcols(t), r.cols))
        end
        @test any(x -> x isa Float64 && iszero(x) && signbit(x), last(res[("input", "d")].cols[4]))

        keep_rows(cols, keep) = [k => v[keep] for (k, v) in cols]
        idrow(cols) = Int.(last(only(filter(p -> first(p) === :id, cols))))
        specs(kind) = kind isa Vector ? kind : Any[kind]

        # The comparison. Returns true when the result matches under the kind; a mismatch is
        # logged with both sides.
        function check(nm, eng, jl, r, kind)
            ks = specs(kind)
            if any(==(:error), ks)
                @test r.err !== nothing
                r.err === nothing || @info "differential: expected error" case = nm engine = eng error = r.err
                return r.err !== nothing
            end
            if r.err !== nothing
                @info "differential: engine error" case = nm engine = eng error = r.err
                @test r.err === nothing
                return false
            end
            jc, fc = jlcols(jl), copy(r.cols)
            ok = true
            for k in ks
                k === :exact && continue
                if k[1] === :jl_only || k[1] === :fr_only
                    p = k[2]
                    side = k[1] === :jl_only ? jc : fc
                    keep = [!p(i) for i in idrow(side)]
                    occurs = any(!, keep)
                    occurs || @info "differential: encoded divergence no longer occurs" case = nm engine = eng kind = k[1] ids = fmt(idrow(side))
                    @test occurs
                    ok &= occurs
                    k[1] === :jl_only ? (jc = keep_rows(jc, keep)) : (fc = keep_rows(fc, keep))
                elseif k[1] === :jl_only_missing
                    keep = [!ismissing(v) for v in last(only(filter(p -> first(p) === k[2], jc)))]
                    occurs = any(!, keep)
                    @test occurs
                    ok &= occurs
                    jc = keep_rows(jc, keep)
                elseif k[1] === :sort_tail
                    col = getproperty(d, k[2])
                    regular(i) = !ismissing(col[i]) && !isnan(col[i])
                    ji, fi = idrow(jc), idrow(fc)
                    setok = sort(ji) == sort(fi)
                    differs = ji != fi
                    headok = filter(regular, ji) == filter(regular, fi)
                    @test setok && headok && differs
                    ok &= setok && headok && differs
                    return ok
                end
            end
            names_ok = [first(p) for p in jc] == [first(p) for p in fc]
            names_ok || @info "differential: column names differ" case = nm engine = eng julia = first.(jc) foreign = first.(fc)
            @test names_ok
            ok &= names_ok
            expect_differ = Set{Symbol}()
            nanmask = nothing
            for k in ks
                k === :exact && continue
                if k[1] === :cols
                    union!(expect_differ, k[2])
                elseif k[1] === :nan_rows
                    col = getproperty(d, k[2])
                    nanmask = [!ismissing(col[i]) && isnan(col[i]) for i in idrow(jc)]
                    union!(expect_differ, k[3])
                end
            end
            for ((jk, jv), (fk, fv)) in zip(jc, fc)
                if jk in expect_differ
                    if nanmask === nothing
                        differs = !colsame(jv, fv)
                    else
                        rest = .!nanmask
                        differs = length(jv) == length(fv) && !colsame(jv[nanmask], fv[nanmask])
                        restok = length(jv) == length(fv) && colsame(jv[rest], fv[rest])
                        restok || @info "differential mismatch (outside the NaN rows)" case = nm engine = eng column = jk julia = fmt(jv) foreign = fmt(fv)
                        @test restok
                        ok &= restok
                    end
                    differs || @info "differential: encoded divergence no longer occurs" case = nm engine = eng column = jk
                    @test differs
                    ok &= differs
                else
                    cok = colsame(jv, fv)
                    cok || @info "differential mismatch" case = nm engine = eng column = jk julia = fmt(jv) foreign = fmt(fv)
                    @test cok
                    ok &= cok
                end
            end
            return ok
        end

        passed = Dict("polars" => 0, "duckdb" => 0)
        exact = Dict("polars" => 0, "duckdb" => 0)
        for (nm, fr, pipe, _, _, kpl, kdb) in cases
            jl = pipe(frames[fr])
            for (eng, kind) in (("polars", kpl), ("duckdb", kdb))
                @test haskey(res, (eng, nm))
                haskey(res, (eng, nm)) || continue
                if check(nm, eng, jl, res[(eng, nm)], kind)
                    passed[eng] += 1
                    kind === :exact && (exact[eng] += 1)
                end
            end
        end
        for eng in ("polars", "duckdb")
            @info "differential: $(passed[eng])/$(length(cases)) cases agree with $eng ($(exact[eng]) exactly, the rest under an encoded divergence)"
        end
        return nothing
    end
    run_differential()
end
