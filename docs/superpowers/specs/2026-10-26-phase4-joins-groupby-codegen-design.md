# Phase 4 design: joins, the fast group-by with aggregate sinks, and codegen kernels

- **Date:** 2026-10-26. **Branch:** `feat/phase4` (integration), sub-lanes `feat/p4-groupby`,
  `feat/p4-join`, `feat/p4-codegen`, `feat/p4-bench`. **Plan:**
  [2026-10-26-phase4.md](../plans/2026-10-26-phase4.md).
- **Tier:** T2 (new public verbs: `inner_join`, `left_join`, `right_join`, `full_join`,
  `semi_join`, `anti_join`; new plan node; new `explain` sections).
- **Binding decisions:** ADR-0003 rules 3, 5–12 (engine), ADR-0004 (sources), ADR-0014
  (upstream stand-ins), ADR-0022 (budgets), CF-008 (lazy == eager, approximate frame equality
  for reductions), the phase-3 spec §1 R-total rule. New ADRs: 0023 (joins), 0024 (group-by and
  aggregate sinks), 0025 (codegen kernels and the interpreter threshold).

## 0. Seam (before the lanes)

Three lanes run in parallel with disjoint file scopes. To keep them disjoint, one seam commit
on `feat/phase4` (the lead's, reviewed with the phase) adds, with no behaviour change:

- empty files included from `src/engine/engine.jl` / `src/lazy/lazy.jl`:
  `src/engine/radix.jl`, `src/engine/hashagg.jl` (group-by lane), `src/engine/join.jl`,
  `src/engine/verbs_join.jl` (join lane), `src/lazy/sinks.jl` (group-by lane),
  `src/lazy/joins.jl` (join lane), `src/lazy/kernels.jl` (codegen lane);
- in `src/lazy/execute.jl`: `execute` asks `stage_kernel(ph, est_rows)` (defined in
  `kernels.jl`; the seam's version returns the phase-3 interpreter loop) once per run, and every
  morsel runs through the returned callable;
- in `execute`'s tail: the `rest` steps run through `run_rest(ph, out; morsel, threads)`
  (defined in `sinks.jl`; the seam's version is the phase-3 `apply` loop).

Each lane's exports live in its own file (`export` inside the module, any file).

## 1. Joins (ADR-0023; DESIGN §7 item 1; parity rows `inner_join` … `anti_join`)

### 1.1 API (dplyr 1.2.0 semantics)

```julia
inner_join(y; by = nothing, suffix = ("_x", "_y"), na_matches = :na, keep = false,
           multiple = :all, unmatched = :drop)
left_join, right_join, full_join      # same keywords
semi_join(y; by = nothing, na_matches = :na)
anti_join(y; by = nothing, na_matches = :na)
```

- Each returns a `JoinStep <: Step` holding `y` (any Tables.jl table, converted once with
  `Frame(y)`, or a `LazyFrame`/`Source`). `x |> inner_join(y; by)` and `inner_join(y; by)(x)`
  (CF-007). An eager `x` with a lazy `y` collects `y` first (eager meaning).
- **`by`** (dplyr's `by`; the parity matrix's sketch `on =` is replaced, the verb set is
  PROVISIONAL in the contract): `nothing` = natural join on the common column names, with a
  `@info "Joining with by = [...]"` message like dplyr's (a `with_logger`-silenceable log);
  `:a`; `"a"`; `[:a, :b]`; `:a => :b` (x's `a` equals y's `b`); a vector of those. No common
  column under `by = nothing` → `ArgumentError` (dplyr errors too). `cross_join`, `nest_join`,
  inequality and rolling `join_by` are out of scope (parity matrix rows stay `planned`).
- **Key equality:** ADR-0003 rule 8 (NaN one key, ±0.0 one key, `missing` its own key).
  `na_matches = :na` (default, dplyr) — `missing` matches `missing`, NaN matches NaN;
  `na_matches = :never` — a key row holding `missing` **or NaN** in any key column matches
  nothing (dplyr's `"never"` treats NaN as NA too; verified by a differential case). x rows with
  such keys are kept by left/full/anti and dropped by inner/semi, as unmatched rows.
- **Key types:** the pair of key columns must have a common promoted type for equality
  (`Int` vs `Float64` compare as numbers, `isequal(1, 1.0)`; `String` vs `Int` →
  `ArgumentError` at plan time, as dplyr's incompatible-types error). Dictionary keys from two
  frames are compared by value (codes are unified or decoded first, rule 11).
- **Output columns and order (dplyr):** x's columns in order, then y's non-key columns in order.
  Key columns appear once with x's names (`keep = false`); their values are x's values, except
  for right/full join rows that only exist in y, which take y's key values. `keep = true` keeps
  both key sets (y's keys get the suffix when the names clash). Non-key name clashes get
  `suffix`. semi/anti return x's columns only.
- **Row order (dplyr 1.2.0):** inner/left: x row order, each x row's matches in y row order.
  right: the inner rows in x order, then y rows with no match in y order. full: the left join's
  rows, then y's unmatched rows in y order. semi/anti: x rows in x order, each once.
- **`multiple`/`unmatched`:** `multiple = :all` (default), `:any`, `:first`, `:last`, `:error`
  (dplyr 1.1+; `"warning"` is skipped); `unmatched = :drop` or `:error` (an x row of an
  inner join, or y row of an inner/left join, without a match → `ArgumentError`). dplyr's default
  `relationship = NULL` many-to-many warning is not reproduced (documented difference).
- **Grouping:** a grouped x keeps its groups (dplyr keeps `x`'s grouping); the group index is
  rebuilt on the output. A grouped y is ungrouped first.
- **Element types:** columns that receive unmatched-side rows become `Union{Missing, T}`;
  others keep their types. Dictionary columns keep their dictionary when every value comes from
  one frame; a key column fed by both frames is decoded to plain values.

### 1.2 The hash join (one physical operator, eager and lazy)

- **Build side is always y**, probe side x. That gives dplyr's row order without a sort (rejected
  alternative: build the smaller side and sort the output back — a full sort on every join; the
  cost stage chooses the strategy only, ADR-0023).
- **Build:** the key columns of y become typed keys (§2.2: one concrete column, or a concrete
  `Tuple`, canonicalised; dictionary keys by value) in an open-addressing table mapping a key to
  the first y row; a `next` vector chains y rows with the same key **in y row order**.
- **Strategy (cost stage, ADR-0003 rules 4 and 11):**
  - **broadcast:** one shared build table, built by one task, when y's estimated rows (from
    `row_count` / the collected y) are < 131 072 and the estimated key bytes < 4 MiB
    (DataFusion's defaults, recalibrated in the bench lane; the threshold is a constant in
    `join.jl`, overridable by a keyword for tests);
  - **partitioned:** y's rows are radix-partitioned (§2.3) by key hash into 2ᵖ partitions
    (p = 4–8, chosen from the row count) and each partition's table is built by its own task;
    a probe row looks its key up in partition `hash >> (64 - p)`.
  - Both strategies produce identical results; a test forces each in turn (ADR-0003 Testing).
- **Probe:** per x morsel, stateless and in parallel (contiguous morsel ranges, gathered in
  morsel order): the matching y rows of each x row, as `(xrow, yrow)` index pairs (`yrow = 0`
  for an unmatched left/full row), then one `take` per column. right/full joins also mark matched
  y rows in a per-task `BitVector`, OR-merged after the probe; the unmatched y rows are appended
  in y order by the **join tail**, which runs after the gather (a pipeline breaker).
- **Eager:** `JoinStep` applied to a frame runs the same build and probe on the whole frame,
  single morsel, on the calling task below 65 536 x rows (ADR-0003 rule 2).

### 1.3 The plan becomes a tree

- `JoinNode(left, right, spec::JoinStep) <: PlanNode` with **`Any`-typed** children (R6), a
  `fmap` that maps both children, so the R6 stand-ins (`cata`, `para`) traverse trees. A `JoinStep`
  applied to a `LazyFrame` makes a `JoinNode` with `right = lazy(y).plan`; `lazy` of a `LazyFrame`
  `y` takes its plan as is.
- **Optimizer, tree-aware:** constant folding, filter splitting and the phase-3 pushdown rules
  run in each subtree. Projection pushdown runs per leaf, with the columns each side must supply
  (the join's keys plus the columns the plan above reads, mapped through suffixes).
- **Filter pushdown through a join (new rule):** a filter directly above a `JoinNode` that is
  **total** (R-total: below the join it is evaluated on rows the join would drop) and whose
  columns all come from one side moves to that side, with names mapped back through `keep` and
  suffixes:
  - inner: either side; semi/anti: the left side (their output has x's columns only; a predicate
    on x columns commutes with the semi/anti filter);
  - left: the left side only; right: the right side only; full: never.
  - a predicate on a key column under `keep = false` is pushed to x for inner/left/semi/anti
    (the output key is x's key); for inner joins it is also pushed to y when the join compares
    keys with `isequal` on the same type (a copy on each side), never under `na_matches = :never`
    with a `!` or `ismissing` predicate (it could keep rows the join would drop or vice versa;
    tested).
- **Lowering for execution** (`src/lazy/joins.jl`): before `physical`, every `JoinNode` becomes
  `StepNode(ProbeStep(build, spec), left)`, where `build` is the right subplan; `collect`
  executes the right subplan (recursively, inside the CF-008 replay guard) into the build table,
  `explain` does not (it prints the subplan). `ProbeStep` is streamable for inner/left/semi/anti
  (it joins in the phase-3 streamed stage, parallel over x morsels); right/full joins split into
  a streamed probe plus the join tail in `rest`.
- **Replay (`reference`)** handles trees: a `JoinNode` replays as `apply(spec, reference(left))`
  with `y = reference(right)`.
- **`explain`** draws the logical and optimized plans as trees (box-drawing `├─`/`└─`, the
  prototype's printer style): `join(inner; by = [:a => :b])` with `x:` and `y:` children. The
  physical section names the strategy (`broadcast` / `partitioned into 2ᵖ`), the estimated build
  rows, and the build subplan. Snapshot-tested on stable Julia.

## 2. Fast adaptive group-by and the aggregate sinks (ADR-0024; DESIGN §7 item 2)

### 2.1 What runs where

- **Eager `group_by`** builds its `GroupIndex` (ADR-0003 rule 3) through the new key machinery
  (§2.2–2.3) instead of `Dict`-per-column codes plus pairwise `Dict{Tuple{Int,Int}}` codes. The
  index's meaning (ids, perm, starts, keys in ascending order, first-seen key value for ±0.0) is
  unchanged; every existing test keeps passing.
- **Eager grouped `summarise`** uses the **hash-aggregate operator** directly on the group ids
  when every output is a *simple aggregate* (below); otherwise it keeps the per-group
  interpreter path.
- **Lazy `group_by ⨟ summarise`** (and `summarise(...; by)`): when every output is a simple
  aggregate and the input of the `group_by` is the streamed stage, the plan's tail becomes a
  **hash-aggregate sink**: the streamed stage's morsels feed per-task partial aggregation, there
  is no gathered frame. Otherwise the summary runs on the gathered frame through the eager
  operator (as phase 3), and `explain` says why ("not a simple aggregate: `median`").
- **Lazy grouped `mutate`** (a window) becomes a **grouped-window sink**: it materializes its
  input, builds the group index with the fast path, evaluates groups in parallel (contiguous
  group ranges per task, ADR-0003 rule 6) and scatters results back in row order.

**Simple aggregates:** a summary output whose expression is one `Reduce` of `sum`, `prod`,
`mean`, `minimum`, `maximum`, `count` (Bool), `length`, `any`, `all`, `first`, `last`,
`var`/`std` (Moments), `n_distinct` is *not* simple (holistic), over a `Col` or a `SkipMiss(Col)`,
or `n_rows()` (NRows). Anything else (holistic reductions, expressions over several reductions,
`Pipe`, references to earlier outputs) is not simple.

### 2.2 Typed keys

- One key column of concrete non-missing type `T` (or `Union{Missing, T}`): the key is the
  canonical value (`_canon`, rule 8), hashed with a fixed mix of `hash(x)` (Base `hash` agrees with
  `isequal`, after canonicalisation ±0 and NaNs coincide). Several key columns: a concrete
  `Tuple` of canonical values. A `DictColumn` key uses its codes (after canonicalising the
  dictionary: two entries may still be ±0.0 or NaN payloads) as `Int32`/`UInt32` keys, so string
  keys never hash strings per row.
- Keys of an abstract element type (`Any`) fall back to the existing path (documented, rare).
- Tables are open-addressing (linear probing, power-of-two capacity, load ≤ 0.5), with keys,
  hashes and group slots in separate typed vectors. No `Dict{Any}` anywhere on the hot path.

### 2.3 Parallel partial aggregation (two-phase, order-preserving)

- **Partial:** each task owns a **contiguous range of morsels** (ADR-0003 rule 6) and a
  thread-local table; it folds each morsel's rows into per-group accumulators through the
  aggregator protocol of the upstream adapter (`UP.init`/`UP.partial`/`UP.combine`/`UP.final`,
  ADR-0014): typed accumulator vectors for `Sum`, `Count`, `Mean`, `Min`, `Max`, `CountTrue`,
  `AnyM`, `AllM`, `Moments`; a `Vector{Any}` of protocol accumulators for the others (`First`,
  `Last`, `MapM`, `ReduceM`, `SkipMissingAgg`). A specialised loop must give the same value as
  the protocol call on the same rows (unit-tested per aggregator).
- **Adaptive switch (ADR-0003 rule 9):** a thread-local table that passes `RADIX_SWITCH` groups
  (initially 2¹⁶, calibrated by the bench lane; a keyword overrides it for tests) flushes its
  accumulators into 2ᵖ radix partitions by key hash, stamped `(range, seq)`, and routes later
  rows' accumulators there. A source with `ndistinct` statistics above the limit starts in radix
  mode.
- **Merge, in order:** per radix partition (or the single table set), one task combines each
  group's accumulators **in (range, seq) order** (`UP.combine`, CC-005: correct for `First`,
  `Last`, `ReduceM`).
- **Final:** `UP.final` per group; the result's rows are sorted ascending by the key values
  (CF-008; the existing `_valueranks` order: `isless`, NaN before `missing`, first-seen ±0.0 key
  value), so the output is independent of the strategy and the thread count.
- **Empty groups / empty input** follow CC-006/CC-007 exactly as the eager operator does (a
  semigroup over an empty group throws the table's type). `drop = false` with `DictColumn` keys
  adds the empty groups of absent levels in the final step, as `_build_gindex_keep` does.
- **Floats:** partial sums are combined in a different association than one pass over a group,
  so float results agree within CC-004's tolerance (CF-008's approximate frame equality); the
  property tests compare that way. Integer, `Bool`, string and `first`/`last` results are exact.

### 2.4 Radix partitioning (one primitive, ADR-0003 rule 10)

`radix_partition(hashes, p) -> (offsets, perm)`: a stable counting scatter (histogram per task
range, prefix sums in (task range, morsel) order, scatter), reused by the aggregate sink, the
partitioned join build and later spilling. A property test checks stability.

## 3. Codegen kernels (ADR-0025; ADR-0003 rule 12; DESIGN §7 item 3)

- `stage_kernel(ph, est_rows)` returns the callable each morsel runs through.
  - **Compiled kernel:** the streamed stage (filters and elementwise `mutate`/`select`
    expressions over `Col`, scalar `Lit`, `Call`, `CaseWhen`) is lowered to a composition of
    closures whose types encode the shape; literals are fields (runtime values), so a new
    constant does not recompile. One fused row loop per stage: filter masks and elementwise
    outputs are computed in one pass over the morsel's columns, written into preallocated typed
    output vectors (the element types from `static_type`, as the interpreter's), no per-op
    intermediate vectors.
  - The compiled kernel is cached for the session in a `Dict` keyed by
    `(stage shape, input column types)`; the shape excludes literal values.
  - **Interpreter** (the phase-3 path) when the shape is not cached **and** `est_rows <
    INTERP_THRESHOLD`, when the stage is deeper than 50 nodes, or when a node is not compilable
    (an abstract-typed column, `Pipe`, a vector `Lit`, …). `INTERP_THRESHOLD` starts at 10⁵ and
    is set from the codegen lane's measurements (break-even of compile time against per-row
    savings, on 1.13 and 1.10), recorded in ADR-0025.
  - Exceptions: the compiled kernel must raise the same exception type as the interpreter on the
    same morsel (the replay guard covers order; a property test covers types on throwing
    stages, e.g. `log.(c.x)` on negatives, `div.(c.a, 0)`).
  - No `eval`, `invokelatest`, `@generated` or RuntimeGeneratedFunctions (ADR-0003 rule 12).
- `explain` prints `kernel: compiled (cached | compiled now) | interpreter (why)`; the rendered
  kernel section and `code_lowered` are unchanged (rule 13).
- A property test runs generated stages through both the compiled kernel and the interpreter and
  compares (exact for non-reductions: elementwise results are bitwise equal).

## 4. Testing

- **lazy == eager (CF-008)**, extended: the generator in `test/lazy/lazy_eager_property_tests.jl`
  gains `group_by ⨟ summarise` with simple and non-simple aggregates, grouped windows,
  `summarise(; by)`, and joins of every kind with a second generated table (shared key columns
  with NaN, ±0.0, `missing`, duplicates, empty tables), at morsel sizes 1–7, with the radix switch
  forced to 4 groups and each join strategy forced, at `-t 1` and `-t 4`. Results compared with
  approximate frame equality; exception types compared.
- **Oracle:** `test/engine/oracle.jl` gains a nested-loop join reference (row loops, rule 8
  equality, dplyr order) used by the join property tests.
- **Differential:** joins against dplyr (`Rscript`, dplyr 1.2.0) and DuckDB/Polars (`uv`,
  pinned as the existing suite) on generated data including `missing`, NaN, ±0.0, duplicates and
  empty inputs; DuckDB's and Polars' null-key semantics differ (`na_matches = :never`
  equivalent), recorded as encoded divergences in `docs/research/differentials-joins.md`.
  Grouped summaries already have differential coverage; the new operator runs under it.
- **Unit:** per aggregator, specialised loop == protocol; radix stability; the switch at 4
  groups with `First`/`Last`/`ReduceM(string *)`; each join kind × `na_matches` × `keep` ×
  `multiple`/`unmatched`; filter pushdown fires / does not fire per kind; tree printing
  snapshots.
- **JET/Aqua** stay clean; the new hot loops are checked with `@test_opt` on concrete inputs
  in `test/jet/`.

## 5. Benchmarks and budgets (ADR-0022)

- New `SUITE` entries with budget rows for 1.13 and 1.10: group-by (Int key, String key,
  dictionary String key, two-column key; 10, n ÷ 10 groups) at 10⁴/10⁶ rows, eager and lazy;
  joins (inner, left; 1:1 and 1:n; broadcast and partitioned) at 10⁴/10⁶ rows; a compiled
  streamed stage at 10⁶ rows.
- `benchmark/compare/` (not in `SUITE`): db-benchmark-like groupby q1–q5 and join q1–q3 at 10⁷
  rows (10⁶ fallback when memory or time does not allow, recorded) against the current path
  (main), DataFrames.jl, Polars and DuckDB (`uv` only). The table, wins and losses, goes into
  `docs/research/performance-phase4.md` and `docs/src/performance.md`.

## 6. Not in this phase

`cross_join`, `nest_join`, inequality/rolling joins, building on x, join reordering,
spilling, async I/O, `source_ordering`-based sort skipping, filters past total `mutate`s.
