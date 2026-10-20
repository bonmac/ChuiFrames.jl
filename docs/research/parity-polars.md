# Parity matrix: Polars

**Question.** Which Polars features (expression API, DataFrame/LazyFrame verbs, lazy engine) should
ChuiFrames match, adapt or skip, and in which phase?

**Date.** 2026-10-20.

**Versions.** Polars 2.0.0 (Python 3.13.13 via `uv`), pyarrow and pandas 3.0.6 as helpers. Docs:
Context7 `/websites/pola_rs` (stable API reference, read 2026-10-20). ChuiFrames baseline: the
prototype (`reference/prototype/DESIGN.md` in the coordinator repo, §2-§3).

**Method.**

```sh
cd <scratchpad>/eng-parity
uv run --python 3.13 --with polars --with pandas --with duckdb --with 'ibis-framework[duckdb]' --with pyarrow python -I py_probe.py
uv run --python 3.13 --with polars --with 'ibis-framework[duckdb]' --with pyarrow --with pandas python -I py_probe2.py
```

Both scripts live only in the scratchpad (not committed). Every "run" source below names an
evidence ID from the Evidence section.

**Status legend.** `prototype` = already works in the prototype; `planned` = a ChuiFrames feature
in the brief's phases, not yet built; `adapted` = we take the idea but change the surface to fit
Julia (dots, plain calls, `c.x`); `skip` = we do not plan it.

**Summary counts (71 rows).** prototype 20 · planned 32 · adapted 15 · skip 4.

**Headline.** Three Polars ideas shape ChuiFrames most:

1. **Expressions are values, contexts decide meaning.** `pl.col("x").sum()` is a reduction in
   `select`/`agg` and a broadcast in `with_columns`; `.over(...)` turns it into a window. The
   prototype already gets this from `c.x` plus "plain call = reduction, dot = elementwise", and
   grouped `mutate` gives the window (PE-04). Keep it; add an explicit `over` only if the ADR on
   the expression grammar finds a case grouped `mutate` cannot express.
2. **One plan, inspectable before and after optimization.** `explain(optimized=False)` vs
   `explain()` (PE-01, PE-02) is exactly the prototype's "Parsed" vs "Optimized Logical Plan". The
   optimized plan folds the filter and the projection into the scan node (`SELECTION:`,
   `PROJECT 2/4 COLUMNS`). ChuiFrames should print the same facts.
3. **Namespaced expression methods and selectors.** Polars groups ~223 `Expr` methods (PE-10) under
   `str`, `dt`, `list`, `struct`, `cat`, `arr`, `bin`, `name`, `meta` (PE-05). In Julia these become
   ordinary functions broadcast over `c.x` (stringr/lubridate/forcats-style names, phase 6), and
   tidyselect-style selectors cover `polars.selectors`.

## Expression API

