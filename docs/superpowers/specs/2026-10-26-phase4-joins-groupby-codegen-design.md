# Phase 4 design: joins, the fast group-by with aggregate sinks, and codegen kernels

- **Date:** 2026-10-26 (revised the same day after critic REJECT and reviewer REQUEST CHANGES,
  then after critic pass 2 ACCEPT WITH CHANGES; see §8 Review log). **Branch:** `feat/phase4` (integration). Sub-lanes, in order (§0.2):
  `feat/p4-groupby` and `feat/p4-codegen` (phase A), then `feat/p4-groupby2` and `feat/p4-join`
  (phase B), then `feat/p4-bench` (phase C). **Plan:**
  [2026-10-26-phase4.md](../plans/2026-10-26-phase4.md).
- **Tier:** T2 (new public verbs: `inner_join`, `left_join`, `right_join`, `full_join`,
  `semi_join`, `anti_join`, and DataAPI join methods; new plan node; new `explain` sections).
- **Binding decisions:** ADR-0002 rule 16 (join keys), ADR-0003 rules 3–12 (engine), ADR-0004
  (sources), ADR-0007 (DataAPI), ADR-0014 (upstream stand-ins), ADR-0022 (budgets), CF-008
  (lazy == eager, approximate frame equality for reductions), the phase-3 spec §1 R-total rule.
  New ADRs: 0023 (joins), 0024 (group-by and aggregate sinks), 0025 (codegen kernels and the
  interpreter threshold).
- **Pending a user ★ (§0.4):** K1 the join keyword, K2 build side and partitioning, K3 phase-4
  join parity. p4-join stays paused until they are answered; group-by and codegen go ahead.

## 0. Seam, lane order, forcing switches, pending decisions

### 0.1 Seam (Task 0, done: b51ca4e, b161ce6, c41343b; Task 0b, done: ddf42b8)

The seam keeps the lanes' file scopes disjoint, with no behaviour change. What it holds:

- `src/lazy/kernels.jl` (not empty): `interpret_stage(ph)` (each stage step through its eager
  operator), `stage_kernel(ph, est_rows)` (seam: returns `interpret_stage(ph)`; its docstring
  requires a reentrant kernel that allocates its outputs per call and gives the interpreter's
  output column types, also on empty morsels), `_explain_kernel(io, ph)` (seam: prints nothing).
- `src/lazy/sinks.jl` (not empty): `run_rest(ph, out; morsel, threads)` (seam: the phase-3
  `apply` loop over `ph.rest`) and `_explain_rest(io, ph)` (seam: the phase-3 text).
- `src/lazy/execute.jl`: `execute` asks `stage_kernel(ph, _estimated_rows(src))` once per run;
  every morsel runs through `_runstage(ph, f, kernel)`; `_process_empty` (empty and pruned
  morsels) runs `interpret_stage(ph)`; the tail calls `run_rest`. `_estimated_rows` returns
  `nothing` or an `Int` (an upper bound when inexact).
- One-line placeholder files, included: `src/engine/radix.jl`, `src/engine/hashagg.jl`,
  `src/engine/join.jl`, `src/engine/verbs_join.jl`, `src/lazy/joins.jl`.

**Task 0b (lead, done in ddf42b8; reviewed with the seam):**

1. `explain(io, q; morsel, kernel::Bool = false)` passes `kernel` to `_explain_kernel(io, ph;
   kernel)` (seam: ignores it). The kernel line prints only when `kernel = true` (§3.4), so no
   existing snapshot changes in any lane.
2. `test/jet/runjet.jl` also includes every `test/jet/opt_*.jl` file (sorted), so each lane's
   `@test_opt` checks live in its own new file and run in its lane. `runjet.jl` is seed-once for
   the factory sync (factory/MANIFEST.toml line 36, critic pass 2), so the edit survives syncs.
3. `test/lazy/force_snippet.jl`: `@testsnippet Force` with
   `withforce(f, pairs::Pair{<:Ref}...)`, which sets each `Ref`, runs `f()` and restores the old
   values in `finally` (generic over `Ref`s, so it names no lane's switch).
4. A changelog fragment for the seam (`changelog.d/phase4.md`) and the PR reference (reviewer
   M8).

Each lane's exports live in its own file (`export` inside the module, any file).

### 0.2 Lane order (ADR-0003 rule 10: one radix primitive, no duplicate key machinery)

- **Phase A, in parallel:** `p4-groupby` (tasks 1–2: typed keys and canonicalisation, the
  open-addressing table, `radix_partition`) and `p4-codegen` (all tasks).
- **Phase B, after p4-groupby is reviewed and merged into `feat/phase4`:** `p4-groupby2` (group-by
  tasks 3–7) and `p4-join`, in parallel. p4-join forks only once the ★ K1–K3 answers are in. It
  uses the merged key and radix API (§2.2, §2.4) and must not duplicate it.
- **Phase C:** `p4-bench`, after p4-groupby2, p4-join and p4-codegen have merged.

### 0.3 Forcing switches for tests (critic M8)

Internal module-level `Ref`s, each in its owner's file. Each is read **once per `collect`** (when
the kernel, the radix limit or the join strategy is chosen), never inside a morsel loop:

| Ref | File (owner) | Values |
|---|---|---|
| `_FORCE_KERNEL::Ref{Symbol}` | `src/lazy/kernels.jl` (p4-codegen) | `:auto` (default), `:compiled`, `:interpreter` |
| `_FORCE_RADIX_SWITCH::Ref{Int}` | `src/engine/hashagg.jl` (p4-groupby2) | `0` = use `RADIX_SWITCH`; `> 0` overrides it |
| `_FORCE_JOIN::Ref{Symbol}` | `src/engine/join.jl` (p4-join) | `:auto`, `:broadcast`, `:partitioned` |

- `_FORCE_KERNEL[] = :compiled` compiles every stage that is compilable (§3.2). A stage that is
  not compilable still runs the interpreter.
- Tests set the switches only through `withforce` (§0.1, Task 0b). The `Ref`s are process-global.
  That is safe because TestItemRunner 1.3.2 runs test items one at a time in one process
  (settled in critic pass 2).

### 0.4 Pending a user ★ (ecosystem lead, 2026-10-26)

Each one is written as options. None is decided here.

- **K1. The join keyword.** ADR-0002 rule 16 (accepted by the user) says `on = :k` /
  `on = [:a => :b]`.
  - Option A: `on =`, as rule 16 says. It matches DataFrames.jl and DataAPI's `innerjoin(…; on)`.
  - Option B: `by =`, for dplyr parity. It amends rule 16, and is consistent with
    `summarise(…; by)`.
  - *Architect's recommendation: A.* It needs no amendment, and the DataAPI methods (§1.1) take
    `on` under either option; record `by` as a parity divergence. The text below writes the
    keyword as **`on_by`** (placeholder, pending ★ K1).
- **K2. Build side and partitioning.**
  - Option A: always build on y and partition only y; x probes its partition. This amends
    ADR-0003 rules 4 (the cost stage picks the build side) and 11 (both sides are partitioned).
    - Gains: dplyr row order with no sort, and x streams (the probe stays in the parallel streamed
      stage and x is never materialized).
    - Costs: the build memory is proportional to |y| even when |x| ≪ |y| (a 10³-row x against a
      10⁷-row y builds 10⁷ entries), and there is one strategy fewer to tune.
  - Option B: conform to the ADRs. The cost stage builds on the smaller side, and a partitioned
    join radix-partitions both sides.
    - Gains: build memory proportional to min(|x|, |y|), and cache-resident partitions for big–big
      joins.
    - Costs: when x is the build side it is materialized, so the probe is a pipeline breaker on x
      and is no longer streamed. dplyr order needs a stable counting sort of the (xrow, yrow)
      pairs by xrow: O(m + |x|) time and two `Int` vectors of length m, plus a matched bitmap
      over x for left/full. Partitioning both sides costs a scatter pass over x and y, and the
      pairs then always need that sort. The test matrix doubles (each build side × strategy
      forced).
  - *Recommendation: A for phase 4.* Revisit if p4-bench measures a small-x/large-y case that
    loses more than 2× against DuckDB.
  - The §1 text is written for option A and marked "PENDING ★ K2". Under B, §1.2's build and
    probe bullets and §1.4's lowering change as described above.
