<!-- package brief: coordinator commit 16b9e6a, prompts/30-chui-frames.md, copied 2026-10-19 -->
# Package brief: ChuiFrames.jl (data frames)

The lead session hands this brief to the agents working on **ChuiFrames.jl**.
- **Upstream:** it depends on released versions of **ChuiCore.jl** (monoids, composition, recursion schemes, transducers per the ADR) and **ChuiTypes.jl** (effects for I/O and async work, streams as sources).
- **Downstream:** the future ChuiStats, ChuiLearn, ChuiSpatial and ChuiPlot build on it.

Lanes for this package edit and commit only in `<root>/ChuiFrames.jl`.

**Read first:**
- `docs/agent/ECOSYSTEM.md`.
- `<root>/reference/prototype/DESIGN.md` and its code: the working prototype.
  - **Keep its ideas:** `c.x` deferred expressions, verbs as data with `⨟`, monoid aggregation, and the logical → optimized → physical plan with `explain`/`code_lowered`.
  - **Keep its tests:** the eight review-found bugs are regression tests.
  - Rewrite the code to production quality.
- The contracts: `chui-core.md` and `chui-types.md` (consumed; carry contract tests for them), and `chui-frames.md` (promised downstream).
- `HANDOFF.md`.

## Scope

- **API parity:** match dplyr, tidyr, readr, haven, stringr, lubridate, forcats, purrr and tibble in **syntax and features**, as far as Julia allows.
  - Keep the prototype's macro-free design (`c.x`, dots for elementwise, plain calls for reductions) unless an ADR shows a better one.
  - Produce a **parity matrix** per R package (function → status → notes → test) and treat it as the test checklist.
- **Engine:**
  - **Arrow:** Apache Arrow memory and semantics: validity bitmaps for nulls, dictionary encoding, string views.
  - **One engine, two modes:** lazy and eager share it. The optimizer runs rule-based rewrites (expressed with ChuiCore's recursion schemes), then cost-based ones, as in Calcite.
  - **Parallel and out-of-core:** multicore execution in chunks ("morsels"), asynchronous I/O through ChuiTypes effects, and out-of-core spilling to disk.
  - **Distributed:** a distributed mode; evaluate Dagger.jl, Distributed.jl and Arrow Flight.
  - **Joins:** hash joins, with broadcast versus shuffle.
  - **Fast group-by:** typed keys and radix partitioning. This was the prototype's bottleneck.
  - **Code generation:** generated code for each fused stage, keeping an interpreter for small inputs.
- **Ideas to borrow from:**
  - data.table: speed, and grouping by reference;
  - sqldf: SQL over data frames;
  - dtplyr and dbplyr: translating a pipeline into SQL for a backend;
  - pandas;
  - Ibis: deferred expressions, multiple backends;
  - Polars: the lazy engine, the expression API;
  - DuckDB;
  - Calcite;
  - Druid and Pinot;
  - Presto/Trino: the connector SPI, distributed stages.
- **tibble-style printing:**
  - fit the terminal width and height;
  - shorten numbers to significant digits and long strings with `…`;
  - show column types under the headers, and group information;
  - show "… with N more rows / M more columns" footers.
- **Sources and sinks:** a pluggable interface carrying partitions, column selection, pushed-down filters and statistics.
  - **Built in:** CSV, Arrow IPC, Parquet.
  - **Through package extensions:**
    - databases via DBInterface: SQLite, DuckDB, Postgres;
    - Excel (XLSX.jl);
    - SAS/SPSS/Stata like haven (ReadStat.jl);
    - JSON, HTTP and S3 object stores.
  - **Extensibility:** adding a new source takes one file and no core changes. This interface is published in the `chui-frames.md` contract.
- **Name conflicts:** use ChuiCore's conflict-banner utility to list real conflicts on interactive load. dplyr's style is the model.

## Independence

- **Ahead of upstream:** start with the parts that don't depend on other Chui packages: Arrow storage, printing, the readr-style readers, the eager verbs, and the expression grammar.
  - Adopt ChuiCore and ChuiTypes APIs only from tagged releases.
  - Until then, keep a small internal adapter module, so switching is one change.
- **Missing upstream features:** write cross-repo requests in `<root>/requests/` for the lead to schedule, instead of working around them silently. A ChuiFrames lane never edits upstream code.

## Testing and benchmarks (on top of the ecosystem rules)
- **Lazy vs eager:** property tests on randomly generated pipelines. This is the core correctness guarantee.
- **Differential tests:** against dplyr (`Rscript`), DuckDB and Polars (`uv`) on generated data, including `missing`/NaN edge cases and empty results.
- **Snapshot (golden-output) tests:** printing output and `explain`/`code_lowered` output.
- **Benchmarks** against Polars, DuckDB, data.table, dplyr, DataFrames.jl, Tidier.jl and pandas: the db-benchmark group-by and join suites, a TPC-H subset, string- and time-heavy workloads, and TTFX. Set target ratios per family in an ADR, and fail CI on regressions.

## Phases
1. **Research and ADRs:**
   - parity matrices;
   - the storage design (Arrow.jl vs your own buffers);
   - the expression grammar;
   - the engine architecture, based on the prototype;
   - the source/sink interface;
   - the dependency budget.
   - ★ Report to the lead before implementing.
2. **Eager frame:** Arrow-backed storage, the core dplyr/tidyr verbs, tibble-style printing, CSV/Arrow/Parquet I/O, the conflict banner.
3. **Lazy engine:** plans, optimizer, pushdown and pruning (including NaN/missing statistics), `explain`/`code_lowered`.
4. **Joins**, the fast group-by, and code generation.
5. **Scale:** parallel execution, async I/O, out-of-core, a distributed prototype.
6. **Extensions:** stringr/lubridate/forcats/haven parity and the I/O extensions.
7. **Docs and the benchmark report.** Then v0.1.0, after the user confirms; record it in `<root>/releases.md`.

## Done means
- **Parity:** the parity checklist is green for the target set.
- **Correctness:** the lazy==eager and differential suites pass.
- **Performance:** benchmarks are within budget.
- **Contracts:** contract tests pass against the latest upstream releases.
- **Quality checks:** JET and Aqua are clean.
- **Standalone:** `]test` passes from a fresh clone.