| Polars feature | ChuiFrames equivalent (proposed) | Status | Phase | Notes | Source |
|---|---|---|---|---|---|
| `pl.col("x")` | `c.x` (`Col` node via `getproperty` on singleton `c`) | prototype | 1 | Same role: a deferred column reference. | DESIGN §3.1; PE-01 |
| `pl.col("^x.*$")` regex / multiple names | `c[r"^x"]`, `c[:a, :b]` or selectors inside `select` | planned | 2 | Needs a multi-column node that expands against the schema. | PE-05 |
| `pl.lit(v)` | plain Julia value inside an expression (`c.x .+ 1`) | prototype | 1 | Broadcasting lifts literals; no `lit` needed. | DESIGN §3.1 |
| arithmetic / comparison operators on `Expr` | dotted operators (`.+`, `.>`, `.&`) | adapted | 1 | Plain `>` is deliberately not overloaded (keeps `==` usable in `Dict`). Polars overloads all dunders. | DESIGN §3.1 |
| `when(...).then(...).otherwise(...)` | `ifelse.(cond, a, b)`; dplyr `if_else`/`case_when` as functions | adapted | 2 | `ifelse.` already works through broadcasting; `case_when` comes from the dplyr matrix. | PE-04; DESIGN §3.1 |
| `.alias("n")` | keyword name: `mutate(n = ...)`, `summarise(n = ...)` | prototype | 1 | Names come from keywords, as in dplyr. | DESIGN §2 |
| aggregations `sum/mean/min/max/std/var/median/quantile/n_unique/first/last/count/len` | plain calls `sum(c.x)`, `mean(c.x)`, … | prototype | 1 | Monoid decomposition for the decomposable ones (DESIGN §3.6). `n_unique` and `len` need names (`n_distinct`, `n()`), see dplyr matrix. | DESIGN §2, §3.6 |
| `.over("g")` window | `group_by(:g) ⨟ mutate(dm = c.x .- mean(c.x))` | prototype | 1 | Prototype's grouped evaluation is a window function. A per-expression `over` (different partitions in one `mutate`) is a candidate for the grammar ADR. | PE-04; DESIGN §3.2 |
| `.over(..., order_by=...)`, `rank`, `shift`, `cum_*`, `diff` | `cumsum.`-style scans, dplyr `lag/lead/row_number/min_rank` | planned | 2 | Scans exist (`cumsum cumprod accumulate`); ranking/shift come with dplyr parity. | DESIGN §2 |
| `.rolling_*` (rolling_mean etc.) on expressions | `slide`-style window functions | planned | 6 | Pair with lubridate parity; slider-like API is an ADR question. | Context7 `/websites/pola_rs` |
| `str` namespace (`contains`, `extract`, `replace`, `split`, `to_lowercase`, `len_chars`, …) | stringr names broadcast over `c.x` (`str_detect.(c.s, r"a")`) | adapted | 6 | Functions, not a namespace object; Julia has no `c.x.str` without `getproperty` tricks on nodes. | PE-05, PE-10 |
| `dt` namespace (`year`, `truncate`, `offset_by`, `convert_time_zone`) | lubridate names broadcast (`year.(c.t)`, `floor_date.(c.t, …)`) | adapted | 6 | Base `Dates.year.` already works through broadcasting. | PE-05 |
| `list` namespace (`len`, `get`, `eval`, `contains`) | `length.(c.l)`, `getindex.(c.l, i)`, purrr-style `map` | adapted | 6 | Nested columns as Arrow `List`; `map(f, c.l)` in prototype. | PE-05; DESIGN §2 |
| `arr` (fixed-size array) namespace | Arrow `FixedSizeList` columns, same functions as `list` | skip | - | No R package in the parity set needs it; revisit with ChuiSpatial. | PE-05 |
| `struct` namespace (`field`, `unnest`, `rename_fields`) | NamedTuple-valued columns, `getfield.(c.s, :a)`, tidyr `unnest_wider` | adapted | 2 | Struct ↔ NamedTuple is natural in Julia. | PE-05 |
| `cat` namespace / `Categorical`, `Enum` dtypes | Arrow dictionary encoding + forcats functions | planned | 6 | Brief requires dictionary encoding; forcats parity sets the API. | PE-05; BRIEF "Engine" |
| `bin` namespace | `Vector{UInt8}` columns, Base functions | skip | - | Low priority; Base covers it. | PE-05 |
| `name` namespace (`suffix`, `prefix`, `map`) | `rename_with`, `.names` in `across` | adapted | 2 | dplyr's `across(.names=)` is the target. | PE-05 |
| `meta` namespace (introspect expressions) | `show`/`label` on nodes; `Call.label` already exists | prototype | 1 | Prototype records a printable `label` per `Call`. | DESIGN §3.1 |
| horizontal ops `sum_horizontal`, `max_horizontal`, `any_horizontal`, `concat_str` | `c.x .+ c.y`, `max.(c.x, c.y)`, `rowwise`-free broadcasting; `pick`/`across` + `ByRow` | adapted | 2 | Broadcasting makes most of these free; an `across`-row form is needed for many columns. | PE-05 |
| `polars.selectors` (`numeric`, `starts_with`, `by_dtype`, set algebra `|`, `&`, `-`, `~`) | tidyselect helpers `where(isnumeric)`, `starts_with("x")`, `!`, `-` | planned | 2 | Polars' set algebra on selectors is a good model for combining tidyselect helpers. | PE-05, PE-10 |
| `map_elements` (row UDF) / `map_batches` (column UDF) | `f.(c.x)` (row) and `c.x \|> f` (whole column) | prototype | 1 | Prototype's escape hatch is `\|> f`; elementwise UDFs are just Julia functions, compiled, no GIL penalty. | DESIGN §2; PE-10 |
| `fold`/`reduce` horizontal | `reduce`, `mapreduce`, `foldl` | prototype | 1 | Prototype lists them as reductions. | DESIGN §2 |
| null vs NaN distinction (`null_count`, `is_nan`, `fill_nan`) | Arrow validity = `missing`; `NaN` stays a value | planned | 2 | Polars skips nulls in aggregations but propagates NaN (PE-11). ChuiFrames follows Julia: `missing` propagates unless `skipmissing`/`na_rm`. Decide in the grammar ADR. | PE-11 |
| `fill_null(strategy=...)`, `drop_nulls`, `interpolate` | tidyr `replace_na`, `fill`, `drop_na` | planned | 2 | From the tidyr matrix. `fill_null(strategy="forward")` ran (PE-12). | PE-12; Context7 `/websites/pola_rs` |
| `cast(dtype, strict=)` | `convert.(T, c.x)`; readr `parse_*` | adapted | 2 | Julia conversion functions instead of a `cast` method. | Context7 `/websites/pola_rs` |
| `pl.struct(...)`, `pl.concat_list(...)` constructors | NamedTuple / vector construction broadcast | adapted | 2 | | PE-05 |