- **K3. Phase-4 join parity.**
  - Option A (recommended): ship `cross_join` and the equality-only `join_by(:a => :b)` (an alias
    form of the `on_by` keys) plus the DataAPI methods. Defer `nest_join` and inequality/rolling
    joins. Inequality/rolling joins have no design yet:
    [parity-dplyr.md](../../research/parity-dplyr.md) "open items".
  - Option B: ship `nest_join`, `cross_join` and `join_by` as the parity matrix lists them (phase
    4). `nest_join` returns a column of y sub-frames per x row. That adds about one task: a nested
    output column, its lazy streaming, and differentials against dplyr. Inequality/rolling joins
    stay deferred under both options.
  - The ADR-0003 deviations (rules 4 and 11) in §1.2 are "PENDING lead decision (ADR-0003 rules
    4 and 11 amended by ADR-0023)" and are settled by K2.

## 1. Joins (ADR-0023; DESIGN §7 item 1; parity rows `inner_join` … `anti_join`)

### 1.1 API (dplyr 1.2.0 semantics; verified facts in §1.6)

```julia
inner_join(y; on_by = nothing, suffix = ("_x", "_y"), na_matches = :na, keep = false,
           multiple = :all, unmatched = :drop)
left_join(y; …same…); right_join(y; …same…)
full_join(y; on_by = nothing, suffix, na_matches, keep, multiple)    # no `unmatched` (dplyr)
semi_join(y; on_by = nothing, na_matches = :na)
anti_join(y; on_by = nothing, na_matches = :na)
# `on_by`: placeholder for `on` or `by`, pending ★ K1
```

- Each verb returns a `JoinStep <: Step` holding `y`: any Tables.jl table, converted once with
  `Frame(y)`, or a `LazyFrame`/`Source`. Both `x |> inner_join(y; on_by)` and
  `inner_join(y; on_by)(x)` work (CF-007). An eager `x` with a lazy `y` collects `y` first (the
  eager meaning).
- **DataAPI methods (ADR-0007):** `DataAPI.innerjoin`, `leftjoin`, `rightjoin`, `outerjoin`,
  `semijoin` and `antijoin` on `(x::Frame, y)`, plus `crossjoin` if ★ K3 ships `cross_join`.
  Each takes DataFrames' keyword `on` (under either K1 option) and forwards to the verb. All
  seven names exist in DataAPI 1.16.0 (checked: `names(DataAPI; all = true)` in this
  package's environment).
- **`on_by`:** `nothing` is a natural join on the common column names. `:a`, `"a"`, `[:a, :b]`
  and `:a => :b` (x's `a` equals y's `b`, left `=>` right as rule 16 says) work, as does a vector
  of those. No common column under `nothing` → `ArgumentError` (dplyr errors too).
- **The natural-join message (one rule, critic n9):** a natural join logs
  `@info "Joining with on_by = [...]"` (silenceable with `with_logger`) **once, when its
  `JoinNames` are resolved** (§1.4).
  - Usually that happens when the step is applied to x: an eager apply, or `JoinNode`
    construction for a lazy x.
  - When a side has no static schema, resolution happens at `collect` time, so that `collect`
    logs (documented in the `JoinStep` docstring and `docs/src/lazy.md`).
  - Once resolved, `JoinNames` are stored in the node, so `optimize`, later passes and replay
    never log again.
  - The step itself cannot log at construction: x is not known yet.
- **Key equality:** ADR-0003 rule 8 (NaN is one key, ±0.0 is one key, `missing` is its own key).
  - `na_matches = :na` (the default, as dplyr): `missing` matches `missing` and NaN matches NaN.
  - `na_matches = :never`: a key row holding `missing` **or NaN** in any key column matches
    nothing (verified in §1.6). Such x rows are unmatched rows: left/full/anti keep them,
    inner/semi drop them.
- **Key types (critic N1).** Let `Sx = nonmissingtype(Tx)` and `Sy = nonmissingtype(Ty)` for a
  key pair. The pair is **allowed only** in three cases:
  - `Sx === Sy`;
  - both are `<: AbstractString`. They are unified the way `bind_rows` unifies them: its
    `vcat_columns` (src/columns.jl) collects the values and calls `column`, which builds a
    `StringColumn` for any `AbstractString` element type. The output key is a `String` column
    (the join builds it). The typed keys keep each column's own string type (e.g. `StringView`;
    no per-row conversion): `isequal` and `keyhash` agree across `String`, `SubString` and
    `StringView` (tested), and a `KeyTable{String}` accepts `StringView` keys, converting once per
    new key. Two string types never promote to `AbstractString`;
  - both are in `Union{Bool, Base.BitInteger, Base.IEEEFloat}` and `T = promote_type(Sx, Sy)`
    keeps every value of both. `_lossless_key_promotion(Sx, Sy)` and `_keypair_allowed(Sx, Sy)`
    (`src/engine/hashagg.jl`, with the rest of the key machinery; p4-join calls them and never
    redefines them) decide this. A side whose nonmissing type is `Union{}` (an all-`missing` key
    column) pairs with any type: it can only match `missing`.
    - integer → integer when `typemin`/`typemax` fit in `T` (so `Int64`/`UInt64` is rejected:
      a negative key would throw `InexactError`);
    - integer → float when the integer's bit width ≤ the float's significand bits + 1
      (`Int32`/`Float64` is allowed; `Int64`/`Float64` is rejected);
    - float → wider float.

    This is the same "promote only when lossless" rule that `column` applies (ADR-0001 rule 12).

  Every other pair → `ArgumentError` naming both columns and types, raised when the step is
  applied (eager) or at `JoinNode` construction (lazy). Rejected pairs include `Date` vs
  `DateTime` (they are `isequal`-compatible in some cases but hash differently, so they would
  silently not match), `Int64` vs `Float64`, `Int64` vs `UInt64`, `String` vs `Int`, and other
  `Real`s that are not identical (`Rational`, `BigFloat`, fixed-point types). The fix is to
  convert first. That `Int64`/`Float64` is rejected is a **parity divergence** (dplyr casts to
  double, §1.6), recorded in parity-dplyr.md. The 2⁵³ problem therefore cannot occur.
  - Allowed pairs compare with `isequal` on canonical values, with no conversion. The output key
    column has element type `promote_type(Sx, Sy)` (or `String`), with `Missing` added when
    either side is nullable.
  - **Required test** (p4-groupby task 1 for `keyhash`, and p4-join for the pair rule): for every
    allowed pair of types and generated values, including ±0.0, NaN payloads, `NaN32` vs `NaN`,
    `true` vs `1` and `SubString` vs `String`, `isequal(a, b)` implies
    `keyhash(a) == keyhash(b)`.
  - Dictionary keys from two frames are compared **by value** (rule 11; §2.2
    `typed_keys(...; codes = false)`).
