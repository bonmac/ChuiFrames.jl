# ADR-0003: One plan-based engine runs both modes: rule passes, a narrow cost stage, push-based morsel pipelines

- **Status:** Accepted (2026-10-20, user at the ChuiFrames phase-1 ★)
- **Date:** 2026-10-20
- **Deciders:** the user, at the phase-1 ★ checkpoint
- **Scope:** ChuiFrames.jl

## Context

The brief asks for:
- one engine shared by lazy and eager mode;
- rule-based rewrites expressed with ChuiCore's recursion schemes, then cost-based ones (as in Calcite);
- morsel-driven multicore execution, async I/O through ChuiTypes effects, spilling, and a
  distributed prototype (evaluating Dagger.jl, Distributed.jl and Arrow Flight);
- hash joins, broadcast or shuffle;
- a fast group-by with typed keys and radix partitioning;
- generated code per fused stage, with an interpreter for small inputs.

The prototype already runs logical → optimized → physical → execute, with `explain`/`code_lowered`
(DESIGN §3.7, §3.9). The frame contract promises lazy == eager, including sorted group output and
the same exception type (CF-008). ChuiCore owns four things here (ecosystem ADR-0002):
- the aggregation protocol (CC-004);
- the ordering obligation for non-commutative aggregators (CC-005);
- empty-input semantics (CC-006);
- transducers and recursion schemes. These two are PROVISIONAL and unreleased.

Measured facts ([engine.md](../research/engine.md); Apple M3 Pro, Julia 1.13.2, `-t 4`, a shared
machine, so compare ratios within a run):
- **Prototype.** Its review checks pass on the copy. Its group-by spends 84% of samples in
  `groupindices` (`Dict{Any}`) (EN-01 to EN-03). Its interpreter costs about 14 µs per step:
  1.38 µs/row at 100 rows vs 41 ns/row at 1M rows, for 10 steps (EN-03).
- **Group-by, 10M rows.** Typed keys are 3–3.6x faster than `Dict{Any}`. Thread-local tables
  plus a merge win at 1k groups (0.019 s), and lose 7.8x at 1M groups. Radix partitioning wins at
  1M groups (0.075 s vs 5.64 s for the prototype) and loses 3.4x at 1k groups (EN-05). Polars and
  DuckDB timings are in EN-06 (not like-for-like).
- **Code generation.** Compiled kernels are 6–8x faster per row than the interpreter. Closures
  and `@generated` compile once per plan *shape*: 3–18 ms per new shape, and at depth 50, 0.047 s
  for closures vs 0.63 s for `@generated`. RuntimeGeneratedFunctions and `eval` with inlined
  literals recompile on every new constant, and RGF takes 1.74 s at depth 50. `eval` needs
  `invokelatest` (EN-07 to EN-09).
- **Optimizers** (Calcite, DuckDB, Polars, DataFusion) are ordered rule passes plus a narrow cost
  step. Metatheory.jl takes seconds on first use (EN-10, EN-11). Morsels are about 100k rows
  (Leis et al. 2014). Push pipelines end at sinks (DuckDB). There is no registered Julia Arrow
  Flight client; gRPCClient.jl exists, and so does an unregistered fork with Flight support
  (EN-12).
- **Exceptions and tasks.** An exception inside a `Threads.@spawn` task reaches the caller as
  `TaskFailedException`, or `CompositeException` under `@sync`. On 1.10.12, Base's
  `maximum(Float64[])` throws `MethodError`, not `ArgumentError` (LC-06; E-34).

## Decision

**Plans and modes**
1. **One plan IR, two entry points.** Every verb is a `Step` value (CF-007). Applied to a lazy
   query, it appends to a logical plan (a tree: joins and set operations have two inputs).
   Applied to a frame, it **must** run through the same physical operators at once, with the
   optimizer off.
2. **Eager fast path.** Below a row threshold (initially 65 536 rows, one morsel), eager
   execution **must** run on the calling task with the interpreter: no task spawn and no
   compilation. Phase 2 measures the per-verb overhead, and the performance ADR sets its budget.
3. **Grouped frames.** `group_by` on a frame materializes a **group index**: dense group ids per
   row, plus the key values sorted ascending. A grouped frame carries it. A grouped `mutate`
   (window) runs through the **grouped-window operator**: evaluate per group on views, then
   scatter back in row order. Grouped `summarise` reuses the index. In a lazy plan, a grouped
   summary is a hash-aggregate sink. A grouped window is a **grouped-window sink** (rule 5): it
   materializes its input, builds the group index, evaluates per group and scatters the results
   back in row order.

