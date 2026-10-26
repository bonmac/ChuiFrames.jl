- **Added:**
  - Joins (phase 4; spec docs/superpowers/specs/2026-10-26-phase4-joins-groupby-codegen-design.md
    §1, dplyr 1.2.0 semantics): `inner_join`, `left_join`, `right_join`, `full_join`,
    `semi_join`, `anti_join`, `nest_join` (a column of `Frame`s, as `nest` builds) and
    `cross_join`, with the `by =` keyword (`nothing` for a natural join with an `@info`, `:a`,
    `"a"`, `[:a, :b]`, `:a => :b`, vectors of those) and `join_by(:a => :b, :c)` (equality pairs
    only). Options `suffix` (default `("_x", "_y")`), `na_matches`, `keep`, `multiple`,
    `unmatched` and, for `nest_join`, `name`.
  - DataAPI's `innerjoin`, `leftjoin`, `rightjoin`, `outerjoin`, `semijoin`, `antijoin` and
    `crossjoin` on a `Frame` (ADR-0007); DataAPI's keyword `on` is forwarded to `by`.
  - The hash join (ADR-0003 rules 4, 8, 10, 11): a cost stage (`join_decision`) picks the build
    side by estimated bytes; broadcast joins below the limits, otherwise both sides
    radix-partitioned; dplyr's row order restored by a stable counting sort. Integer/float key
    pairs are compared as `Float64` (precision above 2^53 documented); `Date`/`DateTime`,
    `Int64`/`UInt64` and string/number keys are rejected.
  - Lazy joins: a `JoinNode` makes the plan a tree. Names are resolved once when the node is
    built; filters move through total joins (never through `multiple = :error`,
    `unmatched = :error`, or to y unless `multiple = :all`); each side is projected separately;
    joins lower to their physical shape at `collect`; `explain` draws the tree and names the
    strategy, the build side, the streamed side and the sort.