- **Output columns and order (dplyr):** x's columns in order, then y's non-key columns in order.
  - `keep = false`: the key columns appear once, with x's names. Their values are x's values,
    except for right/full rows that exist only in y, which take y's key values.
  - `keep = true`: both key sets are kept, and **both** clashing key columns get the suffix
    (`k_x`, `k_y`), as dplyr gives `k.x`, `k.y` (§1.6).
  - Non-key name clashes get `suffix`. semi/anti return x's columns only.
  - The suffix default `("_x", "_y")` is a **parity divergence** from dplyr's `(".x", ".y")`:
    names with `.` are awkward in Julia (`c.v_x` works, `c."v.x"` does not). Record it in
    [parity-dplyr.md](../../research/parity-dplyr.md).
- **Row order (dplyr 1.2.0):** inner/left: x row order, each x row's matches in y row order.
  right: the inner rows in x order, then y rows with no match in y order. full: the left join's
  rows, then y's unmatched rows in y order. semi/anti: x rows in x order, each once.
- **`multiple`** (inner/left/right/full): `:all` (the default), `:any`, `:first`, `:last` or
  `:error`. dplyr's `"warning"` is skipped.
  - `:any` is defined as `:first` (deterministic, so lazy == eager).
  - Under `multiple ≠ :all`, a y row that matched an x row's key but was **not chosen** counts as
    **unmatched** (critic n3). It is appended by a right/full join's tail, and it triggers
    `unmatched = :error` on the y side. The probe marks only the chosen y rows in the hidden
    column. Verified against dplyr 1.2.0 (§1.6); the p4-join differential keeps this case.
- **`unmatched`** (inner/left/right only): `:drop` or `:error`. Each kind checks the side it
  would drop (§1.6): inner checks x and y, left checks y, right checks x. An unmatched row →
  `ArgumentError`. dplyr's default `relationship = NULL` many-to-many warning is not reproduced
  (a documented difference).
- **Grouping:** a grouped x keeps its groups (dplyr keeps x's grouping), and the group index is
  rebuilt on the output with `build_gindex` (read-only use). A grouped y is ungrouped first.
- **Element types (static, by join kind, never from the data):**
  - left: y's non-key columns become `Union{Missing, T}`;
  - right: x's non-key columns;
  - full: both sides' non-key columns.
  - Key columns get the allowed pair's output type (N1 above).
  - The types widen even when every row matched, so lazy == eager whatever the data.
  - Dictionary columns keep their dictionary when every value comes from one frame. A key column
    fed by both frames (right/full, `keep = false`) is decoded to plain values.

### 1.2 The hash join (one physical operator, eager and lazy). PENDING ★ K2

PENDING lead decision (ADR-0003 rules 4 and 11 amended by ADR-0023). Written for option A:

- **Build side is always y**, probe side x. That gives dplyr's row order without a sort.
- **Build:** y's key columns become typed keys (§2.2 `typed_keys(...; codes = false)`) in a
  `KeyTable` (§2.2) that maps a key to its dense id.
  - Abstract key types (critic n6): when `typed_keys` returns `nothing` for either side (a key
    column of abstract element type, e.g. `Any`), the join raises `ArgumentError` naming the
    column and suggesting a conversion.
  - A `Dict`-based fallback is documented as later work (not in phase 4), so the hot path never
    holds a `Dict{Any}`. A `first::Vector{Int}` maps the id to the
  first y row, and a `next::Vector{Int}` chains y rows with the same key **in y row order**.
- **Strategy (cost stage):**
  - **broadcast:** one shared build table, built by one task, when y's estimated rows (from
    `row_count` / the collected y) are below `BROADCAST_MAX_ROWS = 131_072` and y's estimated
    **input bytes** (every y column the join reads, not only the keys) are below
    `BROADCAST_MAX_BYTES = 4 MiB`. These are DataFusion's defaults as ADR-0003 rule 11 records
    them. UNVERIFIED here (the critic reports the byte limit is on input bytes); p4-bench
    rechecks the DataFusion source and recalibrates. Both constants live in `src/engine/join.jl`.
  - **partitioned:** y's rows are radix-partitioned (§2.4 `radix_partition`) by key hash into 2ᵖ
    partitions (p = 4–8, chosen from the row count), and each partition's table is built by its
    own task. A probe row looks its key up in partition `h >> (64 - p)`.
  - Both strategies give identical results; `_FORCE_JOIN` (§0.3) forces each one in turn.
- **Probe (`ProbeStep`):** per x morsel, statelessly against the frozen build table. For each x
  row it emits the matching y rows as `(xrow, yrow)` pairs, applying `multiple` row by row, then
  one `take` per column. Row-local checks raise in the probe: `multiple = :error`, and
  `unmatched = :error` on the x side (inner, right). Right joins drop unmatched x rows here.
  When a tail is needed (below), the probe also emits a hidden column `Symbol("##chui_yrow")`
  (the matched y row, `0` for an unmatched x row). There is no shared `BitVector` (critic M1).
  A user column named `##chui_yrow` on either side → `ArgumentError` when the step is applied or
  the `JoinNode` is built (critic n10), so the hidden column can never collide.
- **`JoinTailStep`** (a pipeline breaker, in `rest`, eager, after the gather) is placed when the
  kind is right or full, or when `unmatched = :error` with a y-side check (inner, left). It:
  1. builds the matched-y bitmap from the gathered hidden column, on one task;
  2. under `unmatched = :error`, raises `ArgumentError` for the first unmatched y row;
  3. for right/full, appends the unmatched y rows in y order (x columns `missing`, keys from y);
  4. drops the hidden column.

  No change to `execute.jl` for joins: `isstreamable(::ProbeStep) = true` and
  `isstreamable(::JoinTailStep) = false` are methods in `src/lazy/joins.jl`, so `physical` puts
  the tail in `rest`. A `head` above a join with a tail stays in `rest`, after the tail.
- **Totality:** `_steptotal(::ProbeStep, below)` (a method in `src/lazy/joins.jl`) is `true` only
  for a total join (§1.3). Otherwise a limit never stops early past it.
- **Eager:** `JoinStep` applied to a frame runs the same build, probe and tail on the whole frame,
  as a single morsel, on the calling task below 65 536 x rows (ADR-0003 rule 2).

### 1.3 Filter pushdown through a join (critic B1, minor "key copy")

A join is **total** for pushdown only when `unmatched = :drop` and `multiple ∈ (:all, :first,
:last, :any)` (semi/anti are always total). The rules:

- **Never** push a filter past a non-total join (`unmatched = :error` or `multiple = :error`):
  - a pushed x filter could remove the x row that would have raised;
  - a pushed y filter could remove the y row that would have raised.
- **Never** push a filter to y unless `multiple = :all`: under `:first`/`:last`/`:any`,
  filtering y first changes which match is chosen (§1.6: `multiple = "first"` then
  `filter(w > 1)` gives 0 rows; filtering y first gives 1).