## DataFrame and LazyFrame verbs

| Polars feature | ChuiFrames equivalent (proposed) | Status | Phase | Notes | Source |
|---|---|---|---|---|---|
| `filter(expr)` | `filter(c.x .> 1)` | prototype | 1 | Prototype splits `.&` conjuncts for pushdown. | DESIGN §2, §3.7 |
| `select(...)` | `select(:a, :b)` / `select(n = expr)` | prototype | 1 | | DESIGN §2 |
| `with_columns(...)` | `mutate(...)` | prototype | 1 | Prototype applies keywords in order (later can use earlier); Polars evaluates them against the input, so a new column is not visible in the same call (`ColumnNotFoundError`, PE-12). Keep dplyr's ordered semantics. | DESIGN §3.3; PE-12 |
| `group_by(keys).agg(...)` | `group_by(:g) ⨟ summarise(...)` | prototype | 1 | Prototype's bottleneck; typed keys and radix partitioning planned (phase 4). | DESIGN §2; BRIEF "Engine" |
| `group_by(maintain_order=True)` | stable group order option; dplyr sorts keys | planned | 4 | Polars default is unordered (`maintain_order: false` in PE-01). dplyr returns sorted groups; ChuiFrames must match dplyr by default. | PE-01 |
| `join(how=inner/left/right/full)` | `inner_join`, `left_join`, `right_join`, `full_join` | planned | 4 | Hash joins, broadcast vs shuffle. | PE-06; BRIEF "Engine" |
| `join(how=semi/anti)` | `semi_join`, `anti_join` | planned | 4 | Verified Polars results: semi keeps 2 rows, anti 1 (PE-06). | PE-06 |
| `join(how=cross)` | `cross_join` | planned | 4 | | PE-06 |
| `join_asof(on, by, strategy=backward/forward/nearest)` | dplyr `join_by(closest(x >= y))` | planned | 4 | dplyr 1.1 inequality/rolling joins are the R-side spec. | PE-06 |
| `join_where` (inequality join) | `join_by(x >= y, …)` | planned | 4 | | PE-12 |
| `sort(by, descending, nulls_last)` | `arrange(c.x, desc(c.y))` | prototype | 1 | | DESIGN §2 |
| `unique(subset, keep=first/last/any/none)` | `distinct(...)` | planned | 2 | `keep="none"` (drop all duplicates) has no dplyr name; skip it unless asked. | PE-10 |
| `head`/`tail`/`slice` | `head`, `slice_head`, `slice_tail`, `slice` | prototype | 1 | `head` exists; `slice_*` from dplyr matrix. | DESIGN §2 |
| `pivot(on, index, values)` | tidyr `pivot_wider` | planned | 2 | Polars 2.0 has `LazyFrame.pivot` (PE-10); a lazy pivot needs the output schema, so the lazy form must require the `on` values or compute them. | PE-07, PE-10 |
| `unpivot(index, on)` (was `melt`) | tidyr `pivot_longer` | planned | 2 | | PE-07 |
| `explode(col)` | tidyr `unnest_longer` / `unnest` | prototype | 1 | Prototype has `nest`/`unnest`. | PE-07; DESIGN §2 |
| `unnest(struct col)` | tidyr `unnest_wider` | planned | 2 | | PE-05 |
| `rolling(index, period)` | slider-style rolling summarise | planned | 6 | Verified: 2h window sums `[0,1,3,5,7,9]`. | PE-08 |
| `group_by_dynamic(index, every)` | `group_by(floor_date.(c.t, Hour(2)))` then `summarise` | adapted | 6 | Fixed windows reduce to a grouping key; overlapping windows (`period > every`) need a dedicated verb. | PE-08 |
| `rename`, `drop` | `rename`, `select(-c.x)` / `select(!:x)` | planned | 2 | | Context7 `/websites/pola_rs` |
| `pl.concat(how=vertical/diagonal/horizontal)` | `bind_rows`, `bind_cols` | planned | 2 | `diagonal` = `bind_rows` with fill (PE-12). | PE-12 |
| `describe`, `glimpse`, `estimated_size` | `glimpse`, `summary` | planned | 2 | Watch name clash with DataFrames `describe` (see parity-julia-frames). | parity-julia-frames.md |
| `pl.SQLContext` / `pl.sql` | `sql(df, "select ...")` sqldf-style | planned | 6 | Polars ran `select sum(x) s from t` on a registered frame (PE-10). Needs a SQL parser; see parity-others. | PE-10 |
| table printing (`pl.Config.set_tbl_rows`, dtype under header) | tibble-style printing | planned | 2 | Polars prints the dtype row under headers (PE-04), same idea as tibble. | PE-04; BRIEF "tibble-style printing" |
| `to_dummies`, `sample`, `transpose` | not in R core set | skip | - | Outside the dplyr/tidyr parity scope. | PE-12 (`to_dummies`); Context7 `/websites/pola_rs` |
| `DataFrame.lazy()` / `LazyFrame.collect()` | `lazy(df)` / `collect(q)` | prototype | 1 | Same pipeline value runs on either (`p(df)`, `p(lazy(df))`). | DESIGN §2 |
| method chaining `lf.filter().select()` | `\|>` and `⨟` (verbs as values) | adapted | 1 | ChuiFrames verbs are first-class `Step` values: a pipeline can exist without data, which Polars cannot express. | DESIGN §3.4 |

