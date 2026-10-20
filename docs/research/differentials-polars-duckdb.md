# Differentials: Polars and DuckDB

**Question.** Where do ChuiFrames' eager verbs give different results from Polars and DuckDB on
the same data, why, and is each difference intended?

**Date.** 2026-10-20.

**Versions.** Polars 2.0.0, DuckDB 1.5.6 (Python package), pyarrow 26.0.0 (DuckDB reads the input
through it), CPython 3.13.13 via `uv` 0.12.23. ChuiFrames at commit 723cf0e (the p2c-diff lane),
Julia 1.13.2.

**Test.** `test/engine/differential_polars_duckdb_tests.jl`, test item "differential: Polars and
DuckDB", tags `:differential` and `:polars_duckdb`. It runs Python once:

```sh
uv run --no-project --python 3.13 --with polars==2.0.0 --with duckdb==1.5.6 --with pyarrow==26.0.0 python -I <mktempdir>/cases.py <mktempdir>
```

When `uv` is not on PATH, the item logs `uv not found on PATH` and records one `@test_skip`
(checked with a PATH holding only `julia`: `Broken 1`, run passes).

**Commands and pass counts.**

```sh
julia scripts/evidence.jl diff-polars-duckdb -- julia scripts/ci.jl test -- differential
julia scripts/evidence.jl diff-polars-duckdb-item -- julia scripts/ci.jl test -- polars_duckdb
```

- `.lanes/evidence/diff-polars-duckdb-723cf0e.txt`: every `:differential` item, 1637/1637 pass.
  It includes the dplyr, rank-tail and tidyr items.
- `.lanes/evidence/diff-polars-duckdb-item-723cf0e.txt`: this item alone, 635/635 pass.
- Cases: 56 per engine.
  - Polars: 56/56 agree, 39 exactly and 17 under an encoded divergence.
  - DuckDB: 56/56 agree, 34 exactly and 22 under an encoded divergence.

## Method

- **Data.** The fixed 40-row frame of the dplyr suite: `id`; `g` (strings with `missing`); `k`
  (keys `0.0, -0.0, NaN, missing, 1.0`, with -0.0 and 0.0 interleaved); `x` (`1.5, NaN, missing,
  -0.0, 0.0, 3.0, -2.0, 1.0, Inf, -Inf`); `y` (Int); `s` (mixed-case ASCII strings with `missing`).
  The pivots use two small frames, `w` (wide, with NaN, -0.0 and `missing`) and `lg` (long).
- **In.** The Julia side writes each frame as Arrow IPC with `write_arrow`. Polars reads it with
  `pl.from_arrow(pyarrow.ipc.open_file(...).read_all())`. DuckDB registers the same pyarrow table
  and copies it into a **native** table (`CREATE TABLE d AS SELECT * FROM d_arrow`); see
  `duckdb_arrow_pushdown` for why. The item checks the round trip first: Polars sees every input
  value exactly, including NaN, -0.0 and null.
- **Out.** Python writes one text file. Each value is a typed token: `N` for null, `T`/`F`, `i<int>`,
  `f<repr(float)>` (so `nan`, `-0.0` and `inf` stay exact), and `s<hex utf-8>`. CSV is not used,
  because it cannot carry NaN, null and -0.0 apart.
- **Comparison.** Same column names, same row order, values equal. NaN equals NaN, numbers may
  differ by 1e-12, but **a zero's sign must match**. Integer and float columns compare by value,
  so `n` as UInt32 (Polars) or HUGEINT (DuckDB) is fine.
- **Row order.** Where dplyr's convention fixes the order (grouped summaries and slices in
  group-key order, NaN before `missing`), the foreign expression sorts to it explicitly. SQL always
  has an `ORDER BY`. This is an adaptation, not a divergence.
