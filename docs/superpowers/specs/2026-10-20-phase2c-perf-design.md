# Phase 2c design: the T2 changes (Frame struct, equality, `case_when` type, Parquet statistics, benchmarks)

- **Date:** 2026-10-20. **Branch:** `feat/phase2c-perf`. **Plan:**
  [2026-10-20-phase2c-perf.md](../plans/2026-10-20-phase2c-perf.md).
- **Tier:** T2. Public behaviour changes (`==`/`isequal`/`hash` on `Frame`, `case_when` result
  types and errors), the `Frame` struct, and `ext/`.

## 1. `drop` is a field of `Frame`

- `Frame` gains `drop::Bool`, a trailing optional constructor argument (default `true`), forced to
  `true` when the frame has no grouping columns. Every existing constructor call keeps working.
- `group_by(…; drop = false)` sets it. Row verbs (`filter`, `filter_out`, `arrange`, `head`, the
  slices, `distinct`) go through `take(::Frame, idx)`. With `drop = false`, `take` carries the
  group index forward (`take_gindex`), so every existing group is kept, empty ones too, for any
  key type. That is dplyr 1.2.0's behaviour on a `.drop = FALSE` grouped_df, checked with
  `Rscript`. With `drop = true` nothing changes: the index is rebuilt on demand.
- Column verbs, a partial `ungroup`, `count_by`/`tally`/`add_count` and a group-keeping
  `summarise` carry the flag. `ungroup()` and a new `group_by` reset it.
  - **Divergence:** dplyr's `group_by` inherits `.drop` from its input. Documented and tested.
    Whether to inherit is a ★ question.

## 2. Content equality

- `isequal(a::Frame, b::Frame)` is true when all of these match: names in order, row count,
  grouping columns, the drop flag, and `isequal` on each column.
- `hash` is consistent with it.
- `==` is `false` when the structure differs. Otherwise it combines the columns as `==` on
  vectors does, so the result can be `missing`.
- The group index and the element types are not compared. So a frame equals its round trip
  through a column table.
- `frame_equal` (contract text) keeps its definition and ignores the flag.
- Nothing in `src/` or `ext/` relied on identity. The only `IdDict`s are keyed by types.

## 3. `case_when` element type

- The result type depends only on the value and default types:
  - equal types stay as they are;
  - numbers promote;
  - a `missing` default makes the result nullable even when it never fires.
- Types with no common type are an `ArgumentError`, as in dplyr ("Can't combine"). So is an `Int`
  that `Float64` cannot hold exactly.
- Untyped inputs (`Any`, abstract types or `Union`s) keep the earlier narrowing from the data.
- `static_type(::CaseWhen)` follows the same rule.

## 4. Exact Parquet timestamp statistics

- `partition_stats` on a timestamp column decodes the column chunk's raw INT64 `Statistics`
  bytes, taken from Parquet2's `meta_orig`. The result has the exact type the column reads as.
- Only a single-file dataset qualifies. Its chunk must also match Parquet2's own `Column`: the
  number of values, the offsets and the physical type.
- Anything unexpected reports `nothing` for that bound, which fails closed (ADR-0021 rule 11).
- The deprecated `min`/`max` fields are used when `min_value`/`max_value` are absent. The spec
  defines both by signed comparison, which is the INT64 order (★).

## 5. Benchmarks and budgets

- [ADR-0022](../../adr/0022-performance-budgets.md) is Proposed.
- `benchmark/benchmarks.jl` defines the `SUITE`, using public API only.
- `benchmark/run.jl --check` checks time, allocation and memory against `benchmark/budgets.toml`.
- `benchmark/ttfx.jl --check` checks load, first call and precompile.
- The multipliers, the one-way rule and where the checks run are ★ questions for the user.

## Testing

- Every behaviour above has a unit test, written failing first.
- A Supposition property checks that `isequal` implies equal `hash`, and that a frame equals its
  round trip.
- The dplyr checks run through `Rscript` and their snippets sit next to the tests.
- The Polars/DuckDB differential runs under `:differential`.
- The pyarrow fixtures used for the Parquet tests come with their generating command in
  `test/io/data/README.md`.
