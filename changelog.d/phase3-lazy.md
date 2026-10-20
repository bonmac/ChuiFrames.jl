### Added
- The lazy engine (phase 3, ADR-0003, ADR-0004): `lazy(t)` (any Tables.jl table, a `Frame` or a
  `Source`) gives a `LazyFrame`; verbs applied to it record a plan; `collect(q; morsel, threads)`
  optimizes and runs it, with the same results and the same exception types as eager (CF-008).
  `optimize(q)`, `explain(q)` and `code_lowered(q)` (the rendered kernel, ADR-0003 rule 13).
  A verb applied to a `Source` (e.g. `scan_file(path)`) starts a lazy query, and
  `collect(source)` reads one through the engine.
- The optimizer: constant folding, filter splitting, predicate pushdown (below `select`,
  `rename`, `relocate` and into the source as a `Tables.Scan`), projection pushdown, limit
  pushdown, and partition pruning from `partition_stats` with the NaN/`missing` safety rules.
  Rules move a filter, prune or stop a scan early only past steps that cannot throw (spec §1).
- Morsel execution: per-row stages run per partition, in parallel over contiguous morsel ranges
  when stateless; results gathered in morsel order; a limit runs sequentially and stops early
  when allowed. A failing lazy run is replayed eagerly so the eager exception is raised.
- Lazy-vs-eager property tests (CF-008): random pipelines on data with NaN, -NaN, ±0.0, Inf and
  `missing`, random morsel sizes and threading; optimizer health; pruning soundness (with a test
  source whose statistics leave NaN out); rendered kernel == interpreter. A differential test
  checks each `Tables.Scan` translation against `filter` (ADR-0004 rule 1).

### Changed
- Every source partition is read with the source's declared column types (`conform_types`), in
  `read_source` as in the lazy engine, so a source whose partitions differ in type (e.g. `Int`
  in one, `Float64` in another) reads the same either way. A declared type a column cannot be
  converted to exactly (an abstract `Any`, `Date` values under a declared `DateTime`) leaves that
  column as read.
- `vcat_columns` concatenates primitive columns of one element type, and dictionary columns
  sharing one dictionary, without boxing; the latter stay dictionary columns.
- **Breaking:** `var` and `std` of fewer than two values (with `corrected = false`: of no values)
  return `missing`, as dplyr's NA and the null of Polars and DuckDB, instead of
  `Statistics.var`'s NaN. Their result type is now always nullable (`Union{Missing, Float64}`).
  User decision at the phase-2c ★ (ADR-0002 rule 10 note, 2026-10-20).
- **Breaking:** `group_by`'s `drop` keyword defaults to `nothing`, which inherits the input's flag,
  as dplyr's `.drop = group_by_drop_default(.data)`. A `group_by` on a `drop = false` frame now
  stays `drop = false` (it used to reset to `true`). An explicit `drop = true`/`false` wins, and an
  ungrouped frame still gives `true`. `show` prints an explicit `drop = true` too. User decision
  at the phase-2c ★ (2026-10-20).
