### Fixed
- Four concatenations no longer copy their growing result once per piece, which made them
  quadratic (docs/research/performance-phase4.md P4-02). They are the lazy gather's
  `vcat_columns` (values, dictionary codes and validity of many morsels), the partitioned
  join's per-partition pairs, `bind_rows(...; id)`'s id column and `reframe`'s key rows. Their
  allocations are now linear in the output; for example, a lazy gather of 1,000 morsels
  allocated about 550× its payload and now allocates about 9×. Outputs are unchanged.
- Slicing a string or binary column (`take`) no longer allocates once per row. Every lazy scan
  of a frame with string columns slices it this way, so the lazy String-key group-by now
  allocates about 0.01 times per row instead of once (P4-05). Outputs are unchanged.

### Changed
- Allocation and memory budgets of rows that fell below half their baseline are tightened
  (ADR-0022 rule 5), on 1.13 and 1.10 (43 rows). They cover the partitioned joins, the
  partitioned lazy joins, the lazy joins behind a `mutate`, `nest_join` (1.13), the lazy
  gathers, the String and Int-plus-String lazy group-by, `filter` and `summarise/String many`.
  No time budget changed.
