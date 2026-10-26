# Lazy queries

A lazy query records verbs instead of running them, optimizes the plan, and runs it over
partitions ("morsels"). For every deterministic, pure pipeline `p`, `collect(p(lazy(t)))` agrees
with `p(t)`: the same values, row order and grouping, and, when one path throws, an exception of
the same type (CF-008). Element types may differ by promotion.

```julia
using ChuiFrames, Statistics

t = (g = ["a", "b", "a", "c"], x = [1.0, NaN, 4.0, missing], y = [1, 2, 3, 4])
q = lazy(t) |> filter(c.x .> 2.0) |> mutate(z = c.y .* 2) |> group_by(:g) |>
    summarise(n = n_rows(), m = mean(c.z))
collect(q)                      # a Frame
collect(q; morsel = 2)          # partitions of 2 rows (tests use 1-7)
explain(q)                      # the plans, the rules that fired, pruning, the rendered kernel
code_lowered(q)                 # the rendered kernel, lowered with Meta.lower
```

Entry points:
- `lazy(t)`: a `Frame`, any Tables.jl table, or a `ChuiFrames.Source`. A grouped frame stays
  grouped.
- A verb applied to a `Source` starts a lazy query, so
  `ChuiFrames.scan_file("data.parquet") |> filter(c.x .> 1) |> collect` offers the filter and
  the columns used to the source, and prunes row groups by their statistics.
  `collect(source)` reads a whole source.
- `optimize(q)` returns the optimized query.

## What the optimizer does

Rule passes run in order, each to a fixpoint, and every rule that fires is listed by
`explain`:

1. **Constant folding** of calls on literals.
2. **Filter splitting** of `filter(a .& b)` and `filter(a, b)` into one filter per condition.
3. **Predicate pushdown** below `select`, `rename`, `rename_with` and `relocate`, and into the
   source. The source receives the conditions `Tables.Scan` can express exactly (comparisons
   with a literal, `ismissing.`, `.!`, `.&`, `.|`). The engine re-applies every pushed
   condition, so a source that ignores one cannot change the result.
4. **Projection pushdown**: the source reads only the columns the query uses.
5. **Limit pushdown**: `head(n)` right after the scan becomes a per-partition limit.
6. **Partition pruning** from `partition_stats`. A partition is skipped only when its statistics
   prove no row can match. A condition that can be true on NaN (`.!=`, a negation, `isnan.`)
   needs a known NaN count of zero; one true on `missing` needs a known null count of zero.

**Which filters move.** A rewrite that skips evaluating a step on some rows (moving a filter
below it, pruning a partition, stopping a scan early at a `head`) happens only when that step
cannot throw. Comparisons of a typed column with a literal, `isnan.`, `ismissing.` and their
`.!`, `.&`, `.|` qualify; a `mutate`, a filter with any other call, and an abstract-typed
condition do not, and nothing moves past them. So a query that throws eagerly also throws
lazily.

## How it runs

The longest prefix of per-row verbs (ungrouped `filter`, `filter_out`, `select`, `rename`,
`relocate`, and `mutate` with elementwise expressions) runs per partition. With more than one
thread, partitions run in parallel over contiguous ranges, and results are gathered in partition
order. A `head(n)` after that prefix runs in partition order and stops reading once it has `n`
rows, when every step before it qualifies as above. Everything else (grouped verbs, windows,
sorts, reshaping) runs on the gathered frame with the same operators as eager mode.

If a lazy run throws, the query is run again eagerly without the optimizer, and that exception
is the one raised. Lazy and eager can otherwise raise different exceptions when two steps fail
on different rows, because a partition runs every step before the next partition starts.

## Joins

The join verbs (`inner_join`, `left_join`, `right_join`, `full_join`, `semi_join`,
`anti_join`, `nest_join`, `cross_join`) work on lazy queries too, and `y` may itself be lazy:

```julia
orders = lazy(ChuiFrames.scan_file("orders.parquet"))
q = orders |> filter(c.amount .> 10) |>
    left_join(lazy(customers) |> select(:id, :country); by = :customer => :id) |>
    filter(c.country .== "KE")
explain(q)          # the plan is a tree: the join's x: and y: subplans
collect(q)          # the same rows, order and types as the eager pipeline
```

- **Names are fixed when the join is applied.** The key pairs and the output names (suffixes
  included) are resolved from both sides' schemas when the join is added to the query, so the
  natural-join message `@info "Joining with by = [...]"` is logged then, once. When a side's
  schema cannot be known without running it, the names are resolved, and the message logged,
  when the query is collected.
- **Filters move through joins only when that cannot change the result.** A filter above a
  join that reads columns of one side moves to that side when the join cannot raise
  (`unmatched = :drop`, `multiple != :error`): to x for inner, left, semi, anti and nest joins,
  to y for inner and right joins only under `multiple = :all` (filtering y first would change
  which match `:first`/`:last` picks), never for full joins. A condition on the merged key
  moves to x only when x's key needs no conversion to the compare type. Each side reads only the
  columns the query needs, plus its keys and every column whose name clashes.
- **How it runs.** At `collect` the cost stage picks the build side (the side with fewer
  estimated bytes) and the strategy: a broadcast join (one shared hash table) when the build
  side is small, otherwise both sides are radix-partitioned. When y is the build side, x streams
  through the probe morsel by morsel and the result is already in order; otherwise a final step
  restores dplyr's row order (x order, then y order) with a stable counting sort. `explain`
  names the strategy, the build side with its estimated size, which side streams, and whether
  the sort runs; its decision is a prediction from estimates, confirmed at `collect` on the
  collected build side.
- **Key types.** A side whose key types are not known from the schema (for example a key made
  by `mutate`) is collected before the join runs, and its column types decide the compare type.
  Integer keys joined with float keys are compared as `Float64`: integers above 2^53 in
  magnitude can then match the same float key (convert the key first if that matters).
- If the lazy run raises, `collect` reruns the query eagerly and raises eager's exception, as
  for every lazy query.

## Not yet

Hash-aggregate and grouped-window sinks with parallel partial aggregation, compiled kernels
(phase 4), and asynchronous I/O (phase 5). Inequality and rolling joins (`join_by(a >= b)`,
`closest`, `between`, `within`, `overlaps`) have no design yet. `code_lowered` shows a kernel rendered from
the plan for reading; the engine runs the interpreter.
