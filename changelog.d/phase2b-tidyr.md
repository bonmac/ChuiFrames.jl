- **Added:**
  - Phase 2b (plan: `docs/superpowers/plans/2026-10-20-phase2b-tidyr.md`).
  - `ArrowTimestamp{U,TZ}` (exported; ADR-0021, Proposed): Arrow timestamps in s/ms/µs/ns, naive or
    zoned, that `DateTime` cannot hold.
    - Equality, hashing and order are by exact instant across units. Zoned values compare by UTC
      instant.
    - Comparing a naive with a zoned value is an `ArgumentError`; `isequal` returns `false`.
    - `DateTime(t)` floors; other conversions and fixed-period arithmetic are exact or raise.
    - Printed as ISO 8601 with the unit's digits (`Z` when zoned); headers show `dttm[us, UTC]`.
  - Arrow IPC reads every Timestamp unit and zone (Polars', R arrow's and DuckDB's µs defaults
    included) and writes them back unchanged.
  - CSV reads timestamps with sub-millisecond digits exactly, writes ISO text, and parses
    `col_types = (t = ArrowTimestamp{U,TZ},)` itself.
  - Parquet reads µs/ns timestamps exactly. Zone names come from pyarrow's `ARROW:schema`, else
    `:UTC` for UTC-adjusted columns.
  - tidyr reshaping as eager verbs, differential-tested against tidyr 1.3.1:
    - `pivot_longer` and `pivot_wider`;
    - `separate_wider_delim`/`_position`/`_regex`, `separate_longer_delim`/`_position` and
      `unite`;
    - `nest`, `unnest`, `unnest_longer`, `unnest_wider`, `pack` and `unpack`;
    - `fill` (a method of `Base.fill` on columns), `expand`, `nesting` and `complete`.
  - The dplyr ranking tail, differential-tested against dplyr 1.2.0:
    - `percent_rank`, `cume_dist` and `ntile`;
    - `when_any` and `when_all`;
    - `slice_sample(weight_by = …)`;
    - `group_by(drop = false)`, which keeps empty levels of dictionary-encoded keys;
    - `arrange(locale = "C")`; other locales raise, since there is no ICU.
  - `c.x |> typed(T, f)` declares the result type of a whole-column function (ADR-0002 rule 11),
    so a filter on such a predicate is planned with a known type. The result is checked against
    `T`, never converted.

- **Changed:**
  - CSV timestamps with sub-millisecond digits no longer raise; they read as `ArrowTimestamp`.
  - `read_csv(...; col_types = "T")` (or a `DateTime` type) parses ISO text exactly. Digits finer
    than a millisecond raise an `ArgumentError` naming `ArrowTimestamp{Nanosecond}`; before, they
    became `missing` with only a warning.
  - `group_by(drop = false)` no longer raises.
  - `rowcodes` with zero key columns gives one code per row (an internal fix found by the nest lane).

- **Fixed:**
  - Parquet timestamps were off by 1 ms for about 1 value in 170 on read and 1 in 110 on write.
    Parquet2's decoding goes through Float64. ChuiFrames now reads the raw Int64 counts and writes
    exact millisecond counts. Timestamp columns report no Parquet statistics, because Parquet2
    decodes their bounds the same lossy way.