- When the join is total, a filter directly above it whose own predicate is R-total, and whose
  columns all come from one side, moves to that side. Names are mapped back through the
  construction-time name map (§1.4):
  - inner: either side (y only when `multiple = :all`);
  - semi/anti: x (their output has x's columns only);
  - left: x only; right: y only (when `multiple = :all`); full: never.
- **Key columns under `keep = false`:** a predicate on the output key is pushed to **x only**,
  only for inner/left/semi/anti (the output key is x's value), and only when
  `nonmissingtype(promote_type(Tx, Ty)) === nonmissingtype(Tx)` (critic N2). Otherwise the output
  key has a wider type than x's key (e.g. x `Int32`, y `Float64`), and the predicate could give
  a different answer on x's unpromoted values. It is **never** copied to y. A copy
  would need `P(x.k) == P(y.k)` whenever the keys match under rule 8, and that fails for `signbit`
  on 0.0 vs −0.0, and for `typeof`-sensitive predicates across allowed cross-type pairs (e.g.
  `Int32`/`Float64`). right/full: key predicates are not pushed.
- **Unit cases where the rule must not fire:**
  - `multiple = :first`, `:last` and `:any` with a y-column filter (not pushed to y);
  - `multiple = :error` with an x-column filter and with a y-column filter (not pushed at all);
  - `unmatched = :error` for inner (x filter and y filter), left (y filter) and right (x filter)
    (not pushed);
  - full join with any filter;
  - a key predicate on right/full;
  - `signbit.(c.k)` with x.k = 0.0, y.k = −0.0 (never copied to y; lazy == eager);
  - a key predicate when the output key type is wider than x's (x `Int32` vs y `Float64`; N2);
  - the 2⁵³ case: x `Int64` key `2^53 + 1` vs y `Float64` key `2.0^53`. The pair is rejected
    with `ArgumentError` at `JoinNode` construction (N1), before any pass runs, so no pushdown
    can happen. The test asserts the error, and that eager raises the same;
  - a non-R-total predicate.

  The positive cases (fires) are tested for each kind too.

### 1.4 The plan becomes a tree

- `JoinNode(left, right, spec::JoinStep, names::JoinNames) <: PlanNode` has **`Any`-typed**
  children (R6), and a `fmap` that maps both children, so the R6 stand-ins (`cata`, `para`)
  traverse trees. `Base.:(==)(a::JoinNode, b::JoinNode) = a.spec === b.spec && a.left == b.left
  && a.right == b.right` follows the existing `StepNode` rule (`step ===`, src/lazy/plan.jl), so
  the optimizer's fixpoint check sees an unchanged join as unchanged.
- **The name map is resolved once, at `JoinNode` construction, from the unprojected schemas
  (critic M3).** Each side's schema is its subplan applied to the empty frame of its source schema
  (the probe technique of `render_kernel`, src/lazy/render.jl). `JoinNames` records:
  - the resolved key pairs (including `on_by = nothing`);
  - every output name and its source (side, column);
  - the clashing names.

  The output names never depend on later projection.
- **Optimizer, tree-aware:**
  - Constant folding, filter splitting and the phase-3 pushdown rules run in each subtree.
  - Projection pushdown runs per side. Each side supplies its keys, the columns read above
    (mapped through `JoinNames`), and **every clashing column, on both sides**, so a suffix never
    disappears. Example: for x(k, v), y(k, v), `inner_join(y; on_by = :k) ⨟ select(:v)` throws
    in eager (`v` is `v_x`/`v_y`), and lazy must keep `y.v` and throw too.
  - A side whose schema cannot be computed statically (the probe throws) is not projected. Its
    `JoinNames` is then resolved at collect time, and that is when the natural-join message is
    logged (§1.1, n9). The N1 key-type check and the n10 hidden-name check also run then.
- **Lowering for execution** (`src/lazy/joins.jl`): before `physical`, every `JoinNode` becomes
  `StepNode(ProbeStep(build, spec, names), left)`, with `JoinTailStep` above it when §1.2 says so.
  `build` is the right subplan.
  - `collect` executes the right subplan (recursively, inside the CF-008 replay guard) into the
    build table.
  - `explain` prints the subplan and does not execute it.
- **Replay (`reference`)** handles trees: a `JoinNode` replays as an internal apply of `spec` with
  the resolved `JoinNames` to `reference(left)`, with `y = reference(right)` (no second
  `@info`).
- **`explain`:**
  - The logical and optimized plans are drawn as trees (box-drawing `├─`/`└─`, the prototype's
    printer style): `join(inner; on_by = [:a => :b])` with `x:` and `y:` children. Linear plans
    print exactly as before.
  - The physical section names the strategy (`broadcast` / `partitioned into 2ᵖ`), the
    estimated build rows, the build subplan, and the tail when there is one.
  - The rendered-kernel section for a stage holding a `ProbeStep` prints
    `not rendered (the stage holds a join probe)` instead of `none (no streamed stage)`
    (src/lazy/explain.jl; `render_kernel` returns `nothing` there).
  - Snapshot-tested on stable Julia in the new directory test/snapshots/lazy_join/.

### 1.5 Parity rows in this phase (PENDING ★ K3)

Under option A:

- **`cross_join(y; suffix = ("_x", "_y"))`** (critic n10). It returns a `JoinStep` of kind
  `:cross` with no keys and no `na_matches`/`keep`/`multiple`/`unmatched`, as dplyr's
  `cross_join(x, y, suffix)`.
  - Output: x's columns, then all of y's columns. Clashing names get `suffix`.
  - Rows: |x| × |y|, in x order, each x row's block in y order.
  - Element types are unchanged (no row is unmatched). A grouped x keeps its groups.
  - Lazily it is a `ProbeStep` whose "build" is the collected y (no hash table, streamed over x
    morsels, no tail). Filter pushdown sends a one-side filter to that side (cross joins are
    total).
  - `DataAPI.crossjoin(x::Frame, y)` forwards to it.
- **`join_by(:a => :b, …)`**: builds the same key specification as `on_by` (the equality form
  only). `nest_join` and the inequality/rolling `join_by` stay `planned`. Under option B,
`nest_join` is added (§0.4).

### 1.6 dplyr facts (verified 2026-10-26, Rscript, dplyr 1.2.0)

- `inner_join(x, y, by = "k", keep = TRUE)` names: `k.x v.x k.y v.y w`, so both keys get the
  suffix.
- `full_join.data.frame` formals: `x, y, by, copy, suffix, ..., keep, na_matches, multiple,
  relationship` (no `unmatched`). `semi_join`: `x, y, by, copy, ..., na_matches`.
- `unmatched = "error"`:
  - `right_join` raises "Each row of `x` must have a match in `y`";
  - `left_join` raises "Each row of `y` must be matched by `x`";
  - `inner_join` raises both messages, one per side.
- `inner_join(x, y, multiple = "first") |> filter(w > 1)` gives 0 rows; filtering y first gives
  1. With `multiple = "last"` the same divergence appears.
- NaN keys: 1 row under the default `na_matches`, 0 under `"never"`. An integer key joined with a
  double key gives a `numeric` output key (ChuiFrames rejects `Int64`/`Float64` instead; §1.1
  N1).
- Unchosen y rows (critic n3): with x(k = 1) and y(k = [1, 1]):
  - `right_join(..., multiple = "first")` gives 2 rows, the second with `a = NA`, `w = 20`;
  - `full_join(..., multiple = "last")` gives `w = 20` matched, then `w = 10` with `NA`;
  - `left_join`/`inner_join` with `unmatched = "error"` and `multiple = "first"`/`"any"` raise
    "Each row of `y` must be matched by `x`" for row 2;
  - `multiple = "any"` chose the first match here.

## 2. Fast adaptive group-by and the aggregate sinks (ADR-0024; DESIGN §7 item 2)

### 2.1 What runs where

- **Eager `group_by`** builds its `GroupIndex` (ADR-0003 rule 3) with the typed keys (§2.2)
  instead of `Dict`-per-column codes plus pairwise `Dict{Tuple{Int,Int}}` codes. The index's
  meaning is unchanged: ids, perm, starts, keys in ascending order, and the first-seen key value
  for ±0.0. Every existing test keeps passing. ADR-0022 rule 3: eager `group_by` on 10-row
  frames must stay within its `n=10` budget row. If table setup costs too much there, small
  inputs keep a direct path; p4-groupby2 runs the `n=10` rows.
- **Eager grouped `summarise` (critic M5):** per group, the **same Base call on the same values
  in the same order** as phase 3 (the group's rows, from the `GroupIndex`'s contiguous `perm`
  range, through the existing per-group interpreter). Only the index construction changes, so
  the results are bitwise equal to phase 3. A test compares phase-3 values with `===`. Typed
  per-row accumulators are used **only** in the lazy sink.
- **Lazy `group_by ⨟ summarise`** (and `summarise(...; by)`) becomes a **hash-aggregate sink**
  when every output is a simple aggregate, every key is a plain column of the streamed stage's
  output, and the `group_by` input is the streamed stage. The streamed stage's morsels feed
  per-task partial aggregation, and no gathered frame is built. Otherwise the summary runs on the
  gathered frame through the eager path (as in phase 3), and `explain` says why (e.g. "not a
  simple aggregate: `median`", "computed key").
  - Computed keys and `add = true`: when the optimizer has already lowered a computed key into a
    streamed `mutate`, the key is a plain column and the sink applies. `add = true` uses the
    union of keys, in order. Otherwise the eager path runs.
  - `drop = false` with `DictColumn` keys adds the empty groups of absent levels in the final
    step, as `_build_gindex_keep` does. With other key types `drop` changes nothing.
- **Lazy grouped `mutate`** (a window) becomes a **grouped-window sink**:
  1. materialize the input;
  2. build the group index on the fast path;
  3. split the groups into contiguous ranges, one per task (ADR-0003 rule 6);
  4. each task runs the **existing** `apply(::MutateStep)` on its sub-frame (`take` of its rows,
     with `take_gindex`), which reuses `eval_column`'s grouped path unchanged;
  5. scatter the results back in row order.

  The column type is `promote_type` over the non-empty ranges (a range with no rows contributes
  no type, as `eval_column` starts from `Union{}`), which equals eager's. The property test
  checks element types. This needs no edit to src/engine/verbs.jl or src/engine/interpreter.jl.
  If the lane finds that a shared helper is needed after all, both files are already in
  p4-groupby2's scope. No other lane edits them: p4-join and p4-codegen only read `static_type`
  and `ev` (§0.2, plan table).

**Simple aggregates:** a summary output whose expression is one `Reduce` whose `_aggregator`
(src/engine/nodes.jl) is not `Holistic` or `NDistinct`, over a `Col` or a `SkipMiss(Col)`, or
`n_rows()` (NRows). That covers `sum`, `prod`, `mean`, `minimum`, `maximum`, `extrema`,
`count`, `length`, `any`, `all`, `first`, `last`, `reduce(op, x)` (ReduceM), `mapreduce(f, op,
x)` and `sum(f, x)` and the like (MapM), and `var`/`std` (Spread over Moments). Holistic
(`median`, `quantile`, `nth`), `n_distinct`, expressions over several reductions, `Pipe`, and
references to earlier outputs are not simple. This list covers the `ReduceM` the switch test
uses.

### 2.2 Typed keys (frozen API once p4-groupby merges; critic B3)

The **frozen** names and signatures below are what p4-join relies on. After p4-groupby merges,
p4-groupby2 may add methods but must not change these signatures. A change needs a spec
amendment and a note to p4-join.

```julia
# src/engine/hashagg.jl
typed_keys(cols::AbstractVector{<:AbstractVector}, n::Int; codes::Bool = true)
    -> Union{Nothing, AbstractVector}   # canonical typed keys, or `nothing` (abstract eltype: fallback)
keyhash(k)::UInt64                      # agrees with `isequal` after canonicalisation; Base `hash` mix
struct KeyTable{K}                      # open addressing, linear probing, power-of-two capacity, load ≤ 0.5
                                        # home slot of hash h: (h & (cap - 1)) + 1 — the LOW bits;
                                        # radix partitions use the HIGH bits (h >> (64 - p)), so the two never correlate
KeyTable{K}(sizehint::Int)
getorinsert!(t::KeyTable{K}, k, h::UInt64)::Int   # dense id, 1-based, first-seen order; canonicalises k
lookup(t::KeyTable{K}, k, h::UInt64)::Int         # id, or 0 when absent; canonicalises k, compares with `isequal`
Base.length(t::KeyTable)                          # number of keys
keyvalues(t::KeyTable{K})::Vector{K}              # keys in id order
```

- **One key column** of concrete non-missing type `T` (or `Union{Missing, T}`): the key is the
  canonical value (`_canon`, rule 8: ±0.0 → one key, NaN payloads → one NaN). **Several key
  columns:** a concrete `Tuple` of canonical values.
- **`DictColumn`, `codes = true`** (group-by within one frame): the codes of the canonicalised
  dictionary (two entries may still be ±0.0 or NaN payloads; they map to one code), as
  `UInt32` keys with 0 = `missing` (a dictionary never holds `missing`; one with more than
  `typemax(UInt32)` entries raises `ArgumentError`), so string keys never hash strings per row. **`codes = false`** (joins
  across frames): canonical values.
- **Cross-type lookup** (joins, `Int` x against `Float64` y): `lookup` accepts a `k` of any type
  and compares with `isequal`. `keyhash` is Base `hash` of the canonical value, which agrees
  across numeric types. A faster type-specific hash may be used only when both sides have the same
  key type.
- **Abstract element types** (`Any`): `typed_keys` returns `nothing`, and the caller uses the
  existing path (documented, rare). There is no `Dict{Any}` on the hot path. Each table keeps
  keys, hashes and ids in separate typed vectors.
- **Raw first-seen key (critic n4):** the frozen `getorinsert!` takes only the canonical key. The
  caller keeps each group's **raw first-seen key** (the uncanonicalised value of the first row)
  in a parallel vector indexed by the id, `rawkeys[id]`, pushed when `getorinsert!` returns a new
  id (`id == length(t)` after the call), plus its `(range, seq, row)` stamp. At the merge it is
  combined like `First`, so the output shows the first ±0.0 in row order (rule 8).
- **Slot rule (critic n5):** the home slot is frozen as `h & (cap - 1)` (low bits). The
  partitioned join and the radix switch rely on partitions taking the high bits, so a partition's
  table does not degrade to one probe chain.
- **Required test (critic N1):** for every allowed join key pair (§1.1) and for same-type keys,
  `isequal(a, b)` implies `keyhash(a) == keyhash(b)` (canonical values; ±0.0, NaN payloads,
  `NaN32`/`NaN`, `true`/`1`, `SubString`/`String`).

### 2.3 Parallel partial aggregation (two-phase, order-preserving)

- **Partial:** each task owns a **contiguous range of morsels** (ADR-0003 rule 6) and a
  thread-local `KeyTable`. It folds each morsel's rows into per-group accumulators.
  - **Typed accumulators** (one concretely typed vector per aggregator): `Sum`, `Count`,
    `CountTrue`, `Mean`, `Min`, `Max`, `Extrema`, `AnyM`, `AllM`, `Prod`, `Spread`/`Moments`,
    and `First`/`Last` (a value vector plus order stamps).
    - **Only `Sum`** uses `typeof(Base.add_sum(x, x))` for the column's element type `x`, so
      `Int8`/`Int32`/`Bool` widen to `Int` and `Float32` stays `Float32`, as Base `sum` does.
    - **`Mean`** (critic N4) uses `(typeof(float(x)), Int)`: a float sum plus a count, as
      `UP.Mean` does (src/engine/upstream.jl: "a float sum plus a count, so Int data never
      overflows"). An `add_sum` integer sum would overflow on `Int` data.
  - **`Vector{Any}` fallback only for `MapM` and `ReduceM`:** their result type would need
    `Base.promote_op`, which ADR-0002 rule 11 rules out for types. `SkipMissingAgg` follows its
    inner aggregator.
  - **Dictionary keys (critic M6):** each morsel's `DictColumn` codes are remapped, before
    folding, to a **global value-keyed dictionary**: one shared `KeyTable` of canonical values
    behind a lock, consulted once per distinct local code per morsel, not per row. Partitions
    with different or permuted dictionaries (per-batch Arrow dictionaries) then group by value.
- **Adaptive switch (ADR-0003 rule 9):** a thread-local table that passes the radix limit
  (`_FORCE_RADIX_SWITCH[]` if > 0, else `RADIX_SWITCH`, initially 2¹⁶) flushes its accumulators
  into 2ᵖ radix partitions by key hash, stamped `(range, seq)`, and routes later rows'
  accumulators there. A source whose `ndistinct` statistics exceed the limit starts in radix mode.
  - **Mixed modes:** tasks that never switched hand over their single table at the merge,
    partitioned by the same hash bits (`radix_partition` over their group hashes) and stamped
    `(range, 0)`. One task's range contributes either one accumulator per group, or flushed then
    later accumulators in `seq` order, so the order key `(range, seq)` is total.
- **Merge, in order:** per radix partition (or per single table set), one task combines each
  group's accumulators **in (range, seq) order** (`UP.combine`, CC-005: correct for `First`,
  `Last` and `ReduceM`).
- **Final:** `UP.final` per group (`Spread` gives `missing` for n ≤ 1, dplyr's rule, as eager
  does). The result's rows are sorted ascending by key value (CF-008; the existing `_valueranks`
  order: `isless`, NaN before `missing`, the first-seen ±0.0 key value). So the output does not
  depend on the strategy or the thread count.
- **Empty groups and empty input** follow CC-006/CC-007 exactly as the eager path does (a
  semigroup over an empty group throws the eager error).
- **Floats:** partial sums associate differently from Base's pairwise `sum` over a group, and
  `Moments` differs from the two-pass `var`. So the lazy sink's float results agree with eager
  within CC-004's tolerance (CF-008's approximate frame equality, `rtol = 1e-12`). Integer
  results (wrapping addition is associative), `Bool`, string, `first`/`last` and
  `minimum`/`maximum` results are exact.
- **Unit tests:** each typed accumulator against the protocol call on the same rows, exact for
  integers, `Bool` and `first`/`last` and within tolerance for floats, with `Int8`, `Int32`,
  `Bool` and `Float32` columns (including the widened `sum` type and `sum(Int8[]) === 0`).
  A `Mean` test over `fill(typemax(Int), 4)` split across morsels must give `float(typemax(Int))`
  within tolerance, as eager `mean` does, with no overflow (N4).

### 2.4 Radix partitioning (one primitive, ADR-0003 rule 10; frozen API)

```julia
# src/engine/radix.jl
radix_partition(hashes::AbstractVector{UInt64}, p::Int; ntasks::Int = 1)
    -> (offsets::Vector{Int}, perm::Vector{Int})
# partition of element i: hashes[i] >> (64 - p); offsets has 2^p + 1 entries;
# perm[offsets[j]:offsets[j+1]-1] lists partition j's elements in ascending index order (stable)
# 0 <= p <= RADIX_MAX_BITS (20) and ntasks >= 1, else ArgumentError
```

It is a stable counting scatter: a histogram per task range, prefix sums over partitions
(outer) and task ranges in order (inner), then the scatter. The histogram holds 2^p × ntasks
`Int`s (twice that with the scatter positions), so callers choose a small `p`. The aggregate sink, the partitioned join build and later spilling all
use it. A property test checks stability and that the result is a permutation.

## 3. Codegen kernels (ADR-0025; ADR-0003 rule 12; DESIGN §7 item 3)

### 3.1 The decision

`kernel_decision(ph, est_rows) -> (kind::Symbol, why::String)` (in `src/lazy/kernels.jl`) is used
by `stage_kernel` and `_explain_kernel`, so `explain` and `collect` agree:

- `_FORCE_KERNEL[] = :interpreter` → interpreter. `= :compiled` → compiled when the stage is
  compilable (§3.2).
- The stage is not compilable, or deeper than 50 nodes → interpreter (why: the first
  non-whitelisted step or node).
- The shape is cached → compiled.
- `est_rows === nothing` (unknown) → treated as unknown, so compiled **only when cached**;
  otherwise the interpreter.
- `est_rows < INTERP_THRESHOLD` and not cached → interpreter. Otherwise compile now.
- `INTERP_THRESHOLD` starts at 10⁵ (ADR-0003 rule 12). p4-codegen sets it in its lane from its
  measurements (compile time against per-row savings, on 1.13 and 1.10), recorded in
  ADR-0025.

### 3.2 Compilability is a whitelist (critic minor)

- **Steps:** `FilterStep` (scalar predicates), `MutateStep` (elementwise: `by === nothing`,
  `keep === :all`, no `Window`/`Reduce`), `SelectStep` (plain names and elementwise pairs),
  `RenameStep`, `RenameWithStep` and `RelocateStep`. Anything else (`ProbeStep`, any future
  step) → the whole stage runs the interpreter.
- **Nodes:** `Col`, scalar `Lit`, `Call`, `CaseWhen`. Not compilable: `Pipe`, a vector `Lit`,
  `IfAnyAll`, anything else.
- **Types:** compilable only when every computed column's `static_type` is concrete (or
  `Union{Missing, T}` with `T` concrete). It must also pass a check once per compile: run the
  compiled kernel and `interpret_stage` on the empty probe frame, and compare, per output column,
  the **column object's type** `typeof(col)`, not only the element type (critic N3). A
  `DictColumn` must stay a `DictColumn`, a `StringColumn` a `StringColumn`. A mismatch →
  interpreter.

