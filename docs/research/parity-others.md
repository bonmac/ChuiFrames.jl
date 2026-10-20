# Ideas to borrow: data.table, pandas, Ibis, DuckDB, dbplyr, dtplyr, sqldf

**Question.** Which features of data.table, pandas, Ibis, DuckDB, dbplyr, dtplyr and sqldf should
ChuiFrames borrow, adapt or reject, and in which phase? This is one table of features and ideas,
not a per-function parity matrix (the per-function matrices are the R-package ones and
parity-polars.md / parity-julia-frames.md).

**Date.** 2026-10-20.

**Versions.**

- Python 3.13.13 via `uv`: pandas 3.0.6, DuckDB 1.5.6, Ibis 12.0.0 (`ibis-framework[duckdb]`), Polars 2.0.0.
- R 4.4.2 via `Rscript`: data.table 1.17.8, dplyr 1.2.0, dbplyr 2.5.1, dtplyr 1.3.2, duckdb (R) 1.5.0,
  RSQLite 2.4.6. sqldf is **not installed** (rows from the CRAN page, sqldf 0.4-12, published 2026-01-30).
- Docs: Context7 `/websites/ibis-project` (read 2026-10-20); CRAN sqldf page (fetched 2026-10-20).

**Method.**

```sh
cd <scratchpad>/eng-parity
uv run --python 3.13 --with polars --with pandas --with duckdb --with 'ibis-framework[duckdb]' --with pyarrow python -I py_probe.py
uv run --python 3.13 --with polars --with 'ibis-framework[duckdb]' --with pyarrow --with pandas python -I py_probe2.py
Rscript r_probe.R
```

Scripts are scratch only. Evidence IDs below continue the `PE-` series from parity-polars.md.

**Borrow legend.** `yes` = take as is; `adapt` = take the idea, change the surface; `no` = reject.

**Summary counts (46 rows).** yes 20 · adapt 19 · no 7.

**Headline.** The SQL-translation family (dbplyr, dtplyr, Ibis) shows the same three-step shape:
a backend-neutral expression tree, a per-backend compiler, and `show_query`/`to_sql` to inspect the
output (PE-21, PE-40, PE-42). ChuiFrames' lazy plan is already that tree; a DBInterface extension
that compiles a plan to SQL is the dbplyr idea in Julia. From data.table the idea is speed
(radix ordering, keyed and rolling joins), not the by-reference API. pandas' index alignment is
rejected (PE-20).

## Feature table

