# Research: the Source/Sink interface

- **Date:** 2026-10-20. **Lane:** phase1-research (researcher). **Status:** evidence for the
  source/sink ADR; nothing here is a decision. Proposals are labelled **Proposal**.
- **Question.** (1) What do Tables.jl's partition protocol and the Julia readers (Arrow, CSV,
  Parquet2) and databases (DBInterface, SQLite, DuckDB) actually expose? (2) What common shape do
  the connector interfaces of Trino, DataFusion, Polars, DuckDB, Arrow Dataset and Spark share?
  (3) What would a streaming (ChuiTypes stream) source need? (4) What do the sinks offer? Then: a
  Source/Sink function list with names distinct from Tables.jl, compared with the contract sketch.
- **Inputs.** The contract `chui-frames.md` PROVISIONAL section "Source and Sink interface
  (sketch)" (coordinator `contracts/`), ADR-0009 §7, ADR-0010 rule 6, prototype DESIGN §3.7/§3.8
  (read only), this repo's consumed contract `test/contracts/chui-types.md` (streams PROVISIONAL).

## Versions

| Item | Version / date |
|---|---|
| Julia | 1.13.2 (`julia --startup-file=no`, run with `-t 4` and `-t 1`). The source probes were **not** re-run on 1.10.12. |
| Tables / Arrow / Parquet2 | 1.14.0 / 2.8.1 / 0.2.37 |
| CSV | 0.10.17 in the main probe env; 1.1.0 in a separate env (they cannot share an env with DuckDB 1.5.5, SS-12) |
| DBInterface / SQLite / DuckDB.jl | 2.7.0 / 1.9.0 / 1.5.5 |
| Polars (Python) | 2.0.0 via `uv run --python 3.13 --with polars` |
| Trino | docs "Trino 484" (trino.io/docs/current, read 2026-10-20); SPI source on `master` (2026-10-20) |
| DataFusion | Context7 `/apache/datafusion` (docs on `main`; the upgrade guides go up to 55.0.0) |
| Spark | Javadoc 4.2.0 (spark.apache.org/docs/latest, read 2026-10-20) |
| Arrow Dataset | PyArrow docs v26.0.0 (arrow.apache.org/docs/python/dataset.html) |
| DuckDB C API | duckdb.org/docs/current (no version on the page; © 2026) |

## Method

Scratch environments in the session scratchpad (`ssenv`, `csv11`; `Pkg.add` of registered
versions on 2026-10-20). Scripts `grammar/io_probe.jl` and `grammar/io2.jl` write and read small
tables with each package and print partition counts, types and statistics. Prior art from Context7
first, then official docs and SPI source via WebFetch; Polars' plugin contract was run, not read.

## Findings

### B1. Tables.jl and the Julia readers

- **Tables.jl's partition protocol** (docstrings in Tables 1.14.0, file Tables.jl of its sources):
  `Tables.partitions(x)` returns an iterator of tables that "_must_ have identical schema"; the
  default is `Tables.partitions(x) = (x,)`. `Tables.partitioner(f, itr)` wraps each element in a
  `Tables.LazyTable` materialized on demand; `Tables.partitioner(x)` wraps an iterator of tables.
  There is **no** projection, filter, statistics or row-count hook in Tables.jl: partitions carry
  data only. Verified: a NamedTuple has 1 partition; `partitioner(parts)` yields `[[1,2],[3,4,5]]`;
  `partitioner(i -> (a = [i],), 1:3)` yields `[[1],[2],[3]]` lazily (SS-01).
  **Correction (2026-10-20, lane owner, after the I/O critic).** "No projection, filter …
  hook" is wrong for Tables 1.14.0. Its `scan.jl` defines `Tables.Scan` (select, filter, limit,
  offset), a filter expression algebra, a residual protocol and the generic executor
  `Tables.scan`. CSV 1.1.0 accepts it through `scan=` (LC-10 in [lane-checks.md](lane-checks.md)).
  Partitions themselves still carry data only, with no statistics or row counts.
