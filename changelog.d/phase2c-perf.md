- **Added:**
  - Benchmarks (ADR-0022, Proposed): `benchmark/benchmarks.jl` (47 entries: the core eager verbs
    at 10, 10^4 and 10^6 rows, grouped summarise and windows, CSV and Arrow IPC I/O),
    `benchmark/run.jl [--check]` (time, allocation and memory budgets per Julia version in
    `benchmark/budgets.toml`), `benchmark/ttfx.jl [--check] [--no-workload]` (load, first call and
    precompile in fresh processes).
  - `docs/src/performance.md`: ratios against DataFrames.jl 1.8.2, Polars 2.0.0 and DuckDB 1.5.6,
    losses (3.4–43× slower than DataFrames.jl on large frames) as well as wins.
  - `Frame` content equality: `isequal`, three-valued `==` and a consistent `hash` (names in order,
    row count, grouping columns, drop flag, elementwise column values). `frame_equal` on frames
    holding nested frames (from `nest`) now compares them by content.
  - Differential tests against Polars 2.0.0 and DuckDB 1.5.6 (`:differential`, `:polars_duckdb`;
    Python through `uv`), with every divergence documented in
    `docs/research/differentials-polars-duckdb.md`.

- **Changed:**
  - Parquet: timestamp columns report exact row-group statistics (`partition_stats`), decoded from
    the raw INT64 statistics bytes into the type the column reads as (`DateTime` or
    `ArrowTimestamp{U,TZ}`), instead of none. Anything unexpected reports `nothing` for that bound,
    never a wrong one (ADR-0021 rule 11). Contradictory bounds (min > max) are dropped too.
  - **Breaking:** `case_when`'s element type comes from the value and default types, not from
    which branches fire (a `missing` default makes it nullable always). Numbers promote; naive
    timestamps of any units and `DateTime` promote exactly (ADR-0021 rule 7). Values with no
    common type, or a value the common type cannot hold exactly, are now an `ArgumentError`
    (dplyr: "Can't combine"); mixes that used to give mixed or narrowed values (`Char`/`String`,
    `Rational`/`Float64`, `Date`/`DateTime`, a `nothing` default) now raise. Unlike dplyr, `Date`
    and `DateTime` are not combined.

- **Fixed:**
  - `group_by(drop = false)` survives row verbs: the flag is stored on `Frame`, and `filter`,
    `filter_out`, `arrange`, the slices and `distinct` keep every existing group (empty ones too),
    as dplyr 1.2.0 does; `head` and `pivot_longer(values_drop_na = true)` regroup (only empty
    dictionary levels stay), as dplyr's `head` and tidyr do. `mutate`, `select`, `rename`,
    `relocate`, a partial `ungroup`, `count_by`/`tally`/`add_count` and a group-keeping
    `summarise` carry the flag. `ungroup()` and a new `group_by` reset it (dplyr inherits it in
    `group_by`: documented).
