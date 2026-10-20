# Phase 3 design: the lazy engine (plans, optimizer, pushdown and pruning, `explain`, morsels)

- **Date:** 2026-10-20. **Branch:** `feat/phase3-lazy`. **Plan:**
  [2026-10-20-phase3-lazy.md](../plans/2026-10-20-phase3-lazy.md).
- **Tier:** T2 (new public API: `lazy`, `collect`, `explain`, `code_lowered`, `optimize`;
  `scan_file` now returns a lazy query).
- **Binding decisions:** ADR-0003 (engine), ADR-0004 (sources, sinks, pushdown, statistics),
  ADR-0021 (timestamps), ADR-0022 (budgets), CF-007, CF-008, CF-011 to CF-013, CF-016.

## 1. The guiding rule: lazy == eager, exceptions included

CF-008 promises equal results **and the same exception type** on both paths. Every rewrite below
is constrained by one derived rule:

> **R-total.** A rewrite may stop the engine from evaluating some step on some rows (by moving a
> filter below it, pruning a partition, pushing a filter into a source, or stopping a scan early)
> only when every step it skips over is **total**: it cannot throw on any row.

Total steps: `select`/`rename`/`relocate` whose selections resolve on the input schema (they
never evaluate data), and filters whose every conjunct is a **total predicate** (§4). A `mutate`,
a non-total filter, or any other step is a **barrier**. This generalises ADR-0003 rule 4's
barrier (abstract-typed predicates) to every predicate that might throw; ADR-0003 rule 6's
"must not stop early below an abstract-typed filter" follows from it.

**Exception replay.** Evaluation order differs between the paths (a fused stage runs every step
on morsel 1 before morsel 2; eager runs step 1 on every row first), so two failing steps can
raise different exception types. When the lazy path throws, the executor first finds the
original exception of the first failing morsel in morsel order (ADR-0003 rule 7: it unwraps
`TaskFailedException`/`CompositeException`), then **replays the unoptimized plan eagerly** (read
the source, apply the steps). If the replay throws, its exception propagates; that is the eager
exception by construction. If it does not, the lazy failure was an engine defect and the
replay's result is returned (review pass 1, M1: planning runs inside the guard too). Pure pipelines only
(CF-008), so replay changes no result; it costs a second run only on failure. (★: an ADR-0003
note.)

## 2. API (CF-007, CF-008, CF-016)

- `lazy(t)` → `LazyFrame`. `t` is a `Frame`, any Tables.jl table, or a `Source`. A frame (or a
  table, converted once with `Frame(t)`) becomes a `FrameSource`: row-range partitions of
  `morsel` rows over the frame's own columns, so partitions have the eager input's exact column
  types. Grouping columns and the drop flag of a grouped frame are kept and re-applied after the
  scan.
- A `Step` or `Pipeline` applied to a `LazyFrame` appends to its plan (CF-007): `s(q)` and
  `q |> s` return a new `LazyFrame`; nothing runs.
- `collect(q; morsel = 65_536, threads = true)` → `Frame`. `optimize(q)` → the optimized
  `LazyFrame`. `explain([io,] q)` prints. `code_lowered([io,] q)` prints the rendered kernels.
- `scan_file(path)` keeps returning the format's `Source` (format registrations return sources,
  CF-016). A verb applied to a `Source` starts a lazy query over it, and `collect(source)` reads
  it through the engine, so CF-016's `collect(scan_file("t.arrow"))` works. `read_file` keeps
  reading eagerly. A `LazyFrame` is not a Tables.jl table; collect first (CF-001 covers "the
  result of collecting").

## 3. Plan IR (ADR-0003 rules 1, 4; ChuiCore R6 mirrored)

- Nodes: `ScanNode(source, pushed::Tables.Scan, groups, drop, notes)` and
  `StepNode(step::Step, child::Any)`. One child field, **`Any`-typed** (ChuiCore R6: parametric
  fields recompile per tree shape). Joins and set operations add two-child nodes in phase 4;
  `bind_rows`/set verbs holding a second table stay a `StepNode` (their second table is eager).
- The upstream adapter gains the R6 stand-ins: `fmap(f, node)` for plan nodes, `project`,
  `cata`, `para`, `ana` with ChuiCore main's semantics (`para`'s holes are `(original, result)`).
  The optimizer's passes are written with them. They move to ChuiCore at its release
  (ADR-0014 rule 3).