## Lazy engine

| Polars feature | ChuiFrames equivalent (proposed) | Status | Phase | Notes | Source |
|---|---|---|---|---|---|
| `explain(optimized=False)` | `explain(q)` "Parsed Logical Plan" | prototype | 1 | PE-02 shows FILTER and SELECT as separate nodes above the scan. | PE-02; DESIGN §3.9 |
| `explain()` optimized | "Optimized Logical Plan" with `PushedFilters` | prototype | 1 | PE-01: filter becomes `SELECTION: col("x") > 1` on the scan. | PE-01; DESIGN §3.9 |
| predicate pushdown | prototype rule set (split conjuncts, safety rules) | prototype | 3 | Phase 3 re-implements it with ChuiCore recursion schemes. | PE-01; DESIGN §3.7 |
| projection pushdown | prototype dead-column elimination | prototype | 3 | PE-01: `PROJECT 2/4 COLUMNS`. | PE-01; DESIGN §3.7 |
| slice pushdown | `head` → `TakeRows` early stop | adapted | 3 | Polars keeps SLICE above FILTER in-memory (PE-10); prototype stops the scan early instead. | PE-10; DESIGN §3.7 |
| common subexpression elimination (CSE) | hash-cons identical `Call` nodes within a step | planned | 3 | PE-03: `(col("x")*2).sum()` computed once as `__POLARS_CSER_…`. | PE-03 |
| common subplan elimination | cache shared subplans (self-joins, unions) | planned | 4 | Matters once joins exist. | Context7 `/websites/pola_rs` (QueryOptFlags) |
| `simplify_expression`, `type_coercion` | rule-based rewrites (constant folding, cast insertion) | planned | 3 | | Context7 `/websites/pola_rs` (QueryOptFlags) |
| `collapse_joins`, `cluster_with_columns` | rule-based rewrites | planned | 4 | | Context7 `/websites/pola_rs` (QueryOptFlags) |
| `pl.QueryOptFlags(...)` toggling passes | `optimize(q; rules=...)` | adapted | 3 | Polars deprecated per-flag kwargs for one flags object (upgrade guide 2). ChuiFrames: one options value too. | Context7 `/websites/pola_rs` |
| row estimates in plan (`ESTIMATED ROWS: 4`) | statistics from sources (`stats(s,p,col)`) | planned | 3 | Feeds the cost-based phase (Calcite-style). | PE-01; DESIGN §3.8 |
| streaming engine `collect(engine="streaming")` | morsel-driven execution over partitions (`foldxt`) | adapted | 5 | Prototype already folds partitions in parallel; phase 5 adds out-of-core spilling. | PE-09; DESIGN §3.7 |
| `engine="gpu"` | none | skip | - | Out of scope. | Context7 `/websites/pola_rs` |
| `scan_parquet/csv/ipc/ndjson/delta/iceberg/lance/...` (11 `scan_*`) | `scan_parquet`, `scan_csv`, `scan_arrow` sources | planned | 2 | Built-ins: CSV, Arrow IPC, Parquet; the rest via extensions (one file each). | PE-09; BRIEF "Sources and sinks" |
| `sink_parquet/csv/ipc/ndjson/batches/...` (7 `sink_*`) | `sink(q, ParquetSink(path))` streaming writes | planned | 5 | Verified `sink_parquet` round-trip (PE-09). | PE-09 |
| `collect_all` (shared plans) | `collect(q1, q2)` with subplan sharing | planned | 5 | | PE-10 |
| `show_graph` / `format="tree"` | `explain(q; format=:tree)` | planned | 3 | Prototype prints `+-` trees already. | PE-12; Context7 `/websites/pola_rs` |
| `collect(background=True)` → `InProcessQuery` | async collect through ChuiTypes effects | planned | 5 | | Context7 `/websites/pola_rs` |
| lowered kernel listing | `code_lowered(q)` | prototype | 3 | Polars has no equivalent; ChuiFrames' JIT-specific advantage. | DESIGN §3.9 |
| GIL-free UDFs | Julia functions compile into the fused kernel | adapted | 4 | Polars warns UDFs are slow (Python); in Julia they are first-class, so codegen is the main win. | DESIGN §3.7; BRIEF "Code generation" |