- **Encoded divergences.** Each case has a kind per engine. An encoded divergence is checked to
  **still occur**: if Polars or DuckDB changes, the test fails, and this table has to be updated.
  - `:exact`.
  - `(:jl_only, p)` / `(:fr_only, p)`: rows only in Julia, or only in the foreign result, picked
    by a predicate on the input row.
  - `(:jl_only_missing, col)`: Julia's rows whose `col` is missing are absent in the foreign
    result.
  - `(:sort_tail, col)`: the same rows, the same order of the non-NaN, non-missing rows, and a
    different placement of NaN and `missing`.
  - `(:nan_rows, col, cols)`: rows whose input `col` is NaN differ in `cols`.
  - `(:cols, cols)`: the named columns differ, and the rest match.

## Divergences

"CF" is ChuiFrames. "Intended" means it follows an ADR rule or dplyr parity.

| Case | CF result | Polars | DuckDB | Cause | Intended? |
|---|---|---|---|---|---|
| `filter_gt` `x > 1` | 12 rows, NaN rows dropped | +4 NaN rows | +4 NaN rows | IEEE `NaN > 1` is false (ADR-0002 rule 12). Polars and DuckDB order NaN above +Inf, so `NaN > 1` is true. | yes |
| `filter_and` `x > -3, y >= 0` | 18 rows | +2 NaN rows | +2 NaN rows | the same | yes |
| `filter_not_gt` `!(x > 1)` | 24 rows, NaN kept | 20, NaN dropped | 20, NaN dropped | rule 12: the negation is true on NaN in Julia, and false in both engines | yes |
| `filter_out` `x > 1` | keeps NaN and `missing` rows | keeps `missing`, drops NaN | keeps NULL, drops NaN (`IS NOT TRUE`) | the same family. `filter_out` keeps rows where the predicate is false or missing (dplyr). | yes |
| `slice_max_x` `n = 3` | the 4 `Inf` rows (ties) | the 4 NaN rows | the 4 NaN rows | NaN is the largest value in Polars and DuckDB. CF ranks only non-NaN values (dplyr: NaN is NA). | yes |
| `mutate_missing` `e = x == x` | `false` on NaN | `true` | `true` | IEEE vs NaN = NaN in Polars and DuckDB (rule 12) | yes |
| `case_when` `x > 1 => big, x <= 0 => neg` | NaN → "other" | NaN → "big" | NaN → "big" | the same | yes |
| `ranks_x` `row_number/min_rank/dense_rank(x)` | NaN → `missing` rank | NaN ranked last (33-36, dense 8) | NaN ranked last | dplyr parity: R's ranks treat NaN as NA. The other ranks agree, including ±0 ties. | yes |
| `arrange_x`, `arrange_k` | NaN and `missing` tied at the end, in input order | NaN first, then nulls (`nulls_last`) | NaN first, then NULLs | ADR-0002 rule 13 (dplyr LC-07). Both engines sort NaN above +Inf. | yes |
| `arrange_desc` | NaN and `missing` still at the end | NaN **first**, nulls last | NaN **first**, NULLs last | rule 13: `desc` reverses only the regular values. In the engines, NaN is the largest value. | yes |
| `arrange_zero_values` (sort, keep the zeros) | `0.0, -0.0, …` as stored | as stored | every -0.0 returned as `0.0` | DuckDB's `ORDER BY` returns the sort column's -0.0 values as 0.0. Selecting `x::VARCHAR` in the same query shows `-0.0`. Probe in the scratch dir: `SELECT id, k FROM t ORDER BY k` gives `0.0` for rows stored as `-0.0`. | yes (DuckDB defect) |
| `summarise_k`, `summarise_gk`, `count_k_sorted` | key `-0.0` (first zero seen, rule 8) | `-0.0` | `0.0` | DuckDB groups ±0 together and keeps the first key seen, as CF does (`distinct_k` is exact). The `ORDER BY k` on the key then rewrites it to 0.0 (row above). | yes (DuckDB defect) |
| `summarise_x_order` `nd = n_distinct(x)` | 5 (counts `missing`) | 5 (`n_unique` counts null) | 4 where the group holds a NULL | SQL `count(DISTINCT x)` skips NULL. dplyr's `n_distinct` counts NA, and rule 8 makes `missing` a key. | yes |
| `summarise_x_stats` `sum/mean/minimum/maximum(x)` | `missing` for groups with a `missing`; else NaN | nulls skipped: `Inf`; `min` -2/-Inf; `max` Inf/3.0 | nulls skipped: `Inf`; `min` -2/-Inf; `max` Inf/NaN | CF propagates `missing` unless `skipmissing` is asked for, as R does without `na.rm`. NaN propagates through Julia's reductions. | yes |
| `summarise_x_skip` (`skipmissing`) | `min` NaN, `max` NaN where the group has a NaN | `min` -Inf, `max` 3.0 (NaN ignored) | `min` -Inf, `max` NaN | Julia's `minimum`/`maximum` propagate NaN. Polars' `min`/`max` ignore NaN. DuckDB orders NaN last, so its `min` skips it and its `max` returns it. `sum` and `mean` agree (NaN). | yes |
| `summarise_x_nanprop` | as above | **exact** with `nan_min`/`nan_max` | **exact** with `CASE WHEN bool_or(isnan(x)) …` | the equivalent spelling exists in both engines | n/a |
| `summarise_empty` (no rows, ungrouped) | `n = 0, s = 0, m = NaN` | `m = null` | `s = NULL, m = NULL` | Julia: `sum([]) = 0`, `mean([]) = NaN`, as in dplyr. SQL `SUM` of no rows is NULL. Polars' sum is 0 and its mean null. | yes |
| `summarise_singleton` `var/std` of one value | `NaN` | `null` | `NULL` | `Statistics.var` of one value is NaN (n-1 = 0). **dplyr gives NA here** (`var(5)` is NA in R). | **flag**: matches neither engine nor dplyr (see "Findings") |
| `mutate_native_mod` (native operators) | `mod.(y, 3)` floors, `div.(y, 2)` truncates | `%` floors (matches `mod`), `//` floors (≠ `div`, = `fld`) | `%` truncates (≠ `mod`, = `rem`), `//` truncates (matches `div`) | the operator names mean different things. `mutate_intdiv` spells `div/fld/mod/rem` in each engine and is exact. | yes |
| `pivot_longer` vs plain `UNPIVOT` | keeps `missing` values (8 rows) | `unpivot` keeps nulls | `UNPIVOT` drops NULLs by default (5 rows; NaN kept) | tidyr keeps NA unless `values_drop_na = true`. `UNPIVOT INCLUDE NULLS` is exact (`pivot_longer_include_nulls`), and so is `values_drop_na = true` against plain `UNPIVOT`. | yes |
| `duckdb_arrow_pushdown` `x > 1` on the **Arrow view** | 12 rows | +4 NaN rows | **exact (12 rows)** | DuckDB pushes a `WHERE` on a registered Arrow table into the Arrow scan (`EXPLAIN`: `ARROW_SCAN … Filters: x>1.0`), which compares IEEE-style. The same predicate in a projection, or on a native table, is true on NaN. | n/a (DuckDB inconsistency, recorded) |

