### Added
- The lazy hash-aggregate sink (phase-4 spec §2.1, §2.3): `group_by(keys...) ⨟ summarise(...)`
  and `summarise(...; by)` with simple aggregates (`sum`, `prod`, `mean`, `minimum`, `maximum`,
  `extrema`, `count`, `length`, `any`, `all`, `first`, `last`, `reduce`, `mapreduce`, `sum(f, x)`,
  `var`, `std`, their `skipmissing` forms, `n_rows()`) over plain key columns fold the streamed
  stage's morsels per task (typed keys, typed accumulators) instead of gathering them. Dictionary
  keys are remapped through one global value-keyed dictionary (partitions may carry their own
  dictionaries); a task's table that passes `RADIX_SWITCH` groups flushes into radix partitions
  (adaptive switch); partitions merge in morsel order, so `first`, `last` and `reduce` see row
  order. Rows are sorted by the keys as eager sorts them, `drop = false` keeps the empty levels,
  and results equal eager (floats within CF-008's `rtol = 1e-12`), element types included.
- The grouped-window sink: a grouped `mutate` (after `group_by`, or with `by`) after the gather
  runs over contiguous group ranges in parallel when threads > 1, scattered back in row order.
- `explain` names the hash-aggregate sink, or says why a summary is not one (e.g. "not a simple
  aggregate: `median`", "a computed group key"), and notes grouped-window sinks.
- Lazy == eager property tests for the grouped sinks (permuted per-partition dictionaries,
  `drop = false` dictionary keys, the radix switch forced at 4 groups, `-t 1` and `-t 4`).

### Changed
- Eager `group_by` builds its group index through the typed keys and one open-addressing table
  (no `Dict` per row): same index, about 10× faster at 10^4–10^6 rows, and faster at 10 rows.
  Grouped `summarise` still makes the same per-group Base calls, so its results are bitwise equal.
- Join key pairs (internal, for the phase-4 joins): an integer (or `Bool`) key paired with a float
  key is now allowed and compared as `Float64`, as dplyr does (the user's ★ K4 answer,
  2026-10-26). New internal `_keypair_compare_type(Sx, Sy)` gives the type both sides are
  converted to; above 2^53 two different integer keys can match the same `Float64` key.

### Fixed
- A lazy query on a source whose partitions carry different dictionaries gathered a lone
  non-empty partition's dictionary column as is, so `group_by(drop = false)` showed levels the
  eager read (which decodes) does not. The gather now follows the eager read's column kind.