## UNVERIFIED

- `show_graph` (graphviz rendering) was not run; only `explain(format="tree")` was (PE-12).
- `collect(background=True)` returning `InProcessQuery`: from the Context7 signature only.
- `engine="gpu"`: from the Context7 `explain` signature only.
- `rolling_*` expression methods, `sample`, `transpose`, `describe`, `cast(strict=)`, `drop_nulls`,
  `interpolate`: names from the Context7 API reference; not called.

## Evidence

- **PE-01** `py_probe.py`, `scan_parquet(...).filter(x>1).select(g,x).group_by(g).agg(sum)`, `explain()`:

  ```text
  AGGREGATE[maintain_order: false]
    [col("x").sum().alias("s")] BY [col("g")]
    FROM
    Parquet SCAN [t.parquet]
    PROJECT 2/4 COLUMNS
    SELECTION: col("x") > 1
    ESTIMATED ROWS: 4
  ```

- **PE-02** same query, `explain(optimized=False)`:

  ```text
  AGGREGATE[maintain_order: false]
    [col("x").sum().alias("s")] BY [col("g")]
    FROM
    SELECT [col("g"), col("x")]
      FILTER col("x") > 1
      FROM
        Parquet SCAN [t.parquet]
        PROJECT */4 COLUMNS
  ```