| Library | Feature | Borrow? (yes/adapt/no) | ChuiFrames phase | Why | Source |
|---|---|---|---|---|---|
| data.table | `:=` update by reference (no copy) | adapt | 5 | Ran: address unchanged after `DT[, s := sum(x), by = g]` (PE-43). ChuiFrames tables are immutable values; borrow the effect (no copy of untouched columns: share column buffers between input and output) not the mutation. | PE-43 |
| data.table | grouping by reference / `by=` without materialising groups | adapt | 4 | Brief names it. Use radix-partitioned typed keys; group indices, not copies. | BRIEF "Ideas to borrow from"; PE-43 |
| data.table | radix ordering (`forder`, `setorder`) | yes | 4 | Brief's "fast group-by: typed keys and radix partitioning". `forder` exists in the namespace (PE-43). | PE-43 |
| data.table | keys (`setkey`) and keyed subset `DT[J("a")]` | adapt | 4 | Ran: keyed lookup returns the two `a` rows (PE-43). Map to a "sorted-by" property in the plan that lets the optimizer pick merge joins and binary-search filters. | PE-43 |
| data.table | rolling join `x[i, roll = TRUE]` | yes | 4 | Ran: `t = 10` matched `t = 9` (PE-43). Same semantics as Polars `join_asof` and dplyr `closest()`. | PE-43, PE-06 |
| data.table | non-equi joins `on = .(a >= b)` | yes | 4 | dplyr `join_by(a >= b)` is the API target. | UNVERIFIED (not run) |
| data.table | `fread` (fast multi-threaded CSV, type sniffing) | adapt | 2 | Exists (PE-43). The readr parity matrix sets the API; `fread`'s sampling-based type detection is the engine idea. | PE-43 |
| data.table | `fwrite` | yes | 2 | Multi-threaded writer; pair with `write_csv`. | PE-43 |
| data.table | `setDTthreads` / thread control | adapt | 5 | Ran: `getDTthreads()` → 6. Julia's `-t` plus a per-query option. | PE-43 |
| data.table | `DT[i, j, by]` one-bracket syntax | no | - | dplyr verbs are the parity target. | PE-42 |
| data.table | print showing column types `<char> <num>` and `Key: <g>` | yes | 2 | Matches the tibble-style printing goal, and suggests showing sort order/keys. | PE-43 |
| dtplyr | translate dplyr pipeline to data.table code (`show_query`) | adapt | 3 | Ran: `dt[x > 1][, .(s = sum(x)), keyby = .(g)]` (PE-42). Same "pipeline → backend code" idea; ChuiFrames prints its own plan and `code_lowered`. | PE-42 |
| dtplyr | `keyby` (sorted groups) as default for `group_by` + `summarise` | yes | 4 | dtplyr emits `keyby`, so output groups are sorted like dplyr. ChuiFrames must sort group keys by default to match dplyr (Polars does not, PE-01). | PE-42 |
| dtplyr | `lazy_dt` → `as_tibble()` to force | yes | 1 | Same lazy/collect split as the prototype. | PE-42; DESIGN §2 |
| dbplyr | `show_query` for a pipeline | yes | 3 | Ran on SQLite (`memdb_frame`) and DuckDB (PE-40, PE-41). ChuiFrames: `show_query(q)` for SQL backends, `explain(q)` for the native engine. | PE-40, PE-41 |
| dbplyr | nested subquery per verb (`FROM (SELECT … WHERE …) AS q01`) | adapt | 3 | dbplyr 2.5.1 still nests the filter as a subquery (PE-40). Ibis does the same (PE-21). A ChuiFrames SQL compiler should flatten where safe, since its optimizer already merges steps. | PE-40, PE-21 |
| dbplyr | `na.rm = TRUE` dropped in SQL (SQL aggregates skip NULL) | yes | 3 | PE-40: `sum(x, na.rm = TRUE)` → `SUM(x)`. The SQL backend must translate `missing` semantics carefully: SQL skips NULL, Julia propagates. | PE-40 |
| dbplyr | backend translation via `sql_translation()` per connection class | adapt | 6 | One translation table per backend; in Julia, methods on the connection type in a package extension. | PE-41 |
| dbplyr | `memdb_frame` / `lazy_frame` + `simulate_*` to test SQL without a database | yes | 3 | Good for snapshot tests of generated SQL. | PE-40 |
| dbplyr | `collect()` / `compute()` (materialise in the database) | yes | 6 | `compute` = create a temp table remotely; map to a sink. | PE-41 |
| sqldf | `sqldf("select … from df")`: SQL over in-memory data frames | adapt | 6 | Brief names it. sqldf copies frames into SQLite per call (CRAN description). ChuiFrames: either DuckDB extension over Arrow memory (no copy) or a SQL front end that parses into its own plan. | CRAN sqldf 0.4-12 |
| sqldf | pluggable backends (SQLite default via RSQLite; H2, PostgreSQL, MySQL optional) | adapt | 6 | Backend chosen via DBInterface extensions. | CRAN sqldf 0.4-12 |
| sqldf | automatic class inference of the returned columns | no | - | ChuiFrames keeps Arrow types end to end. | CRAN sqldf 0.4-12 |
| pandas | index alignment on arithmetic (`s1 + s2` aligns labels) | no | - | Ran: `{a: NaN, b: 12, c: 23, d: NaN}` (PE-20): silent NaN from label mismatch. dplyr/tibble have no row index; alignment hides bugs and breaks positional broadcasting. | PE-20 |
| pandas | `MultiIndex` / hierarchical rows | no | - | Same reason; tidyr reshaping covers it. | PE-20 |
| pandas | `.pipe(f)` | yes | 1 | Already `\|>` and `c.x \|> f`. | DESIGN §2 |
| pandas | `pd.NA` / nullable dtypes, Arrow-backed dtypes | adapt | 2 | pandas 3.x uses Arrow-backed strings; confirms Arrow storage choice. Default string dtype not checked here. | UNVERIFIED (not run) |
| pandas | `read_*` breadth (Excel, SAS, Stata, SPSS, HTML, …) | adapt | 6 | Breadth target for the I/O extensions (haven parity). | BRIEF "Sources and sinks" |
| pandas | copy-on-write semantics (default in 3.0) | adapt | 2 | Same goal as immutable `Tbl` with shared column buffers. | UNVERIFIED (not run) |
| Ibis | deferred `_` expressions (`_.x > 1`) | adapt | 1 | Ran (PE-21). Julia cannot read a bare `_` (DESIGN §3.1), hence `c.x`. Same idea. | PE-21; DESIGN §3.1 |
| Ibis | one expression API, 22 backends | adapt | 6 | Ran: entry points list 22 backends incl. duckdb, polars, postgres, sqlite, trino, pyspark, druid, clickhouse (PE-23). ChuiFrames: native engine first; DBInterface/SQL backends as extensions. | PE-23 |
| Ibis | `ibis.to_sql(expr, dialect=…)` via SQLGlot | yes | 6 | Ran for duckdb and postgres (PE-21). A dialect-parameterised SQL printer from the plan. | PE-21 |
| Ibis | `memtable` (register in-memory data with a backend) | yes | 6 | Same as dbplyr `copy_to`. | PE-21 |
| Ibis | windowed `group_by(...).mutate(...)` → `OVER (PARTITION BY …)` | yes | 3 | Context7 example shows grouped `mutate` compiling to window SQL; matches prototype's grouped `mutate` = window. | Context7 `/websites/ibis-project` |
| Ibis | schema-first typed tables (`ibis.table(schema=…)`) unbound to data | adapt | 3 | A pipeline over an unbound schema = ChuiFrames' verbs-as-values (`⨟`) plus schema inference. | Context7 `/websites/ibis-project` |
| Ibis | many execution engines of its own (it has no pandas or Dask backend in 12.0.0; DuckDB is the local default) | no | - | Ran: no `pandas`/`dask` among the 22 backends (PE-23); why they are absent is UNVERIFIED. Lesson for ChuiFrames: keep one native engine. | PE-23 |
| DuckDB | relational API (`con.from_df(df).filter(...).aggregate(...)`) | adapt | 6 | Ran (PE-22). A lazy relation object, like ChuiFrames' `LazyTbl`; useful as an extension backend. | PE-22 |
| DuckDB | `explain()` physical tree (HASH_GROUP_BY / PROJECTION / FILTER / scan, `~N rows`) | yes | 3 | Ran (PE-22). Shows row estimates per operator; ChuiFrames' physical plan should too. | PE-22 |
| DuckDB | replacement scans (query a host variable by name: `FROM df`) | adapt | 6 | Ran on a Polars frame (PE-22). sqldf-style SQL over Julia tables via DuckDB.jl. | PE-22 |
| DuckDB | direct Parquet/CSV querying with pushdown (`FROM 't.parquet' WHERE …`) | yes | 2 | Ran (PE-22). Same as Polars `scan_parquet`; built-in sources in ChuiFrames. | PE-22 |
| DuckDB | Arrow zero-copy exchange | yes | 6 | DBInterface extension should pass Arrow buffers, not rows. | UNVERIFIED (not run) |
| DuckDB | morsel-driven parallelism, out-of-core hash aggregate/join | yes | 5 | Brief's "morsels" and spilling. | UNVERIFIED (from DuckDB papers; not run) |
| DuckDB | pandas-scan projection pushdown (`Projections: x g`) | yes | 3 | PE-22 shows the scan reading only `x` and `g`. Same as projection pushdown into sources. | PE-22 |
| DuckDB | redundant duplicate `PROJECTION` nodes in the printed plan | no | - | PE-22 printed two identical projections; ChuiFrames' explain should show the plan after dead-node removal. | PE-22 |
| dbplyr/Ibis/DuckDB | SQL as the interchange format between engines | no | - | ChuiFrames' internal plan stays a Julia value (rewritable by ChuiCore recursion schemes); SQL is only an output for backends. | DESIGN §3.4 |
| data.table / dtplyr | grouped result sorted by key (`keyby`) vs first-appearance (`by`) | adapt | 4 | DataFrames/Tidier return first-appearance order (parity-julia-frames PJ-05); dplyr sorts. Expose an option, default dplyr. | PE-42 |