### 3.3 The compiled kernel (critic B2)

- The stage is lowered to a composition of closures whose types encode the shape. Literals are
  fields (runtime values), so a new constant does not recompile. One fused row loop per stage
  computes the filter mask and the **computed** columns. Each computed column is written into a
  typed vector **allocated per call** (reentrant: the kernel is shared by every task; seam
  docstring), then wrapped by the same column constructor the interpreter uses (`typed_column`,
  as `apply(::MutateStep)` does).
- **Column kinds (critic N3):** passed-through, renamed and filtered columns keep their **column
  object**. They are the input column itself, or `take(col, kept_rows)` on the original column
  when a filter dropped rows, never a vector rebuilt from values. So a `DictColumn` keeps its
  dictionary and its unused levels, and `group_by(drop = false)` after the stage still shows the
  empty levels.
- **Scalar-only subexpressions (critic n2):** a subexpression with no `Col` (e.g.
  `lit(1) + lit(2)` left after folding, or `sqrt(lit(-1.0))`) is evaluated **once per morsel**,
  as the interpreter evaluates it once per call. That happens even when no rows remain after a
  filter, so a throwing scalar subexpression raises on every morsel as the interpreter's does.
- **No short-circuit:** like the interpreter (src/engine/interpreter.jl `ev(::CaseWhen)`
  evaluates every condition, value and the default; src/engine/verbs.jl filter evaluates every
  conjunct), the kernel evaluates **every filter conjunct and every `case_when` branch and the
  default on every row of the morsel**.