- **PE-03** CSE: `with_columns(a=(x*2).sum(), b=(x*2).sum()+1).explain()` shows
  `[(col("x") * 2).sum().alias("__POLARS_CSER_0x100000004")]` computed once and reused by `a` and `b`.
- **PE-04** `x - x.mean().over("g")` gave `dm = [-1.0, 0.0, 1.0, 0.0]`; `when(x>2).then("hi").otherwise("lo")`
  gave `[lo, lo, hi, hi]`. Printed table has a dtype row (`str`, `i64`, `f64`) under the headers.
- **PE-05** `hasattr(pl.col("x"), ns)` True for `str dt list struct cat arr bin name meta`;
  `cs.numeric()` → `['x','y','z']`; `cs.starts_with("x","y")` → `['x','y']`; `sum_horizontal`/`max_horizontal` ran.
- **PE-06** semi → `[{k:1},{k:2}]`; anti → `[{k:3}]`; cross → 9 rows; `join_asof` on `t` matched
  `t=10` to the `t=9` row (backward).
- **PE-07** `pivot(on="g", index="x", values="y")` columns `['x','a','b','c']`; `unpivot` shape `(8,3)`; `explode` → `[1,2,3]`.
- **PE-08** `group_by_dynamic("t", every="2h")` sums `[1,5,9]`; `rolling("t", period="2h")` sums `[0,1,3,5,7,9]`.
- **PE-09** `collect(engine="streaming")` returned the 3-group result; `sink_parquet` round-trip shape `(3,2)`;
  `scan_*`: arrow_c_stream, csv, delta, external_reader, iceberg, ipc, lance, lines, ndjson, parquet, pyarrow_dataset;
  `sink_*`: batches, csv, delta, iceberg, ipc, ndjson, parquet.
- **PE-10** `py_probe2.py`: join strategies `('inner','left','right','full','semi','anti','cross')`;
  unique keep `('first','last','any','none')`; `LazyFrame.pivot` True; `SQLContext` → `[{'s': 3}]`;
  `filter(x>0).head(2).explain()` → `SLICE[offset: 0, len: 2]` above `FILTER`; 223 public `Expr` methods;
  `collect_all` True.
- **PE-11** `[1.0, None, NaN]`: `sum` → `nan`, `null_count` → 1, `is_nan().sum()` → 1, `mean` → `nan`;
  `fill_nan(None).mean()` → `1.0` (nulls skipped by default).
- **PE-12** inline `uv run --python 3.13 --with polars python -I -c '…'`:
  `with_columns(a=x+1, b=col("a")*2)` → `ColumnNotFoundError` (no same-call references);
  `join_where(a > b)` → `[{a:5, b:3}]`; `concat(how="diagonal")` filled `None`;
  `fill_null(strategy="forward")` → `[1, 1]`; `to_dummies` → `['x_1','x_2']`;
  `explain(format="tree")` printed a box-drawn tree with `FILTER` / `predicate:` / `FROM:` nodes.