- **Arrow 2.8.1.** `Arrow.write(file, Tables.partitioner(parts))` writes one record batch per
  partition (`Arrow.Stream` yields sizes `[2, 3]`). An `Arrow.Table` column is a
  `SentinelArrays.ChainedVector` whose `.arrays` are the batches (`[2, 3]`).
  `Tables.partitions(Arrow.Table)` iterates the batches, **but** its `Arrow.TablePartitions` reports
  `Base.IteratorSize == HasLength()` while defining no `length`, so a comprehension or `collect`
  over it throws `MethodError: no method matching length(::Arrow.TablePartitions)`; a `for` loop
  works (SS-02). A Source must iterate it with `for`/`iterate`, or use `.arrays` as the prototype
  did.
- **CSV.** `Tables.partitions(CSV.File)` is 1 partition in 0.10.17 and 1.1.0. `CSV.Chunks` is the
  partitioned reader: in 0.10.17 it throws `ArgumentError: unable to iterate chunks from input file
  source` unless the parse is threaded (it worked with `-t 4` and 200 000 rows: `[107937, 92063]`);
  in 1.1.0, `CSV.Chunks(f; ntasks = 2)` returned a single chunk of 200 000 rows. `CSV.Rows`
  streams rows. CSV 1.1.0 also exports `LazyFile` (not explored). CSV has no statistics (SS-03).
- **Parquet2 0.2.37.** `Parquet2.Dataset` is a Tables.jl table whose `Tables.partitions` are the
  row groups (`[2, 3]`); `length(ds)` is the row-group count. `Parquet2.load(ds[k], "b")` reads one
  column of one row group (strings come back as `Parquet2.StringRefVector`).
  `Parquet2.ColumnStatistics(ds[k]["a"])` gives `min`, `max`, `n_null`, `n_distinct` (here
  `(3, 5, 0)`), and `(nothing, nothing)` when the file was written without
  `compute_statistics = true` (SS-04).
- **DBInterface 2.7.0** (its DBInterface.jl source file): `connect`, `prepare(conn, sql)`,
  `execute(stmt, params)` / `execute(conn, sql, params)` (`execute(conn, sql, params) =
  execute(prepare(conn, sql), params)`), `executemany`, `executemultiple`, `transaction`,
  `lastrowid`, `close!`. Results are driver-defined; both drivers below return Tables.jl tables.
- **SQLite 1.9.0.** `SQLite.load!(tbl, db, "t")` creates/loads a table;
  `DBInterface.execute(db, sql)` returns `SQLite.Query{false}`, `Tables.istable == true`,
  1 partition; prepared statements with positional params work (SS-05).
- **DuckDB.jl 1.5.5.** `DBInterface.execute(con, sql)` returns `DuckDB.QueryResult`
  (`istable`); `Tables.partitions` on `SELECT * FROM range(5000)` yields **3** partitions (DuckDB's
  result chunks), also with the `DuckDB.StreamResult` result type. `DuckDB.register_table(con, tbl,
  name)` exposes any Tables.jl table to SQL (it calls `columntable(tbl)`, i.e. materializes, then
  scans it with a Julia table function `julia_tbl_scan` registered with **projection pushdown on**,
  an **exact** cardinality and `max_threads = ceil(rows / ROW_GROUP_SIZE)`; source
  file table_scan.jl). `DuckDB.create_table_function(con, name, params, bind, init, main, extra,
  projection_pushdown, init_local)` is the general hook (source file table_function.jl). DuckDB reads
  Parquet itself (`read_parquet(...)` returned the 5 rows). Sinks: `DuckDB.Appender` +
  `DuckDB.append` + `end_row` + `close`, and `DuckDB.load!(con, tbl, name)` (SS-06).
- **Dependency conflict (matters for extensions and `integration/`).** DuckDB.jl 1.5.5 needs
  `FixedPointDecimals` 0.4–0.6; FixedPointDecimals 0.6.5 needs `Parsers = "2.7"`; CSV 1.1.0 needs
  `Parsers = "3"`. The resolver therefore gives either DuckDB 1.5.5 + CSV 0.10.17 or CSV 1.1.0 +
  DuckDB **0.2.6** (SS-12).