## UNVERIFIED

- data.table non-equi joins: documented feature, not run here.
- pandas 3.0 default string dtype and copy-on-write: not run.
- DuckDB Arrow zero-copy and morsel/out-of-core execution: from DuckDB documentation and papers
  remembered, not run or re-read today.
- sqldf behaviour beyond the CRAN description: package not installed, nothing run.

## Evidence

- **PE-20** pandas 3.0.6: `pd.Series([1,2,3], index=list("abc")) + pd.Series([10,20,30], index=list("bcd"))`
  → `{'a': nan, 'b': 12.0, 'c': 23.0, 'd': nan}`.
- **PE-21** Ibis 12.0.0: `t.filter(_.x > 1).group_by("g").aggregate(s=_.x.sum())`, `ibis.to_sql(e, dialect="duckdb")`:

  ```sql
  SELECT
    "t1"."g",
    SUM("t1"."x") AS "s"
  FROM (
    SELECT
      *
    FROM "ibis_pandas_memtable_…" AS "t0"
    WHERE
      "t0"."x" > 1
  ) AS "t1"
  GROUP BY
    1
  ```

  The `postgres` dialect printed the same text. Executed result: `b 2`, `a 3`.
- **PE-22** DuckDB 1.5.6: `con.from_df(pdf).filter("x > 1").aggregate("g, sum(x) AS s", "g").explain()`
  printed, top to bottom: `HASH_GROUP_BY (Groups: #0, Aggregates: sum(#1), ~0 rows)`,
  `PROJECTION g x (~1 row)`, `PROJECTION g x (~1 row)`, `FILTER (x > 1) (~1 row)`,
  `PANDAS_SCAN (Projections: x g, ~4 rows)`. `SELECT g, sum(x) s FROM 't.parquet' WHERE x > 1 GROUP BY g`
  → `[('a', 3), ('b', 2), ('c', 4)]`; `con.sql("SELECT * FROM df").pl()` on a Polars frame → shape `(4, 4)`.