- **Exceptions:** a fused loop meets errors in a different order across steps. For example,
  `mutate(a = log.(c.x)) ⨟ mutate(b = div.(c.y, c.z))` with x = [1, −1], z = [0, 1] raises
  `DivideError` fused but `DomainError` interpreted. So on any exception the kernel re-runs
  that morsel through `interpret_stage(ph)` and rethrows the interpreter's exception.
  - The one exception is `InterruptException`, which is rethrown **at once**, with no re-run
    (critic n1).
  - If the interpreter succeeds, its result is used and an internal counter
    `_KERNEL_DISAGREE::Threads.Atomic{Int}` is incremented. Tests read the counter before and
    after the code under test and assert the **difference** is 0 (critic n7), because the counter
    is cumulative over the session.
- **Output types** equal the interpreter's, column kinds included, also on empty morsels:
  `_process_empty` uses `interpret_stage`, and §3.2's `typeof(col)` check guarantees that the
  compiled outputs match.
- **Cache:** `_KERNEL_CACHE::Dict{Any, Any}` guarded by `_KERNEL_LOCK::ReentrantLock`, keyed by
  `(shape, input column types)`. The shape includes each `Call`'s `typeof(f)` and each literal's
  type, and excludes literal values.
- No `eval`, `invokelatest`, `@generated` or RuntimeGeneratedFunctions (ADR-0003 rule 12).