**Optimizer**
4. **Ordered rule passes, then a narrow cost stage.**
   - The rule passes are filter splitting, predicate pushdown, projection pushdown / dead-column
     elimination, limit pushdown, constant folding and partition pruning. Each **must** preserve
     results, including NaN/`missing` statistics and filters moved past `select` (prototype
     regressions 7 and 8).
   - Each pass is a rewrite of the plan tree to a fixpoint over a **plan functor**
     (catamorphism, anamorphism or paramorphism-style traversals). Until ChuiCore releases
     its recursion schemes, these traversals live behind the internal upstream adapter
     (ADR-0014).
   - A pass that has not reached its fixpoint after 100 iterations stops. The optimizer then
     keeps the last plan, logs the event in `explain`, and a test asserts that the event never
     happens on generated pipelines.
   - Every rule that fires is logged for `explain`.
   - **Barrier.** A `filter` whose predicate type is abstract (ADR-0002 rule 11) is an
     optimizer barrier:
     - no rule splits or reorders its conjuncts;
     - no sibling conjunct drives pruning or source pushdown below it;
     - no other filter moves across it.

     So eager and lazy evaluate its predicate on the same rows and raise identically (CF-008;
     grammar critic `p9.jl` shows splitting hiding a bad value).
   - The cost stage only chooses join order, build side and join strategy, from source
     statistics. Metatheory.jl is not adopted.

**Execution**
5. **Push pipelines over morsels.** A physical plan is a list of pipelines,
   `source → fused operators → sink`. The sinks are the pipeline breakers: hash-aggregate build,
   grouped-window, hash-join build, sort, materialize and write. Aggregate sinks implement
   CC-004, using ChuiCore's instance-value convention (ChuiCore ADR-0001): every protocol call
   names its aggregator (`ChuiCore.combine(agg, a, b)`), and `neutral(agg)` is a fresh value on
   every call. Where a stage is a plain fold, it goes through `ChuiCore.aggregate(agg, xf, parts)`
   (ChuiCore ADR-0003 rule 6).
   - The default morsel is 65 536 rows. The morsel size is a parameter of execution, so tests can
     set it to 1–7.
   - Work runs on `Threads.@spawn` tasks, each assigned **a contiguous range of morsels**.
   - Task results go into concretely typed containers (EN-05's `Vector{Any}` pitfall).
6. **Order (CF-008, CC-005).**
   - **Only `isstateless` stages run per partition** (ChuiCore ADR-0003 rule 4, accepted
     2026-10-20). `ChuiCore.isstateless` is fail-closed, so a fused stage is parallel only if
     every transducer in it opts in (`Map`, `Filter`, `MapCat`). A stage holding a row limit
     (`Take`), a scan or any other stateful step runs **sequentially** through `foldxl`, as the
     prototype did after regression 2. The engine must never run such a stage per partition, even
     when the stage looks safe.
   - Materialized output **must** be gathered in morsel-index order. Parallel folds use
     ChuiCore's `foldparts`/`foldxt`, with an explicit `merge` that merges in partition order.
   - A row limit is applied in that sequential stage, in morsel order, and stops the scan early.
     The exception: below a `filter` whose predicate type is abstract (ADR-0002 rule 11), the scan
     **must not** stop early, so both paths see, and can raise on, the same rows.
   - For a non-commutative aggregator (`First`, `Last`, order-dependent `ReduceM`), accumulators
     **must** be combined in morsel-range order. A grouped table holding such aggregators
     **must** be built per contiguous range, never from interleaved morsels.
   - The radix scatter **must be stable**: it writes through prefix-summed offsets in
     (task range, morsel) order, so each partition keeps global row order.
   - A grouped summary's rows are sorted ascending by the group keys, on both paths.
7. **Exceptions.** The executor **must** unwrap `TaskFailedException` and `CompositeException`.
   It rethrows the original exception of the first failing morsel, in morsel order. A failure in
   range *k* cancels only the ranges after *k*; earlier ranges run to completion, so the reported
   exception is the one a serial run would raise. Every
   reduction, on every path, goes through the adapter's aggregators (CC-006/CC-007 exception
   types), never through Base reductions directly. So `maximum` over an empty group is an
   `ArgumentError` on 1.10 and 1.13, in both modes.

**Group-by and joins**
8. **Key equality.** It applies to **every key-based operator**: group-by, joins, `distinct`,
   `count_by`, `n_distinct` and the `_rows` set verbs. Keys follow `isequal` semantics, with two
   exceptions:
   - NaN is canonicalised before hashing, so `NaN` and `-NaN` fall in one group;
   - `-0.0` and `0.0` hash and compare equal, so they form **one** group, as in dplyr's
     `group_by` (grammar critic `r4.R`). The key shown is the **first one seen in row order**,
     as in dplyr, tracked with the same order stamps as `First`;
   - `missing` is its own group.

   The test oracle implements these two exceptions explicitly. Base `Dict`/`unique` follow plain
   `isequal` and would split ±0.

   Keys are one typed column or a tuple of concrete types. Dictionary codes are grouping keys only
   after the partitions' dictionaries are **unified**, or the codes are remapped per partition.
   Output order follows the values, not the codes.