### B2. Prior art: the common shape

| | Schema | Splits / partitions | Projection | Filter pushdown and exactness | Limit | Statistics | Ordering | Streaming |
|---|---|---|---|---|---|---|---|---|
| **Trino SPI** | `ConnectorMetadata` (table/column handles) | `ConnectorSplitManager.getSplits(txn, session, table, dynamicFilterColumns, constraint) → ConnectorSplitSource`; `ConnectorPageSource.getNextSourcePage()`, `isFinished()`, `isBlocked()` (a future: backpressure) | `applyProjection(session, handle, projections, assignments)` | `applyFilter(session, handle, constraint) → Optional<ConstraintApplicationResult>` carrying the **remaining filter** Trino still applies | `applyLimit(…, long limit)` with `limitGuaranteed`; `applyTopN(…, sortItems, …)` with `topNGuaranteed` | `getTableStatistics` (for the CBO) | `getTableProperties` (no Javadoc); TopN is the only sort pushdown | Bounded per query; page source pulled with `isBlocked` |
| **DataFusion** | `TableProvider::schema()` | `ExecutionPlan` with `Partitioning::UnknownPartitioning(n)`; `execute(partition) → SendableRecordBatchStream` | `scan(state, projection: Option<&[usize]>, filters, limit)` | `supports_filters_pushdown(&[&Expr]) → Vec<TableProviderFilterPushDown>`: `Exact` (no `FilterExec` added), `Inexact` (engine re-filters), `Unsupported` | `limit: Option<usize>` in `scan` (a hint) | `partition_statistics(partition)` (renamed from `statistics` in 53.0.0) | Output ordering in `PlanProperties` / `EquivalenceProperties` ("avoid inserting a `SortExec`") | `Boundedness::{Bounded, Unbounded}`, `EmissionType::Incremental` |
| **Polars IO plugin** | `schema=` dict or callable ("before projection pushdown") | The callable returns an iterator of DataFrames (`batch_size` hint) | `with_columns` | `predicate`: the docs say "the reader must filter"; **verified: Polars does not re-apply it** (SS-07) | `n_rows`: **not re-applied either** (SS-07) | none | none | Iterator (pull); marked unstable |
| **DuckDB C API** | bind callback | `duckdb_init_set_max_threads`, local init per thread | `duckdb_table_function_supports_projection_pushdown`; `duckdb_init_get_column_count/_index` | not in the C API docs | none found | `duckdb_bind_set_cardinality(info, n, is_exact)` | none found | chunks pulled by the main function; replacement scans map unknown table names to a table function |
| **Arrow Dataset** (PyArrow 26) | inferred from files | fragments (one per Parquet file by default; `split_by_row_group`); Hive/directory partitioning; `get_fragments(filter)` | `columns=` list or dict of expressions | `filter=` expression: skips non-matching files, and the result is **row-exact** ("rows which do not match … will not be included") | `head` (not checked) | Parquet row-group statistics for skipping | none found | `Dataset.to_batches()` iterator, `batch_size` (default 1 Mi rows) |
| **Spark DSv2** (4.2.0) | `Scan.readSchema()` | `Batch.planInputPartitions()`, `PartitionReaderFactory` | `SupportsPushDownRequiredColumns.pruneColumns(requiredSchema)` ("OK to do the pruning partially") | `SupportsPushDownFilters.pushFilters(filters)` "returns filters that need to be evaluated after scanning"; `pushedFilters()` lists both exact and inexact pushed filters | `SupportsPushDownLimit.pushLimit(int)` + `isPartiallyPushed()` ("Spark will do LIMIT again") | `SupportsReportStatistics.estimateStatistics()` | `SupportsReportOrdering.outputOrdering()` ("order in each partition"); global order via `SupportsReportPartitioning` | `MicroBatchStream.latestOffset()`, `planInputPartitions(start, end)` per micro-batch |