### 3.4 `explain`

`explain(q; kernel = true)` (Task 0b keyword) prints
`kernel: compiled (cached | compiled at collect) | interpreter (why)`, from `kernel_decision`.
By default the line is not printed. The line depends on the session cache, and printing it
always would make the existing goldens depend on test order. The rendered-kernel section and
`code_lowered` are unchanged (rule 13). p4-codegen tests the line with `occursin` under
`withforce`, not with goldens.

### 3.5 Tests

A property test runs generated stages through both the compiled kernel (forced) and the
interpreter. It compares:

- results, exactly (elementwise results are bitwise equal);
- `typeof(col)` per output column (also on empty morsels);
- exception types on throwing stages (`log.(c.x)` on negatives, `div.(c.a, 0)`, the cross-step
  example above, and a throwing scalar subexpression on a morsel whose rows are all filtered
  out).

It asserts that the before/after difference of `_KERNEL_DISAGREE` is 0. The generator includes a
`DictColumn` source with unused levels whose stage is followed by `group_by(drop = false)`
(critic N3).

## 4. Testing

- **lazy == eager (CF-008), extended.**
  - p4-groupby2 **only adds** to the generator (`@testsnippet LazyProp`, in
    `test/lazy/lazy_eager_property_tests.jl`): `group_by ⨟ summarise` (simple and non-simple
    aggregates), grouped windows, `summarise(; by)`, and a `DictColumn` source with unused
    levels under `group_by(drop = false)` (N3). It changes no existing definition there (n8).
  - p4-join adds joins of every kind in the new file
    test/lazy/lazy_eager_join_property_tests.jl. It uses `setup = [LazyProp]` read-only for the
    table generators and comparison helpers, and defines its own `@testsnippet`. That snippet
    holds:
    - the second generated table: shared key columns with NaN, ±0.0, `missing`, duplicates,
      allowed cross-type pairs (`Int32`/`Float64`, `Int32`/`Int64`, `String`/`SubString`) and
      empty tables;
    - **its own raw runner** (critic n8). LazyProp's `run_raw` calls `execute(physical(plan))`
      on a linear plan and cannot run join trees, so the join runner lowers the tree (§1.4) and
      collects the build subplans before executing.

    Cross-file reuse works: `@testmodule Oracle` (`test/engine/oracle.jl`) is used by
    `test/engine/property_tests.jl`.
  - Both run at morsel sizes 1–7, with `withforce(_FORCE_RADIX_SWITCH => 4)` and each
    `_FORCE_JOIN` strategy, at `-t 1` and `-t 4`. They compare with approximate frame equality
    and also compare exception types.
  - A Source whose partitions carry **permuted dictionaries** is included for the sink (M6).
- **Oracle:** `test/engine/oracle.jl` gains a nested-loop join reference (row loops, rule 8
  equality, dplyr order, `multiple`, `unmatched`), used by the join property tests.
- **Differential:** joins against dplyr (`Rscript`, dplyr 1.2.0) and DuckDB/Polars (`uv`,
  pinned as in the existing suite) on generated data that includes `missing`, NaN, ±0.0,
  duplicates and empty inputs. DuckDB's and Polars' null-key semantics differ (the
  `na_matches = :never` equivalent). That is recorded as an encoded divergence in the new file
  docs/research/differentials-joins.md (created by p4-join). Grouped summaries already have
  differential coverage, and the new operator runs under it.
- **Unit:**
  - per accumulator against the protocol (§2.3);
  - radix stability;
  - the switch at 4 groups with `First`/`Last`/`ReduceM(string *)`;
  - each join kind × `na_matches` × `keep` × `multiple`/`unmatched`;
  - filter pushdown, fires and does not fire (§1.3);
  - name-map stability under projection (M3);
  - tree-printing snapshots;
  - kernel whitelist, cache-lock and fallback cases.
- **JET/Aqua** stay clean. Each lane checks its hot loops with `@test_opt` on concrete inputs in
  its own new file: test/jet/opt_groupby.jl (p4-groupby, then p4-groupby2), test/jet/opt_join.jl
  (p4-join), test/jet/opt_kernels.jl (p4-codegen). `runjet.jl` includes them (Task 0b).

## 5. Benchmarks and budgets (ADR-0022)

- New `SUITE` entries with budget rows for 1.13 and 1.10:
  - group-by (Int key, String key, dictionary String key, two-column key; 10 and n ÷ 10 groups)
    at 10⁴/10⁶ rows, eager and lazy;
  - joins (inner, left; 1:1 and 1:n; broadcast and partitioned) at 10⁴/10⁶ rows;
  - a compiled streamed stage at 10⁶ rows;
  - the `n=10` per-verb rows for `group_by` (rule 3) and for each join verb.
- New directory benchmark/compare/ (not in `SUITE`): db-benchmark-like groupby q1–q5 and join
  q1–q3 at 10⁷ rows (10⁶ as the fallback when memory or time does not allow, recorded), against
  the current path (main), DataFrames.jl, Polars and DuckDB (`uv` only). The other brief
  comparators (data.table, dplyr, Tidier.jl, pandas; docs/agent/BRIEF.md "Benchmarks") are
  deferred to phase 7, "Docs and the benchmark report". The table, with wins and losses, goes into
  the new file docs/research/performance-phase4.md and into `docs/src/performance.md`.
- **Calibrated constants:** p4-bench calibrates `RADIX_SWITCH` (`src/engine/hashagg.jl`) and
  `BROADCAST_MAX_ROWS`/`BROADCAST_MAX_BYTES` (`src/engine/join.jl`) and records the measurements
  in its research doc. It then changes **only those constant lines**. Its lane scope lists the two
  files, and the reviewer checks that the diff in them is those lines only. `INTERP_THRESHOLD` is
  set by p4-codegen (§3.1).

## 6. Not in this phase

`nest_join` and inequality/rolling joins (unless ★ K3 says otherwise), join reordering, spilling,
async I/O, `source_ordering`-based sort skipping, filters past total `mutate`s, partially
compiled stages (a compiled prefix before a non-whitelisted step), and building on x (unless
★ K2 picks option B).

## 7. Revisit triggers

- p4-bench measures a small-x/large-y join more than 2× slower than DuckDB → reopen K2.
- `_KERNEL_DISAGREE` is ever non-zero in CI → the kernel is wrong; fall back to the interpreter
  by default until it is fixed.
- A lane needs to change a frozen signature (§2.2, §2.4) → spec amendment before the change.

## 8. Review log

Critic (REJECT, at b161ce6) and reviewer (REQUEST CHANGES, seam), answered 2026-10-26.