9. **Adaptive group-by strategy.** Execution starts with thread-local open-addressing tables. A
   table that passes a size limit switches to radix partitioning, as DuckDB does (initial limit:
   2¹⁶ groups per table, calibrated in phase 4). When a source reports distinct counts
   (ADR-0004), execution may start with radix partitioning directly. **At the switch**, the table
   **must** be flushed into the radix partitions as accumulators stamped with (range, sequence),
   ahead of any later rows. Each partition then combines a group's accumulators in that order,
   which keeps CC-005 for `First`, `Last` and `ReduceM`. A test forces the switch at a tiny
   limit (4 groups) with those aggregators.
10. **Radix partitioning is one primitive**, reused by many-group aggregation, partitioned hash
    joins and spilling.
11. **Joins** are hash joins. A broadcast join (one shared build table) is used when the
    estimated build side is under 128k rows / 4 MiB (DataFusion's defaults, recalibrated in
    phase 4). Otherwise both sides are radix-partitioned. Join keys follow rule 8's equality,
    so `missing` matches `missing` by default, as in dplyr (`na_matches = "na"`). DuckDB does
    not match nulls by default. The differential suites record that as an expected divergence,
    and a `na_matches = :never` option matches DuckDB. Dictionary-encoded keys from two
    different frames are unified before codes are compared.

**Code generation**
12. **Shape-keyed kernels.** Each fused stage compiles into one kernel by composing closures,
    with literals held as runtime values, and is cached by plan shape for the session.
    - The interpreter runs when the stage's shape is not compiled yet **and** the estimated rows
      are below 10⁵, or when the stage is deeper than 50 (the deepest chain measured, EN-08).
    - Why 10⁵: compiling a new closure shape costs 3–9 ms for a two-operation stage (EN-07)
      and 18 ms at depth 20 (EN-08). Against the prototype interpreter's 41 ns/row for 10 steps,
      that breaks even between about 0.7×10⁵ and 4.4×10⁵ rows. 10⁵ is the conservative end.
      Phase 4 recalibrates it.
    - `eval`, `invokelatest` and RuntimeGeneratedFunctions are not used: they recompile per
      literal unless restructured, and RGF compiles slowly at depth.
13. **`code_lowered(q)`** prints the CodeInfo of a **rendered** kernel: a Julia function
    expression generated from the fused stage and lowered with `Meta.lower`, as the prototype
    does. A closure kernel's own lowered code is the same generic loop for every plan (probe
    P3). `explain` labels this section "rendered kernel". A property test over generated
    stages runs the rendered expression (in the test process only) and checks it gives the same
    result as the closure kernel. `explain` keeps the prototype's four sections, plus
    the rules fired, the strategies chosen and the pruning counts. The output is snapshot-tested
    on stable Julia.

**Upstream, I/O, scale**
14. **Upstream names.** Transducers, aggregators and recursion schemes are used only through the
    internal upstream adapter (ADR-0014), never through Transducers.jl.
15. **Asynchronous I/O and cancellation** go through the internal effects adapter (ADR-0015).
    Cancellation is cooperative: a cancelled query sets a flag that tasks check between
    morsels. The flag cannot interrupt a `read_partition` call that is blocked on a slow HTTP or
    S3 read, so remote sources **must** take a read timeout.
16. **Out-of-core** (phase 5): a radix partition over the memory budget is spilled to an Arrow
    IPC stream file, written through the Arrow.jl writer adapter and read back by ChuiFrames'
    own IPC reader (ADR-0001 rules 10–11), with one dictionary per spill file. Sort runs spill
    the same way.
17. **Distributed** (phase 5): the brief's distributed prototype is built in phase 5. That phase
    evaluates Dagger.jl, Distributed.jl and Arrow Flight (through gRPCClient.jl or the
    unregistered fork) in a research note before it chooses. Each is a package extension, not a
    core dependency. Substrait export is not planned: no Julia implementation exists.

**Phases**
18. **Phasing.**
    - Phase 2 builds the column types, the physical operators for single-table verbs, the
      grouped-window operator, the interpreter and eager execution, single-threaded.
    - Phase 3 adds the lazy entry point, the rule passes, morsel parallelism and pushdown.
    - Phase 4 adds radix partitioning, joins, codegen and the calibrated thresholds.
    - **Brief deviation (★):** the brief lists parallel execution under phase 5. This ADR moves
      morsel parallelism to phase 3, because lazy == eager must be tested on the parallel paths
      from the start. Phase 5 keeps async I/O, out-of-core and the distributed prototype.
      The user approved this deviation at the phase-1 ★ on 2026-10-20.

