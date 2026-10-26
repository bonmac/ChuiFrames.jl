- **Fixed:**
  - Four concatenations no longer copy their growing result once per piece, which made them
    quadratic (docs/research/performance-phase4.md P4-02). They are the lazy gather's
    `vcat_columns` (values, dictionary codes and validity of many morsels), the partitioned
    join's per-partition pairs, `bind_rows(...; id)`'s id column and `reframe`'s key rows. Their
    allocations are now linear in the output (test/lazy/alloc_gather_tests.jl and
    test/engine/alloc_concat_tests.jl bound them by bytes). Outputs are unchanged.
  - Slicing a string or binary column (`take`) no longer allocates once per row. Every lazy scan
    of a frame with string columns slices it this way, so the lazy String-key group-by no longer
    allocates per row: `groupby/String few, lazy/n=10^6` went from 1,003,338 to 3,280 allocations
    (`bench-113-6396ca3.txt`, archived under `.lanes/reports/lanes/p4-perf/evidence/`). Outputs
    are unchanged.

- **Changed:**
  - Allocation and memory budgets of rows that fell below half their baseline are tightened
    (ADR-0022 rule 5), on 1.13 and 1.10 (43 rows). They cover the partitioned joins, the
    partitioned lazy joins, the lazy joins behind a `mutate`, `nest_join` (1.13), the lazy
    gathers, the String and Int-plus-String lazy group-by, `filter` and `summarise/String many`.
    No time budget changed.