- **PE-23** `py_probe2.py`: `entry_points(group="ibis.backends")` → athena, bigquery, clickhouse,
  databricks, datafusion, druid, duckdb, exasol, flink, impala, materialize, mssql, mysql, oracle, polars,
  postgres, pyspark, risingwave, singlestoredb, snowflake, sqlite, trino (22). Inline
  `python -I -c 'import ibis; print(ibis.get_backend().name)'` → `duckdb` (default local backend).
- **PE-40** dbplyr 2.5.1 with RSQLite 2.4.6, `memdb_frame(df, .name = "t") |> filter(x > 1) |> group_by(g) |>
  summarise(s = sum(x, na.rm = TRUE)) |> show_query()`:

  ```sql
  SELECT `g`, SUM(`x`) AS `s`
  FROM (
    SELECT `t`.*
    FROM `t`
    WHERE (`x` > 1.0)
  ) AS `q01`
  GROUP BY `g`
  ```

- **PE-41** same pipeline on `DBI::dbConnect(duckdb::duckdb())`: identical SQL without backticks
  (`) q01` instead of `) AS q01`); `collect()` → `a 3, b 2, c 4`.
- **PE-42** dtplyr 1.3.2, `lazy_dt(df, "dt") |> filter(x > 1) |> group_by(g) |> summarise(s = sum(x)) |> show_query()`:

  ```r
  dt[x > 1][, .(s = sum(x)), keyby = .(g)]
  ```

- **PE-43** data.table 1.17.8: `address(DT)` identical before and after `DT[, s := sum(x), by = g]`
  (`TRUE`); `setkey(DT, g); DT[J("a")]` → 2 rows, printed with `Key: <g>` and `<char> <num>` type row;
  rolling join `r[q2, roll = TRUE]` → `t = 1, 5, 10` matched `v = p, q, r`; `fread`, `fwrite`,
  `setorder`, `forder` exist; `getDTthreads()` → 6.