| Finding | Answer | Where |
|---|---|---|
| critic B1 pushdown ignores `multiple`/`unmatched` | fixed: totality rule, no push to y unless `:all`, does-not-fire cases | §1.3, §1.6 |
| critic B2 short-circuit / exception type | fixed: no short-circuit, interpreter re-run on any exception, whitelist, type check, cache lock | §3.1–3.3 |
| critic B3 join needs groupby keys/radix | fixed: phases A/B/C, frozen API | §0.2, §2.2, §2.4 |
| critic M1 right/full tail, shared BitVector | fixed: hidden y-row column + `JoinTailStep` in `rest`; no execute.jl change | §1.2 |
| critic M2 scope gaps | fixed: plan table (lazy_tests, snapshots, LazyProp, test/jet, docs, parity-dplyr, forcing Refs, verbs/interpreter, constants) | plan "Lanes"; §0.1, §0.3, §3.4, §5 |
| critic M3 projection changes join names | fixed: `JoinNames` at construction; clashing columns kept | §1.4 |
| critic M4 dplyr facts | fixed: keep suffixes both keys, full has no `unmatched`, right checks x, `isequal`/`hash` + `promote_type`, 2⁵³ caveat; `_x`/`_y` kept as a divergence | §1.1, §1.6 |
| critic M5 specialised == protocol false for floats | fixed: eager unchanged per-group Base call; typed accumulators only in the sink, tolerance; `add_sum` type; Int8/Int32/Bool/Float32 tests | §2.1, §2.3 |
| critic M6 per-morsel dictionaries | fixed: global value-keyed remap; permuted-dictionary test | §2.3, §4 |
| critic M7 ADR deviations | (i) DataAPI methods added; (ii) build side/partitioning and parity rows PENDING ★ K2/K3 | §0.4, §1.1, §1.2, §1.5 |
| critic M8 no forcing mechanism | fixed: three `Ref`s + `withforce` snippet | §0.3, §0.1 |
| minor: key-predicate copy rationale | fixed: never copied to y; `signbit` guard test | §1.3 |
| minor: `est_rows === nothing` | fixed: unknown ⇒ compile only when cached | §3.1 |
| minor: shape key `typeof(f)` | fixed | §3.3 |
| minor: cache lock | fixed | §3.3 |
| minor: whitelist; ProbeStep renders "none" | fixed: whitelist; explain prints "not rendered (join probe)" | §3.2, §1.4 |
| minor: unmatched-side `Union{Missing}` static or dynamic | static by kind | §1.1 |
| minor: simple-aggregate list vs ReduceM test | fixed: defined by `_aggregator`, includes reduce/mapreduce/sum(f,x)/extrema | §2.1 |
| minor: `var`/`std` n ≤ 1 | `missing` preserved (`Spread`) | §2.3 |
| minor: sink gaps (computed keys, `drop`, raw first-seen key, mixed radix modes) | fixed | §2.1, §2.2, §2.3 |
| minor: DataFusion 4 MiB is input bytes | fixed wording (UNVERIFIED, p4-bench rechecks) | §1.2 |
| minor: `@info` repeats | once per application of the step; never in optimize/collect/replay. Not "per construction": x is unknown then | §1.1, §1.4 |
| minor: `JoinNode` `==` | fixed | §1.4 |
| minor: `Vector{Any}` accumulators | typed per aggregator; `Vector{Any}` only for MapM/ReduceM | §2.3 |
| minor: `_x`/`_y` suffix divergence | kept, recorded in parity-dplyr.md | §1.1 |
| minor: benchmark comparators | deferred to phase 7 (brief) | §5 |
| minor: ADR-0022 rule 3 | `n=10` rows for group_by and joins | §2.1, §5 |
| reviewer B1 check_docs stale refs | fixed: future paths written without backticks | whole spec and plan |
| reviewer M1–M4 (seam code) | fixed in c41343b (not in this file scope) | §0.1 |
| reviewer M5 docs owners | p4-join owns docs/src/api.md and lazy.md; groupby/codegen docs at integration | plan "Lanes" |
| reviewer M6 sink cannot sit behind `run_rest` | p4-groupby2 restructures the morsel loop in execute.jl; every morsel still goes through `_runstage(..., kernel)` | plan task 5 |
| reviewer M7 "empty files" wording | fixed | §0.1, plan Task 0 |
| reviewer M8 dod items | Task 0b item 4 | §0.1 |

Critic pass 2 (ACCEPT WITH CHANGES, at 7521667 + ddf42b8), answered 2026-10-26. The pass-1 M4
row's "`promote_type` + 2⁵³ caveat" is replaced by N1 (Int64/Float64 is now rejected).

| Finding | Answer | Where |
|---|---|---|
| settled: runjet.jl seed-once; TestItemRunner sequential | both UNVERIFIED marks removed; Task 0b marked done (ddf42b8) | §0.1, §0.3 |
| N1 key-type rule | identical / both strings (unified to `String` as `vcat_columns`→`column`) / lossless BitInteger-IEEEFloat-Bool promotion, else `ArgumentError`; Date/DateTime, Int64/UInt64, Int64/Float64 rejected; `isequal` ⇒ equal `keyhash` test | §1.1, §2.2 |
| N2 key predicate under promotion | push to x only when `nonmissingtype(promote_type(Tx, Ty)) === nonmissingtype(Tx)`; 2⁵³ and Int32/Float64 must-not-fire cases | §1.3 |
| N3 compiled kernel loses column kinds | pass-through/filtered columns keep the column object (`take`); computed columns wrapped as the interpreter does; probe check compares `typeof(col)`; DictColumn + `drop = false` in generators | §3.2, §3.3, §3.5, §4 |
| N4 lazy `Mean` overflow | `Mean` accumulator `(typeof(float(x)), Int)` as `UP.Mean`; only `Sum` uses `add_sum`; `typemax(Int)` test (eager `mean` gives 9.223372036854776e18, checked) | §2.3 |
| n1 `InterruptException` | rethrown at once, no re-run | §3.3 |
| n2 scalar-only subexpressions | evaluated once per morsel, also with no rows left | §3.3, §3.5 |
| n3 unchosen y rows | unmatched under `multiple ≠ :all`; `:any` = `:first`; verified with dplyr 1.2.0 | §1.1, §1.6 |
| n4 raw first-seen key | parallel `rawkeys[id]` vector kept by the caller | §2.2 |
| n5 slot rule | frozen home slot `h & (cap - 1)` (low bits; partitions use high bits) | §2.2 |
| n6 abstract join keys | `ArgumentError` naming the column; `Dict` fallback documented as later work | §1.2 |
| n7 `_KERNEL_DISAGREE` | atomic counter; tests assert the before/after difference is 0 | §3.3, §3.5 |
| n8 `run_raw` cannot run trees | p4-join writes its own runner; p4-groupby2 only adds to LazyProp | §4 |
| n9 `@info` vs collect-time resolution | one rule: logged once when `JoinNames` are resolved, collect-time resolution included and documented | §1.1, §1.4 |
| n10 hidden-column collision; `cross_join` | a user column named `##chui_yrow` → `ArgumentError`; `cross_join` defined under K3-A | §1.2, §1.5 |

p4-groupby review (APPROVE WITH CONDITIONS, at 657cdaa), spec amendments by the sub-lead:

| Finding | Answer | Where |
|---|---|---|
| M1 `Union{}` (all-missing key) in the pair rule | pairs with any type; fixed in the lane | §1.1 |
| OQ1 `_lossless_key_promotion` location | `src/engine/hashagg.jl`; p4-join calls it | §1.1 |
| OQ2 string keys keep their type | `StringView` keys kept; hash agrees with `String`; the join builds the `String` output | §1.1 |
| OQ3 dictionary codes | `UInt32`, 0 = `missing` | §2.2 |
| OQ4 re-canonicalisation | `getorinsert!`/`lookup` canonicalise `k` | §2.2 |
| OQ5 / m4 / m6 radix bounds and wording | `p <= 20`, `ntasks >= 1`, memory bound, prefix order | §2.4 |
