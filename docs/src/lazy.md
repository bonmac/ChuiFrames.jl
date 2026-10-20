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

## Not yet

Hash-aggregate and grouped-window sinks with parallel partial aggregation, joins, compiled
kernels (phase 4), and asynchronous I/O (phase 5). `code_lowered` shows a kernel rendered from
the plan for reading; the engine runs the interpreter.