- Plans are immutable values; `LazyFrame` holds the root.

## 4. Predicates: totality, Scan translation, pruning (ADR-0004 rules 1, 3, 4; CF-012, CF-013)

A filter's predicates are split into conjuncts on `&` (dotted `.&` builds `Call(&, …)`) and on
the filter's own argument list.

- **Total predicate** (`istotal(p, schema)`): a dotted comparison `==, !=, <, <=, >, >=`
  between a `Col` whose non-missing element type is concrete and in
  {`Integer`, `AbstractFloat`, `AbstractString`, `Date`, `DateTime`, `ArrowTimestamp`, `Bool`}
  and a scalar `Lit` the comparison accepts without throwing (checked at plan time by comparing
  the literal with `zero`/a sample of that type in a `try`); `isnan.(col)` (float columns),
  `ismissing.(col)`, `.!p`, `p .& q`, `p .| q` over total `p`, `q`. Everything else is not
  total (it might throw, or its type is abstract: the ADR-0003 barrier).
- **Scan translation** (`to_scan`): only node kinds whose `Tables.Scan` semantics equal
  ChuiFrames' for every value, NaN and `missing` included: `colcmp` for the six comparisons
  (IEEE, as `r2_scan.jl` showed), `isnull` for `ismissing.`, `!`, `&`, `|`. Never `colin` with a
  NaN member (not produced at all in v0: `in.` is not total). A differential test per node kind
  checks `Tables.scan` against `filter` on data with NaN, ±0.0 and `missing`; a kind without it
  is not pushed.
- **Pruning** (`may_match(p, stats) :: Bool`; a partition is pruned when it is `false`): from
  `(; lo, hi, nnull, nnan)` per column. Unknown statistics, a NaN or `missing` bound, or a
  comparison that throws → `true` (keep). A predicate that can be true on NaN (`!=`, any `!`,
  `isnan.`) needs `nnan == 0` known before its NaN-free range test may prune; one that can be true
  on `missing` (`ismissing.`, `|` with one) needs `nnull == 0`. `&` prunes when either side does;
  `|` when both do; `!` is handled by pushing the negation into the comparison (De Morgan, with
  the NaN condition above). Unclassified → `true`.
- Timestamp statistics (phase 2c, ADR-0021 rule 11) compare against `DateTime` or same-unit
  `ArrowTimestamp` literals only; any other mix throws in the comparison → keep.

## 5. The optimizer (ADR-0003 rule 4)

Ordered passes, each to a fixpoint (at most 100 iterations; on hitting the cap the pass keeps
its last plan and logs `fixpoint cap hit` for `explain`; a property test asserts it never
happens). Every rule that fires is logged.

1. **Constant folding:** a `Call` whose arguments are all scalar `Lit`s becomes a `Lit` (pure
   functions, CF-008). A call that throws at plan time is left alone (eager would throw on it
   too, and must, at the same point).
2. **Filter splitting:** a `filter(a, b)` or `filter(a .& b)` whose conjuncts are **all** total
   becomes one filter per conjunct. A non-total filter is never split (R-total; ADR-0003 rule 4).
3. **Predicate pushdown:** a total filter moves below a `select`/`rename`/`relocate` when every
   column it reads exists, under its old name, below (names are rewritten through `rename`;
   regression 8: a filter never moves below a `select` that drops its column); below another
   total filter (for ordering only: it changes no result); and into the `ScanNode` as pushed
   conjuncts when the conjunct translates (§4). Untranslatable total conjuncts still prune.
   `filter_out` is never pushed (its three-valued complement is not a `Scan` predicate in v0).
4. **Projection pushdown:** the columns the plan reads (a backward pass with per-step `reads`;
   any step it cannot analyse reads every column) become the scan's `select`. Only **source**
   columns are pruned: no computation is removed (dead-column elimination of computed columns
   would skip work eager does, which could throw).
5. **Limit pushdown:** `head(n)` (n ≥ 0) directly above the scan, with every pushed conjunct
   applied by the source and no engine filter left below it, becomes the scan's `limit` (a
   per-partition limit; the global `head` stays, ADR-0004 rule 3). Independently, the executor
   **stops the scan early** once a `head(n)` has its rows, when every step between the scan and
   the `head` is total (R-total).
