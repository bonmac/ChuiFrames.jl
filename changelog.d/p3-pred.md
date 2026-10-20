### Added
- Internal filter-predicate analysis for the lazy optimizer (spec 2026-10-20 phase 3 §4;
  ADR-0004 rules 1, 4; CF-013): `conjuncts`, `istotal` (predicates that cannot throw on any row),
  `to_scan` (translation to `Tables.Scan` for comparisons, `ismissing.`, `.!`, `.&`, `.|`, checked
  by a differential test against `filter` on NaN, -NaN, ±0.0, ±Inf and `missing`) and
  `may_match` (statistics pruning that keeps a partition unless no row can match, with the NaN
  and `missing` safety conditions; a Supposition property checks soundness).