## Where Polars and DuckDB disagree with each other

- **`max` with NaN.** Polars ignores NaN (3.0). DuckDB returns NaN, because NaN is its largest
  value. Both `min`s give -Inf.
- **`//` and `%`.** Polars floors both. DuckDB truncates both.
- **Sum of no rows.** Polars gives 0. DuckDB gives NULL. Both give a null mean.
- **Distinct counts.** Polars `n_unique` counts null. DuckDB `count(DISTINCT)` does not.
- **Unpivot.** Polars `unpivot` keeps nulls. DuckDB `UNPIVOT` drops them unless `INCLUDE NULLS`.
- **±0 output.** Polars returns -0.0 everywhere it is stored. DuckDB rewrites it to 0.0 in an
  `ORDER BY` column.
- **NaN in filters on Arrow data.** DuckDB's result depends on whether the predicate is pushed
  into an Arrow scan. Polars is consistent.
- **Pivot column order.** Polars `pivot` uses first appearance, as tidyr and CF do. DuckDB `PIVOT`
  sorts the new columns. The suite names them (`IN ('b', 'a', 'c')`) for `pivot_wider` and
  compares the sorted default with `names_sort = true`. Both are exact.

## Agreements worth recording

- **±0 keys.** All three engines merge -0.0 and 0.0 into one group or distinct row and keep the
  first key seen (`distinct_k` is exact, first zero -0.0; `distinct_x` is exact, first zero 0.0).
  All three tie ±0 in a sort: `arrange_k`'s regular part and `arrange_zero_values`' row order are
  equal. This is ADR-0003 rule 8 and ADR-0002 rule 13.