## Alternatives rejected

| Alternative | Why rejected |
|---|---|
| Separate eager implementations (as in the prototype) | Two code paths to keep correct. The prototype's lazy and eager element types already diverge (DESIGN §6). The oracle in "Testing" replaces the cross-check. |
| Volcano-style pull iterators | One virtual call per row. Morsel push pipelines are the measured norm (DuckDB; Leis et al.). |
| Full cost-based search with e-graphs (Metatheory.jl) | Seconds of first-use latency (EN-11). The engines surveyed use cost only for join order and build side. |
| `Dict{Any}` grouping (prototype) | 14–75x slower than the measured alternatives (EN-05). |
| A single group-by strategy | Thread-local tables lose 7.8x at 1M groups; radix loses 3.4x at 1k (EN-05). |
| Dynamic per-morsel task scheduling | Interleaves morsels inside one accumulator, which breaks CC-005 for `ReduceM` (critic probe P5: `125634` vs `123456`). |
| RuntimeGeneratedFunctions / `eval` codegen | Recompiles per literal as measured, needs `invokelatest` (`eval`), and RGF takes 1.74 s at depth 50 (EN-07 to EN-09). |
| `@generated` kernels | Its lowered body would serve `code_lowered` directly, but it compiles 13x slower than closures at depth 50 (EN-08). |
| Always compile, no interpreter | 3–18 ms per new shape dominates small queries (EN-07). |
| Transducers.jl, OhMyThreads or Dagger in the core | Ecosystem ADR-0002 §4 for transducers. `Threads.@spawn` with contiguous ranges needs no scheduler library. Dagger is a phase-5 extension candidate. |

## Testing (binding on phases 2–4)

- **Oracle.** The CF-008 property tests compare against an independent reference evaluator in
  the test tree. It uses row loops and Base functions, with no optimizer and no threads. It
  shares only the expression AST and CC-007's exception table with the engine. Where a Base
  reduction throws on empty input, the oracle maps the error to the type that table names. On
  1.10.12, Base's `maximum(Float64[])` throws `MethodError` (LC-06).
- **Statistics pruning and NaN** are decided in ADR-0004 rule 3, and tested here: generated
  float partitions with NaN plus negated and `.!=` predicates.
- **Coverage of the parallel paths.** Generated pipelines run with morsel sizes 1–7, with each
  group-by strategy and join strategy forced in turn. CI runs them at `-t 1` and `-t 4`.
- **Generated data** includes NaN, `-NaN`, `±0.0`, `missing`, empty groups, permuted
  per-partition dictionaries, and `ReduceM(string *)`.
- **Exception types** are checked under threads on both Julia versions.
- **Supposition** (ecosystem ADR-0007 §2 as amended at the ChuiCore ★, 2026-10-20). The LTS job
  carries one planted violation, which must fail, to prove that failures are recorded. Property
  tests use `@check record=false db=false` (a database written under 1.13 crashes 1.10) plus an
  explicit `@test` on the
  result: on Julia 1.10.12, Supposition 0.3.5 does not record a failing `@check` inside
  `@testset` (finding reported by the lead, 2026-10-20).
- **CI change:** the test job gains a `-t 4` run. CI workflows are a T3 path (`risk.toml`), so
  the user approves this change when it is made.

## Consequences

- Phase 2's scope grows by the operator layer and the group index (rule 18). In exchange, no
  eager code is thrown away later.
- `chui-frames.md` should gain a note that `code_lowered` shows a rendered kernel (a coordinator
  change through the lead).
- Requests to ChuiCore: a recursion-scheme API that fits a plan functor (including a
  paramorphism), and the transducer substrate (drafted in the phase report).
- A performance-budget ADR is still owed: target ratios per benchmark family, the eager per-verb
  overhead and TTFX.

## Verification

- EN-01 to EN-12 in [engine.md](../research/engine.md).
- LC-06 in [lane-checks.md](../research/lane-checks.md): the critic's probes P1 to P5, with
  their script and output, run on Julia 1.13.2 and 1.10.12.
- UNVERIFIED: codegen beyond depth 50 and on multi-column or string stages; group-by with
  multi-column, string or `missing` keys; timings on an idle machine; DuckDB's operator interface
  names; the 2¹⁶ switch limit (not measured).

## Revisit when

- Phase-4 benchmarks put a threshold far from its starting value.
- ChuiCore's recursion-scheme or transducer API differs in shape from rules 4 and 14.
- A registered Arrow Flight client or Julia Substrait library appears.
- Julia's LTS moves to ≥ 1.11.