**The common shape** (what at least four of the six have):
1. **Schema before data**, as names and types (all six).
2. **Planning separated from reading**: a planning call returns partition/split handles; reading a
   handle is a separate, parallelisable call (Trino, DataFusion, Spark, Arrow, DuckDB threads).
3. **Projection pushdown** as a column list; partial pruning is allowed (Spark) (all six).
4. **Filter pushdown with an explicit exactness answer per conjunct**: Exact/Inexact/Unsupported
   (DataFusion), "remaining filter" (Trino), "filters to evaluate after scanning" (Spark). Polars is
   the outlier: the source must be exact and nothing tells the engine otherwise.
5. **Limit pushdown with a guarantee flag** (`limitGuaranteed`, `isPartiallyPushed`) or a hint.
6. **Statistics** at two levels: a row-count/cardinality estimate with an exactness bit (DuckDB
   `is_exact`, DataFusion precision, Spark estimate), and per-partition column min/max/null
   counts for pruning (Parquet, DataFusion `partition_statistics`).
7. **Ordering guarantees** declared by the source so sorts can be skipped (DataFusion, Spark,
   Trino TopN).
8. **Boundedness** as a declared property (DataFusion `Boundedness`, Spark micro-batch streams).

### B3. ChuiTypes streams as a source

ChuiTypes' stream API is PROVISIONAL (`test/contracts/chui-types.md`: push vs pull, backpressure,
operators and schedulers are all open; the adapter lives in ChuiFrames using only ChuiTypes' public
API). From B2, a streaming variant needs:
- **A declared boundedness** (`Bounded`/`Unbounded`), so the planner can reject plans that cannot
  finish (DataFusion's `Boundedness`).
- **An unbounded partition iterator**: `Base.IteratorSize` of `SizeUnknown`/`IsInfinite`, each
  element a batch with the declared schema (Tables' "identical schema" rule still applies).
- **Backpressure**: a pull model gives it for free (Trino `isBlocked` future, Polars/Arrow
  iterators); a push stream must be bridged through a bounded buffer (a `Channel` of size `k`
  is the obvious Julia bridge; ChuiTypes' Channel adapter is in its contract, names PROVISIONAL).
- **Offsets/checkpoints** only if replay is required (Spark `latestOffset`, `planInputPartitions(
  start, end)`); not needed for a v0.
- **Which verbs work unbounded** (from the prototype's own classification of row-wise steps,
  DESIGN §3.7): row-wise `filter`, `select`, `rename`, row-wise `mutate`, and `head(n)` (terminates
  the stream). Blocking: `arrange`, `summarise`, any whole-column node (`mean(c.x)`, `c.x |> f`),
  `group_by ⨟ mutate` windows, joins, `nest`. These need windowing (time or count) or must be
  rejected at plan time.

**Proposal:** bounded-only v0, but reserve `source_boundedness(s)` (default `:bounded`) in the
interface now, so a streaming source is a later additive method rather than a contract change.
The ChuiTypes adapter can then ship as a bounded source (a finite stream drained into partitions)
first.

### B4. Sinks

- **Arrow IPC, incremental.** `open(Arrow.Writer, path_or_io; file = …)` then `Arrow.write(w, tbl)`
  per batch, then `close`. Each `write` became one record batch (`[2, 3, 1]`). The default for
  `open(Writer, io)` is `file = true` (Arrow's write.jl source); for appendable output use `file = false`
  (stream format). `Arrow.append(path, tbl)` works **only on stream-format files**
  (`ArgumentError: append is supported only to files in arrow stream format` otherwise); after it
  the stream had `[2, 3, 1, 2]` batches. `Arrow.write(file, Tables.partitioner(parts))` writes
  one batch per partition (SS-08).
- **Parquet2.** `Parquet2.writefile(path, Tables.partitioner(parts); compute_statistics = true)`
  writes one row group per partition (`length(Dataset) == 2`, sizes `[2, 3]`); the only
  row-group/statistics-related field of `Parquet2.WriteOptions` is `compute_statistics`, so row-group
  size is set by the caller's partitioning (matches DESIGN §3.8). Without `compute_statistics`,
  min/max are `nothing` (SS-04, SS-09).
- **CSV.** `CSV.write(path, Tables.partitioner(parts); partition = true)` writes one file per
  partition, named `path_1`, `path_2` (suffix *after* the extension: `cp1.csv_1`). With CSV
  0.10.17 under `-t 4`, the **first** partitioned write in a session failed twice out of two
  sessions (`TaskFailedException … BoundsError: attempt to access 1-element Vector{String} at index
  [2]`); later calls and all `-t 1` calls succeeded. CSV 1.1.0 succeeded 3/3 under `-t 4`
  (SS-10). Cause not traced (UNVERIFIED); treat 0.10.x partitioned writes as unreliable.
- **Databases.** `SQLite.load!(tbl, db, name)`; `DuckDB.load!(con, tbl, name)` (registers the table
  then `CREATE TABLE … AS SELECT`); `DuckDB.Appender` for row-wise appends (SS-05, SS-06).
  Common sink shape: open with a schema, write batches in order, close/commit. Spark/Trino
  write-side SPIs were not researched.

### Proposal: Source/Sink functions (names distinct from Tables.jl)

Labelled **proposal**, for the source/sink ADR. Required methods are marked (R); everything else
has a default, so "a new source is one file" (BRIEF) stays true.

```julia
abstract type Source end
source_schema(s)::Vector{Pair{Symbol,Type}}                       # (R)
source_label(s)::String                                           # (R) for explain()
plan_partitions(s; columns, filters, limit, morsel)::Vector       # (R) handles; may prune by stats
read_partition(s, p, columns::Vector{Symbol})                     # (R) → Tables.jl table of `columns`
filter_support(s, conjunct)::Symbol = :unsupported                 # :exact | :inexact | :unsupported
limit_support(s)::Symbol = :none                                   # :exact | :hint | :none
partition_stats(s, p, col) = nothing                               # (lo, hi, nnull) or nothing
row_count(s) = nothing                                             # (n, exact::Bool) or nothing
partition_row_count(s, p) = nothing                                # (n, exact::Bool) or nothing
source_ordering(s) = Pair{Symbol,Symbol}[]                         # [:ts => :asc]; per-partition order
source_groups(s) = Symbol[]                                        # pre-grouped (clustered) columns
isthreadsafe(s) = true
source_boundedness(s) = :bounded                                   # reserved; :unbounded later

abstract type Sink end
open_sink(k, schema)            # → state
write_partition!(state, part)   # one Tables.jl table, in order
close_sink!(state)              # flush, footer/metadata, commit
```

**Compared with the contract sketch**, what the sketch lacks:
1. **Filter exactness.** The sketch passes `filters` to `read_partition` but cannot say whether
   the source applied them exactly, so the engine must always re-filter (safe but wasteful) or
   trust blindly (Polars' behaviour, SS-07). Add `filter_support`.
2. **Planning-time pushdown.** In the sketch, filters reach only `read_partition`; prior art
   pushes projection/filters/limit at planning (`scan`, `applyFilter`, `ScanBuilder`) so pruning
   whole partitions happens before reading. Either `plan_partitions` takes them, or the prototype's
   separate `partition_stats` pruning stays the only planning-time pruning.
3. **Limit pushdown** with a guarantee flag (Trino, Spark, DataFusion, Polars).
4. **Cardinality** (`row_count`, `partition_row_count` with an exactness bit; DuckDB, Spark,
   DataFusion). Needed for `nrow` without a scan and for join planning.
5. **Ordering** (`source_ordering`): lets `arrange` and ordered windows skip a sort.
6. **`partition_stats` richness:** null counts (Parquet2 has `n_null`), and the sketch's rule
   "NaN/missing ⇒ nothing" should stay.
7. **Boundedness** (B3).
8. **Names:** the sketch's `source_partitions` reads like a twin of `Tables.partitions`; a planning
   verb (`plan_partitions`) makes the difference (handles, not tables) visible. `source_schema`
   vs `Tables.schema` is already distinct.
9. **Tables.jl bridge:** any `Tables.partitions`-capable input should get a default Source
   (`read_partition` = the partition; no stats, no pushdown), so CF-001 holds for lazy queries too.

## UNVERIFIED

- All source probes ran on Julia 1.13.2 only (not 1.10.12).
- DuckDB.jl result chunk size (3 partitions for 5000 rows suggests 2048-row vectors; not measured).
- Cause of the CSV 0.10.17 partitioned-write failure under threads.
- `CSV.LazyFile` (1.1.0) and why 1.1.0's `CSV.Chunks(ntasks = 2)` returned a single chunk.
- Trino `LimitApplicationResult` field docs (only the `applyLimit` Javadoc and connector guide
  were read); `getTableProperties` semantics (no Javadoc).
- Spark `SparkDataStream.initialOffset/commit/stop` descriptions (the page did not show them).
- DuckDB C API filter pushdown (not in the docs page; may exist in the C++ API).
- Arrow Dataset limit/`head` pushdown and ordering.
- DataFusion exact crate version for the cited docs (Context7 serves `main`).
- Write-side SPIs of Trino/Spark/DataFusion.

## Evidence

Scripts in the session scratchpad (`grammar/io_probe.jl`, `grammar/io2.jl`, `csv11/`,
`priorart/`). Command for SS-01..SS-06, SS-08, SS-09:
`julia --startup-file=no -t 4 --project=<scratch>/ssenv io_probe.jl`.

- **SS-01 partitions.** `partitions(NamedTuple) count => 1`; `partitioner(parts) partitions =>
  [[1, 2], [3, 4, 5]]`; `partitioner(f, itr) lazily => [[1], [2], [3]]`.
- **SS-02 Arrow partitions.** `Arrow.Stream batches => [2, 3]`; `partitions(Arrow.Table) sizes =>
  ERR MethodError: no method matching length(::Arrow.TablePartitions)`;
  `ChainedVector.arrays lengths => [2, 3]`; `io2.jl`: `partitions(Arrow.Table) sizes via for-loop:
  [2, 3]  Base.IteratorSize: Base.HasLength()`.
- **SS-03 CSV read.** `partitions(CSV.File) count => 1`; `Threads.nthreads() => 4`;
  `CSV.Chunks(ntasks=2) partitions => [107937, 92063]`; with `-t 1` (first run):
  `ERR ArgumentError: unable to iterate chunks from input file source`; CSV 1.1.0 (`csv11`):
  `partitions(CSV.File) count: 1`, `CSV.Chunks: [200000]`,
  `names: [:Chunks, :File, :LazyFile, :RowWriter, :Rows, :write]`.
- **SS-04 Parquet2.** `Dataset istable / nrowgroups => (true, 2)`; `partitions(Dataset) sizes =>
  [2, 3]`; `load(rowgroup, col) typeof => Parquet2.StringRefVector{String, …}`;
  `ColumnStatistics rg1 col a => (3, 5, 0)` (row group 2); `Parquet2 stats without
  compute_statistics => (nothing, nothing)`.
- **SS-05 SQLite.** `SQLite.load!(tbl, db, "t") => t`; `execute result istable =>
  (SQLite.Query{false}, true)`; `prepare + execute(params) => ["y", "z"]`;
  `partitions(SQLite.Query) count => 1`.
- **SS-06 DuckDB.** `DuckDB execute result istable => (DuckDB.QueryResult, true)`;
  `register_table … => Int128[6]`; `read parquet via SQL => [5]`; `Appender => ["p", "q"]`;
  `load! => ok`; `partitions(DuckDB result) count => 3`; `io2.jl`: `DuckDB StreamResult:
  DuckDB.QueryResult partitions=3 rows=5000`; names include `Appender, StreamResult, load!,
  register_data_frame, register_table, unregister_table`. Source: `table_scan.jl` lines 97–99
  (`set_stats_cardinality(info, row_count, true)`), 142–143 (`set_max_threads`), 201
  (`columntable(tbl)`), 224–233 (`create_table_function(…, true, …)` = projection pushdown).
- **SS-07 Polars plugin contract.** `uv run --python 3.13 --with polars python -I polars_io.py`
  (polars 2.0.0), a source that ignores its arguments:
  `filter ignored by source -> [1, 2, 3, 4] {'with_columns': ['x'], 'predicate':
  '[(col("x")) > (2)]', 'n_rows': None, 'batch_size': 100000}`;
  `head(2) ignored by source -> 4 {… 'n_rows': 2 …}`.
- **SS-08 Arrow sinks.** `Arrow.Writer incremental (3 writes) => [2, 3, 1]`;
  `Arrow.append(stream file, tbl) => [2, 3, 1, 2]`; `Arrow.append(file-format .arrow) => ERR
  ArgumentError: append is supported only to files in arrow stream format`.
- **SS-09 Parquet2 writer options.** `Parquet2.writefile row-group kwargs => [:compute_statistics]`
  (fields of `WriteOptions` matching row/group/stat).
- **SS-10 CSV partitioned write.** `-t 4`, CSV 0.10.17: `try 1: ERR TaskFailedException … nested
  task error: BoundsError: attempt to access 1-element Vector{String} at index [2]`,
  `try 2: ["cp2.csv_1", "cp2.csv_2"]`, `try 3: […]` (and the first call of `io_probe.jl` failed the
  same way); `-t 1`: 3/3 succeed. CSV 1.1.0 `-t 4`: `partition write 1..3: ["p1.csv_1",
  "p1.csv_2"] …`.
- **SS-11 prior art.** Context7 `/apache/datafusion` (custom-table-providers guide: `scan`,
  `supports_filters_pushdown`, Exact/Inexact/Unsupported text, `Boundedness`, `partition_statistics`
  in upgrading/53.0.0), Context7 `/websites/pola_rs_api_python_stable` (`register_io_source`
  signature), Context7 `/websites/trino_io_current` and WebFetch of trino.io/docs/current/develop/
  connectors.html (Trino 484) and SPI sources `ConnectorPageSource.java`,
  `ConnectorSplitManager.java`, `ConnectorMetadata.java` on GitHub `master`; WebFetch of Spark 4.2.0
  Javadoc (`SupportsPushDownFilters`, `SupportsPushDownLimit`, `SupportsPushDownRequiredColumns`,
  `SupportsReportOrdering`, `read` package summary, `streaming.MicroBatchStream`); DuckDB
  `clients/c/table_functions` and `clients/c/replacement_scans` (docs/current); PyArrow
  `dataset.html` (v26.0.0).
- **SS-12 resolver conflict.** `Pkg.add(name="DuckDB", version="1")` in an env holding CSV 1.1.0:
  `CSV v1.1.0 ⇒ v0.10.17`, `DuckDB v0.2.6 ⇒ v1.5.5`; the reverse `Pkg.add(name="CSV",
  version="1.1")`: `CSV ⇒ v1.1.0`, `DuckDB v1.5.5 ⇒ v0.2.6`. Compat: DuckDB 1.5.5
  `FixedPointDecimals = "0.4, 0.5, 0.6"`; FixedPointDecimals 0.6.5 `Parsers = "2.7"`; CSV 1.1.0
  `Parsers = "3"`.
  **Correction (2026-10-20, from [parquet-csv.md](parquet-csv.md) PQ-11 and PQ-13).** The
  conflict depends on which FixedPointDecimals is already locked. FixedPointDecimals 0.4.0–0.4.2
  do not depend on Parsers. A fresh `Pkg.add(["CSV", "DuckDB"])` resolves CSV 1.1.0 + DuckDB
  1.5.5 + FixedPointDecimals 0.4.2, and a DECIMAL query works. The downgrade above happens only
  when FixedPointDecimals 0.6 is already locked in the environment.