- **NaN and null keys.** NaN is one group and `missing` is another, everywhere. Sorted, NaN comes
  before `missing` (CF-008's `isless` order), which is Polars' and DuckDB's order too.
- **Exact cases.**
  - Group order and values: `count_by`, `wt`, `add_count`.
  - Grouped `summarise` over Int: `n`, `sum`, `mean`, `min`, `max`, `var`, `std`, `median`.
  - Order-dependent reductions: `first` and `last` (DuckDB `first(x ORDER BY id)`).
  - Grouped windows: `row_number`, `lag`, `lead` with a default, `cumsum`, `cummean`, and the
    demeaned value.
  - Grouped and ungrouped ranks on Int: `min_rank`, `dense_rank`, `desc`, `percent_rank`,
    `cume_dist` and `ntile`. Polars has no `ntile`, `percent_rank` or `cume_dist`, so the suite
    composes them from `rank(...)` and `len()`. DuckDB's built-ins match dplyr.
  - Slices: `slice_head`, `slice_tail`, `slice_min` with ties, `slice_max` without ties.
  - String sort (byte order) and multi-key sort with nulls last.
  - Arithmetic with ±Inf, NaN and -0.0, missing propagation, and `coalesce`.
  - `distinct`.
- **Joins.** Not exercised: ChuiFrames exports no join verbs yet. When they land, ADR-0003 rule
  11's NULL-key note (DuckDB does not match NULL keys, CF does by default) belongs here as a
  `:jl_only` divergence.

## Findings

1. **`var`/`std` of a single value is NaN, not `missing`.** dplyr gives NA, and Polars and DuckDB
   give null. ChuiFrames returns `Statistics.var`'s NaN. Repro:

   ```julia
   using ChuiFrames, Statistics, Tables
   r = summarise(v = var(c.y), s = std(c.y))((y = [5],))
   Tables.getcolumn(r, :v), Tables.getcolumn(r, :s)   # ([NaN], [NaN])
   ```

   R check: `Rscript --vanilla -e 'library(dplyr); tibble(id = 1:2, y = c(2L, 0L)) |> group_by(id) |>
   summarise(v = var(y), sd = sd(y), m = mean(y[0]), s = sum(y[0]))'` printed `v = NA, sd = NA,
   m = NaN, s = 0`. The empty `mean`/`sum` agree with CF; the singleton `var`/`sd` do not. No ADR
   rule covers this. It is encoded here as an expected difference, not fixed (this lane has no src
   scope). The decision belongs to the lead: either document it next to ADR-0002 rule 12 as a Julia
   semantics divergence from dplyr, or map n < 2 to `missing`. The dplyr suites do not test `var`.
2. **No other ChuiFrames defect found.** Every other difference traces to an ADR rule or dplyr
   parity.
3. **Two DuckDB 1.5.6 defects** affect anyone using DuckDB as an oracle: the `ORDER BY` -0.0
   rewrite, and the Arrow-scan pushdown changing NaN comparisons. The suite therefore queries
   native DuckDB tables, and keeps one case on the Arrow view so a fix shows up.

## Not covered

- Lazy plans: only the eager verbs.
- Joins: not exported.
- Timestamps, nested and list columns, dictionary-encoded input. The Arrow input has plain
  columns only.
- The DuckDB relational API: SQL was clearer for every case.
- Other Julia versions. The item ran on Julia 1.13.2 only.