6. **Partition pruning** runs at execution time on the pushed and untranslatable total
   conjuncts directly above the scan, per partition, from `partition_stats`, and counts kept and
   pruned partitions for `explain`.

The cost stage (join order and strategies) has nothing to choose until phase 4's joins.

## 6. Physical plan and execution (ADR-0003 rules 2, 5, 6, 7)

- A physical plan is: the scan (pushed `Scan`, residual), a **streamed stage** (the longest
  prefix of steps above the scan that are per-row: ungrouped `filter`/`filter_out`, `select`,
  `rename`, `relocate`, and ungrouped `mutate`/`select` whose outputs are **elementwise**
  expressions: `Col`, scalar `Lit`, `Call` of elementwise arguments, `CaseWhen` of them; no
  `Reduce`, `Window`, `Pipe`, `NRows`, vector `Lit`, `if_any`/`if_all`, `across`, or `by`/`keep`
  options), an optional **limit** (`head`) applied in morsel order, a **materialize sink**
  (concatenate in morsel order), then the **rest** of the steps applied to the materialized frame
  through the same eager operators (grouped summaries, windows, sorts, reshaping). Phase 4
  replaces parts of the rest with hash-aggregate sinks and codegen.
- **Morsels:** the source's partitions. `FrameSource` makes `morsel`-row partitions; tests set
  `morsel` to 1–7.
- **Parallelism (ADR-0003 rule 6, ChuiCore ADR-0003 rule 4, contract ADR-0012 P2):** the streamed
  stage is lowered to a transducer (`Map` of the stage over partitions); only when
  `isstateless(xf)` is `true` does it run per partition on `Threads.@spawn` tasks, each with a
  **contiguous range** of morsels, results in a concretely typed `Vector{Frame}` indexed by morsel.
  A stage with a `head` runs sequentially through `foldxl` with `Take`, never through an
  accumulator-dependent `Reduced` under a parallel fold (ChuiCore S1). Reads of a source with
  `isthreadsafe(s) == false` go through the source lock (ADR-0004 rule 10).
- **Exceptions:** as §1. A failure in range *k* cancels only the ranges after *k* (a shared
  atomic "first failed range" checked between morsels).
- **Partition types:** a streamed stage evaluates static types per partition. When partitions'
  column element types disagree (possible for file sources, never for `FrameSource`), the
  executor materializes the scan first and re-partitions it as a `FrameSource`, so the stage sees
  the eager concatenation's types.
- **Eager fast path (rule 2):** unchanged: eager verbs on frames never build a plan.

## 7. `explain` and `code_lowered` (ADR-0003 rule 13)

`explain(q)` prints, in order: `logical plan`, `optimized plan`, `rules fired` (or `none`),
`physical plan` (pipelines, the streamed stage, parallel or sequential and why, the morsel
size), `pruning` (partitions kept / pruned, or `not run` before `collect`), and
`rendered kernel`. `code_lowered(q)` prints the `CodeInfo` of the rendered kernel: a Julia
function expression `(cols) -> (cols′, mask)` generated from the streamed stage and lowered with
`Meta.lower`. A property test evaluates the rendered expression (test process only) and checks
it against the interpreter on generated stages. The output is snapshot-tested on stable Julia.

## 8. Testing

- Unit tests per rule (fires, does not fire, the barrier cases, regressions 7 and 8 lazy
  halves, R-total cases where eager throws).
- **lazy == eager** (CF-008) property tests: the existing generator (`test/engine/property_tests.jl`)
  plus streamed-stage steps (`select`, `rename`, `head`, `filter_out`, elementwise `mutate`),
  random morsel sizes 1–7, run at `-t 1` and `-t 4`; result agreement and exception types.
  Every property and parallel wait has a hard time bound and fails loudly.
- Pruning: generated float partitions with NaN, `missing` and negated / `.!=` predicates
  (ADR-0003 Testing); the CF-013 example cases through `lazy`.
- Scan translation differential per node kind (§4).
- Snapshot tests of `explain`/`code_lowered` (`:snapshot`).

## 9. Not in this milestone (reported as remaining)

Hash-aggregate and grouped-window sinks with parallel partial aggregation (`foldparts`), the
adaptive group-by, radix partitioning, joins, codegen kernels and the 10⁵ interpreter threshold
(phase 4); async I/O and cancellation (phase 5). Ordering declarations (`source_ordering`)
are not used to skip sorts yet.
