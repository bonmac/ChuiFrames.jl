- **Added:**
  - Benchmarks for phase 4 (spec §5, ADR-0022 rules 1 and 3): the eager group-by on dictionary
    and two-column keys, the lazy hash-aggregate sink on Int, String, dictionary and two-column
    keys (10 and n ÷ 10 groups), `group_by` alone on 10 rows, inner and left joins (1:1 and 1:n)
    under each forced strategy and build side, a small-x/large-y join, a join behind a non-key
    `mutate` and the same join with the `mutate` after it, the lazy join in each shape, `nest_join`,
    `cross_join`, an `n=10` row per join verb, a compiled streamed stage at 10⁶ rows with its
    interpreted twin, the phase-3 pipeline forced through the interpreter (ADR-0025's gauge) and
    a `drop = false` group-by over statistics-pruned partitions (ADR-0024's trigger), each with
    budget rows for Julia 1.13 and 1.10.
  - `benchmark/compare/`: db-benchmark-like group-by q1–q5 and join q1–q3 (plus small x / large
    y) on ChuiFrames, the previous `main`, DataFrames.jl, Polars and DuckDB
    (docs/research/performance-phase4.md).

- **Changed:**
  - The hash-aggregate sink's radix switch `RADIX_SWITCH` is 2²⁰ groups per task table (was 2¹⁶):
    between 10⁵ and 5·10⁵ groups the 2¹⁶ limit allocated 1.2–4.6× the memory of 2²⁰ and ran up
    to 2.9× slower on a loaded machine (docs/research/performance-phase4.md P4-03).
  - Allocation budgets of rows whose allocations fell by more than half since their baseline are
    tightened (ADR-0022 rule 5): grouped `summarise`, `count_by` and the lazy pipeline.
