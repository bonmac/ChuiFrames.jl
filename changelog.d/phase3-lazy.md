### Changed
- **Breaking:** `var` and `std` of fewer than two values (with `corrected = false`: of no values)
  return `missing`, as dplyr's NA and the null of Polars and DuckDB, instead of
  `Statistics.var`'s NaN. Their result type is now always nullable (`Union{Missing, Float64}`).
  User decision at the phase-2c ★ (ADR-0002 rule 10 note, 2026-10-20).
