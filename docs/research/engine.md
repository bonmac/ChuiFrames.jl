# Research: query-engine architecture

**Question.** What should the ChuiFrames engine be built from? This note covers what the
prototype really does and costs, how fast a typed and radix-partitioned group-by is in plain
Julia compared with Polars and DuckDB, which code-generation strategy suits fused stages, how
mature optimizers are organised (and whether Metatheory.jl is usable), and which execution and
distribution building blocks exist in Julia today. This is the evidence for the engine ADR
([BRIEF](../agent/BRIEF.md), "Engine" bullets and phase 1). It contains no decisions.

- **Date:** 2026-10-20.
- **Versions:**
  - Julia 1.13.2 (`-t 4`), with 1.10.12 LTS for the compatibility checks.
  - Polars 2.0.0, DuckDB 1.5.6, NumPy 2.5.4, run through `uv run --python 3.13`.
  - RuntimeGeneratedFunctions 0.5.27, Metatheory 2.1.0.
  - The prototype's I/O environment: Arrow 2.8.1, Parquet2 0.2.37, Tables 1.14.0.
- **Hardware:** Apple M3 Pro, 12 cores (`hw.ncpu`), 18 GiB RAM, macOS (Darwin 25.6.0).
  - **Caveat:** the machine was heavily shared while these numbers were taken. `uptime` load averages ranged from 19 to 65 on 12 cores (EN-05, EN-07).
  - Absolute times are therefore noisy, and repeated runs differed by up to 2x. Ratios within one run are more reliable than absolute times. Every table gives the median and the min–max.
- **Method:**
  - The prototype was copied (`cp -R`) into the session scratchpad and run there, never in place.
  - All other benchmark code is new scratch code, not part of the repo.
  - Polars and DuckDB read the very same binary arrays that Julia wrote.
  - The literature and documentation survey was delegated to one helper lane. Its sources are cited inline with their version or commit.

Upstream contracts the engine may rely on ([chui-core contracts](../../test/contracts/chui-core.md)):

- **CC-004:** the aggregator protocol `init` (a factory), `partial`, `combine`, `final`.
- **CC-005:** `iscommutative`. Non-commutative aggregators are combined in partition order, and any shuffle must carry an order key.
- **ADR-0002 (coordinator):** ChuiCore owns the transducer substrate and the aggregation protocol, and ChuiFrames must not redefine them.
- **Not released yet:** the transducer API and recursion schemes are PROVISIONAL, so the engine reaches them only through an internal adapter.

---

## 1. Prototype facts

### 1.1 Check scripts on Julia 1.13.2, `-t 4` (EN-01, EN-02)

| Script | Result | Wall time (incl. compile) |
|---|---|---|
| `demo.jl` | runs; prints `lazy == eager: true   lazy 1.119s vs eager 2.988s` | 35.5 s |
| `review/fixcheck.jl` | `all fix checks passed` | 23.6 s |
| `review/optcheck.jl` | all 6 `@test`s pass; rules logged (split filter → 2 conjuncts, both pushed into the scan, dead column `junk` dropped) | 36.3 s |
| `review/nancheck.jl` (needs the I/O env) | `nan + select checks passed` | 56.2 s |

- **Not run:** the 150 MB Parquet regeneration in `io_demo.jl` and `explaincheck.jl`.
- **Instantiating the copied I/O environment on 1.13 (EN-02):**
  - Precompiling 33 dependencies took 176 s, of which Parquet2 alone took 112.7 s.
  - Pkg warned that the manifest was resolved for different compat. It was resolved on 1.11.
- **Demo timing:** DESIGN §4 reports lazy at 0.20–0.25 s vs eager at 0.76–0.89 s on 1.11.7. This run on a loaded machine gave 1.12 s vs 2.99 s.
  - The lazy-to-eager ratio is similar (about 2.7x). The absolute times are not comparable.

### 1.2 Group-by on 2M rows / 10k groups (EN-03)

The query is `group_by(:k) ⨟ summarise(s = sum(c.a), m = mean(c.b))`, with integer key `k` in 1:10_000. It ran in two separate processes, 3 runs each:

| Measure | Process 1 median [min, max] | Process 2 median [min, max] |
|---|---|---|
| eager `group_by`+`summarise` | 3.648 s [3.202, 4.144] | 5.304 s [5.103, 5.682] |
| lazy (two-phase HashAggregate, 4 tasks) | 3.386 s [2.548, 4.932] | 3.936 s [3.223, 3.958] |
| `groupindices` alone | 2.915 s [2.785, 3.011] | 5.889 s [2.199, 5.973] |

- `@time` of the eager query reported `3.33 s (10.56 M allocations: 275.119 MiB, 11.40% gc time)`.
- `Profile` (flat, 3 eager runs) gave 6989 samples under the top-level call. Of these:
  - 5846 (84%) are under the `groupindices` call (line 344, `apply(::Tbl, ::SummariseStep)`).
  - Line 263 alone, `push!(get!(Vector{Int}, d, map(v -> v[i], keycols)), i)`, accounts for 3715 samples, with 2054 self.
  - About 10% is `ev(::Call, …)` evaluating the aggregates on per-group views.
- **Confirmed:** DESIGN §6 is right that `groupindices` (a `Dict{Any,Vector{Int}}` keyed by tuples, built row by row) is the bottleneck.
  - The lazy path does not avoid it. `partial_rf` calls `groupindices` once per morsel and then merges the `Dict{Any,Vector{Any}}` accumulators.

### 1.3 Interpreter dispatch overhead (EN-03)

This is a 10-step eager pipeline (7 mutates, 2 filters, 1 select). Each row is the median of 3 batches:

| Rows | Per call, median [min, max] | Per row |
|---|---|---|
| 100 | 138 µs [127, 447] | 1.38 µs |
| 10 000 | 0.68 ms [0.32, 3.84] | 68 ns |
| 1 000 000 | 41.5 ms [38.0, 64.3] | 41 ns |

- Fixed cost is about 14 µs per step: rebuilding the `NamedTuple`, one dynamic `ev` dispatch per node, and a broadcast allocation.
- Per row, the cost at 100 rows is 33x the large-table rate. For small inputs, interpreter overhead dominates; for large inputs, the per-row cost is that of a temporary-allocating broadcast.

---

## 2. Group-by: typed keys and radix partitioning (EN-04 … EN-06)

**Setup.**
- 10M rows, with `k = rand(1:G)` (Int64) and `v = rand()` (Float64). The query is `sum(v)` by `k`.
- Seed 42. 3 timed runs after one warm-up run.
- The results were checked: the group count equals `length(unique(k))`, and the total equals `sum(v)` to an rtol of 1e-9.

**Variants (scratch code):**
- **(a)** The prototype's algorithm: `Dict{Any,Vector{Int}}` with tuple keys, then `sum` over views.
- **(b)** `Dict{Int,Int}` mapping each key to a dense slot, plus a `Vector{Float64}` of sums.
- **(c)** A hand-rolled open-addressing table: linear probing, power-of-two capacity, multiplicative hash, load ≤ 0.5, one thread.
- **(d)** A thread-local table (c) per task, followed by a serial merge.
- **(e)** Radix partitioning:
  - Each task histograms and then scatters `(k, v)` into 64 partitions by the top 6 hash bits.
  - Then one table per partition is built under `@threads :dynamic`.
  - No merge is needed, because the partitions are disjoint.

**Julia, `-t 4` (EN-05, same process, load average about 40–45):**

| Variant | G = 1 000: median [min, max] | G = 1 000 000: median [min, max] |
|---|---|---|
| (a) `Dict{Any}` tuple keys (prototype) | 0.268 s [0.204, 0.329] | 5.639 s [3.717, 6.459] |
| (b) `Dict{Int,Int}` typed | 0.093 s [0.073, 0.100] | 1.547 s [1.494, 1.872] |
| (c) open addressing, 1 thread | 0.060 s [0.055, 0.081] | 0.823 s [0.773, 1.020] |
| (d) thread-local OA + merge | **0.019 s** [0.017, 0.021] | 0.587 s [0.548, 0.715] |
| (e) radix-partitioned, 64 parts | 0.064 s [0.044, 0.176] | **0.075 s** [0.056, 0.123] |
| (c) at `-t 1` | — | 0.707 s [0.413, 0.817] |
| (e) at `-t 1` | — | 0.161 s [0.150, 0.180] |

**Polars and DuckDB on the same arrays, 4 threads (EN-06):**

- Polars ran with `POLARS_MAX_THREADS=4` (`thread_pool_size()` reported 4).
- DuckDB ran with `SET threads=4` on a native table loaded from the arrays.
- Each was timed 5 times after a warm-up run.

| Engine | G = 1 000 | G = 1 000 000 |
|---|---|---|
| Polars 2.0.0 `group_by("k").agg(sum)` | 0.128 s [0.092, 0.188] | 0.341 s [0.300, 0.523] |
| DuckDB 1.5.6 `GROUP BY k` (native table) | 0.012 s [0.009, 0.018] | 0.250 s [0.161, 0.288] |

All engines returned the same group count and total (4.999669e+06).

**Findings.**

1. **Typed keys alone gain 3x at 1k groups and 3.6x at 1M.** This is (b) vs (a). A specialised open-addressing table gains another 1.5–1.9x, (c) vs (b).
2. **Strategy depends on the number of groups.**
   - **Few groups:** thread-local tables plus a merge are best. At 1k groups, (d) is 14x faster than the prototype and close to DuckDB.
   - **Many groups:** radix partitioning is best. At 1M groups, (e) is 75x faster than the prototype, 8x faster than (d), and in this run faster than both Polars and DuckDB.
   - **Why:** each partition's table (about 16k groups) fits in cache. Even single-threaded, (e) is 4.4x faster than (c).
   - **Caveat:** the comparison with Polars and DuckDB is not like-for-like. Those engines materialise a result table and handle general types, and the Julia code is a specialised `Int`/`Float64` sum.
   - This mirrors DuckDB's design: thread-local partitioned pre-aggregation, then aggregation per partition (B7 below).
3. **A Julia pitfall found while measuring.**
   - `fetch.(tasks)` returns `Vector{Any}`. My first version of (d) therefore dispatched dynamically on every merged row and took 4.9 s at 1M groups.
   - Typing the collect (`OATable[fetch(t) for t in tasks]`) fixed it.
   - So the engine's task results need concrete containers or a function barrier.
4. **Partitioning reorders rows, which matters for CC-005.**
   - Partition-wise tables are fine for commutative aggregators (`Sum`, `Count`, `Min`, `Max`).
   - `First`, `Last` and order-dependent `ReduceM` must carry an order key per accumulator (for example the global row index of the first contribution), or fall back to merging in partition order.

---

## 3. Code generation for a fused stage (EN-07 … EN-09)

**Stage.** `sum(mut(x) for x in v if pred(x))` over 10M `Float64`. Plan A is `x > 0.5` and `x*2.0 + 1.0`.
- Plan B has a different shape: `abs(x - 0.3) < 0.2` and `x*x - 1.0`.
- Plan C has A's shape with different constants.
- The plan IR is a tiny expression tree (`X`, `Lit{T}`, `Call{F,Args}`). Each variant ran in a fresh process 3 times, and the tables give the median over those 3 processes.

**Strategies:**
- **(i) Interpreter:** broadcast per node, as in the prototype.
- **(a) Closures:** the tree is compiled into nested closures that capture constants as values. One `@simd` kernel then specialises on the closure types.
- **(b) `@generated`:** a function keyed on the plan *type*. It emits the loop body, and constants stay runtime fields (`s.pred.args[2].value`).
- **(c) RuntimeGeneratedFunctions 0.5.27:** an `Expr` with the literals inlined.
- **(d) `Core.eval`:** the same expression evaluated into a module, then called through `Base.invokelatest`.

| Strategy | First call A | First call B (new shape) | First call C (A's shape, new consts) | Steady 10M rows: median [min, max] | Per row | 100-row query, new constant |
|---|---|---|---|---|---|---|
| (i) interpreter | 0.064 s | 0.074 s | 0.049 s | 14.2 ms [12.2, 28.4] | 1.42 ns | 0.2–0.3 µs |
| (a) closures | 0.009 s | 0.003 s | 0.003 s | 2.4 ms [1.9, 5.4] | 0.24 ns | ≤ 0.1 µs |
| (b) `@generated` | 0.018 s | 0.003 s | 0.003 s | 2.0 ms [1.9, 11.4] | 0.20 ns | ≤ 0.1 µs |
| (c) RGF | 0.087 s | 0.052 s | 0.010 s | 1.8 ms [1.7, 2.3] | 0.18 ns | 8.3 ms |
| (d) eval + `invokelatest` | 0.040 s | 0.064 s | 0.017 s | 2.3 ms [1.9, 3.7] | 0.23 ns | 9.8 ms |

**Compile latency vs stage size** (first call on 1M rows, one process each, EN-08). The mutate is a chain of `d` alternating `+`/`*` with constants:

| Depth d | Closures | `@generated` | RGF |
|---|---|---|---|
| 5 | 0.009 s | 0.101 s | 0.176 s |
| 20 | 0.018 s | 0.288 s | 0.459 s |
| 50 | 0.047 s | 0.630 s | 1.740 s |

**World age (EN-09, run on both 1.13.2 and 1.10.12):**
- A function created by `Core.eval` and called directly from the function that created it fails with `MethodError: no method matching kk(::Vector{Int64})` ("method too new").
- `Base.invokelatest` works.
- 1.13.2 also prints a warning: "Detected access to binding `K.kk` in a world prior to its definition world. Julia 1.12 has introduced more strict world age semantics for global bindings … This code will error in future versions of Julia."
- RGF objects were called directly, with no `invokelatest`, inside the driver function and worked. That is the package's purpose: they define no global binding or method.
- Closures and `@generated` create no new methods, so they have no world-age issue.
- Note that each new `@generated` specialisation, and each kernel specialised on new closure types, is ordinary compilation, cached in the method table.

**Findings.**
1. Every compiled strategy is 6–8x faster per row than the interpreter on this stage. Steady state is within noise across (a)–(d), at 0.18–0.24 ns per row, which is memory-bound.
2. **The key difference is what triggers compilation.**
   - (a) and (b) compile once per plan *shape*, because constants are values. A new query with new literals costs no compilation, and a 100-row query runs in under 1 µs.
   - (c) and (d) inline literals, so every new constant recompiles: 10–17 ms here.
   - (c) and (d) could also pass constants as arguments, which would make them shape-keyed. That variant was not measured.
3. Closures had the lowest compile latency, which grew roughly linearly with depth (47 ms at depth 50). RGF grew steeply to 1.7 s at depth 50.
4. Long fused stages still need a cap on specialisation size, or a fallback. Very deep closure types also risk type-inference limits (UNVERIFIED for depths > 50).

**Threshold idea (not a decision).**
- Break-even rows ≈ compile cost ÷ (interpreter cost per row − compiled cost per row).
- With a 10 ms shape compile and about 1.2 ns/row saved, that gives roughly 8M rows on this simple stage.
- With the prototype's real interpreter cost (41 ns/row for 10 steps, §1.3), break-even falls to about 250k rows.
- If kernels are cached by plan shape, the compile cost is paid once per shape per session. That makes "interpret when the plan shape is unseen **and** estimated rows < N (≈ 10⁵–10⁶), else compile and cache" a reasonable rule to calibrate later, using row estimates from statistics.

---

## 4. Optimizer

### 4.1 How existing optimizers are organised

- **Apache Calcite** (1.42.0, Maven metadata 2026-05-31) has two planner engines.
  - **HepPlanner** "fires a sequence of rules in a more fixed order". Its `HepMatchOrder` can be `ARBITRARY` (the default), `BOTTOM_UP`, `TOP_DOWN` or `DEPTH_FIRST`.
  - **VolcanoPlanner** "uses dynamic programming and is good for exhaustive search". It builds equivalence sets (`RelSet`) and `RelSubset`s that share physical traits, each with a `getWinnerCost()`.
  - Importance-based scheduling was removed in 1.23.0 (CALCITE-3753), and top-down (Cascades-style) optimisation is available through `setTopDownOpt`.
  - Sources: [adapter docs](https://calcite.apache.org/docs/adapter.html), [HepMatchOrder](https://calcite.apache.org/javadocAggregate/org/apache/calcite/plan/hep/HepMatchOrder.html), [VolcanoPlanner](https://calcite.apache.org/javadocAggregate/org/apache/calcite/plan/volcano/VolcanoPlanner.html), [1.23.0 notes](https://calcite.apache.org/news/2020/05/23/release-1.23.0/), and Begoli et al., SIGMOD 2018, [arXiv:1802.10233](https://arxiv.org/abs/1802.10233).
- **DuckDB** runs a fixed sequence of about 48 passes. They were read from `optimizer.cpp` at commit [0b272c23](https://github.com/duckdb/duckdb/blob/0b272c23b19eb7747313fffa0a1097f720905b29/src/optimizer/optimizer.cpp) (2026-10-19). In order, abridged:
  - expression rewriter, CTE inlining, aggregate-function rewrite, filter pull-up, filter pushdown;
  - IN-clause, delim-join elimination, outer-join simplification, join order, partial-aggregate pushdown, join elimination, unused columns;
  - common subexpressions, column lifetime, build/probe side selection, common subplan, limit pushdown, row-group pruner, TopN, late materialisation, statistics propagation;
  - unused columns and column lifetime a second time, filter reordering, partitioned execution, join filter pushdown, type pushdown.
  - Several passes run twice. This is rule-based except for join order and the statistics-driven build-side choice.
- **Polars** 2.0.0 [lazy optimizations](https://docs.pola.rs/user-guide/lazy/optimizations/) runs these passes:
  - predicate, projection and slice pushdown, common-subplan elimination and join ordering, each once;
  - simplify-expressions and type coercion, each until a fixed point;
  - cardinality estimation, 0 to n times.
- `QueryOptFlags` in 2.0.0 exposes `predicate_pushdown`, `projection_pushdown`, `slice_pushdown`, `comm_subplan_elim`, `comm_subexpr_elim`, `simplify_expression`, `cluster_with_columns`, `join_order`, `row_estimate` and others.
- `explain()` output for `filter(x > 10) → with_columns(y2 = y*2) → group_by(g).agg(sum(y2), max(x)) → sort(desc) → head(2)` (EN-10):

```
SORT BY [slice: (0, 2, dynamic_pred: …), descending: [true]] [col("s")]
  FILTER col("s").dynamic_predicate()
  FROM
    AGGREGATE[maintain_order: false]
      [col("y2").sum().alias("s"), col("x").max()] BY [col("g")]
      FROM
      simple π 3/3 ["g", "y2", "x"]
         WITH_COLUMNS: [(col("y") * 2.0).alias("y2")]
          FILTER col("x") > 10
          FROM
            DF ["g", "x", "y", "z"]; PROJECT["g", "x", "y"] 3/4 COLUMNS
```

  The unoptimized plan keeps `SLICE[offset: 0, len: 2]` above `SORT` and reads `PROJECT */4 COLUMNS`. So the optimizer pushed the projection into the scan and turned slice+sort into a top-k with a dynamic predicate.
- **DataFusion** 55.2.0 (crates.io, 2026-10-07):
  - The [docs page](https://datafusion.apache.org/library-user-guide/query-optimizer.html) shows an outdated rule list. The current one comes from source on main (7c918f9854, 2026-10-19).
  - **Logical rules, in order:** SimplifyExpressions, EliminateJoin, subquery decorrelation, EliminateFilter/Limit/CrossJoin/OuterJoin, PropagateEmptyRelation, PushDownLimit, PushDownFilter, SingleDistinctToGroupBy, CommonSubexprEliminate, OptimizeProjections, among others.
  - **Physical rules:** AggregateStatistics, JoinSelection, FilterPushdown, EnsureRequirements (distribution and sort), CombinePartialFinalAggregate, ProjectionPushdown, TopKAggregation, LimitPushdown, SanityCheckPlan, among others.
- **The common shape:** most of each optimizer is a fixed, ordered list of rule passes, some run to a fixpoint. The cost-based part is narrow: join order, build side and physical choices.

### 4.2 Metatheory.jl as the cost-based option (EN-11)

- **Version:** latest registered is 2.1.0, registered 2026-09-17 (General PR #168618).
  - Julia compat is `1.8.0 - 1`, and it depends on TermInterface 0.3.
  - The last GitHub release object is v2.0.2 (2023-11-10). The repo is active and was pushed 2026-10-19.
- **Install and first run:** a scratch environment with an `a*1 → a` rule and commutativity reduced `1 * (x * 1)` to `x`. Both versions reported "saturated, 2 iterations, 2 e-classes, 6 nodes".

  | Julia | Install + precompile | First saturate + extract (incl. compile) |
  |---|---|---|
  | 1.13.2 | 46.4 s | 4.2 s |
  | 1.10.12 | 48.5 s | 2.6 s |

- **Assessment (evidence only):**
  - It works on both supported Julia versions.
  - Its first-use latency is seconds, which is large next to sub-millisecond rule passes.
  - It would be a heavy dependency for the default path.
  - E-graph saturation fits join reordering and algebraic expression rewrites. Plan-level physical choices still need a cost model outside the e-graph's extraction cost function.
  - Not measured: saturation time on realistic plans (joins of 5–10 relations).

### 4.3 Rule-based rewrites as recursion schemes (design sketch, not a decision)

Let the logical plan be the fixpoint of a functor `PlanF{R}`:

```julia
# DESIGN SKETCH, not implemented; names are not ChuiCore's (its recursion-scheme API is PROVISIONAL)
PlanF{R} = ScanF | FilterF(pred, child::R) | ProjectF(cols, child::R) | MutateF(defs, child::R)
         | AggF(keys, aggs, child::R) | SortF(keys, child::R) | LimitF(n, child::R) | JoinF(on, l::R, r::R)
fmap(f, ::PlanF{R})  # applies f to the children only
Plan = Fix{PlanF}
```

- **A local rule** is a partial function `PlanF{Plan} -> Union{Plan,Nothing}`. Examples are filter-past-mutate (when the filter does not use a defined column) and filter merge.
- **One bottom-up pass** is `cata(alg)`, with `alg(n) = something(rule(n), Fix(n))`. This is Calcite Hep `BOTTOM_UP` order.
  - Applying a rule set to a fixpoint means repeating the cata until nothing fires.
  - Each pass reports a "changed" flag, since a catamorphism into `(Plan, Bool)` keeps it pure.
  - The prototype's rule log becomes the `Writer` part of that carrier.
- **Projection pushdown** needs *inherited* (top-down) information: the columns required by the parents.
  - As a cata, its carrier is a function, `Set{Symbol} -> Plan`.
  - Equivalently, it can be an `ana` driven by required columns.
  - The prototype's backward liveness pass is exactly this.
- **Predicate pushdown** that moves a node past its child is easiest as a `para`, because the rule must see the child's original subtree as well as its rewritten form.
- **Statistics and cost estimation** are a cata into `(rows, distinct counts, min/max, cost)`. The same pass can annotate the physical plan.
- **Cost-based search** (join order) is a separate stage over a memo or e-graph, entered after the rule fixpoint.
  - This matches Calcite's Hep-then-Volcano layering and DuckDB's "rules, then join order with statistics".
- Because the recursion-scheme API is PROVISIONAL, the engine would call it through an internal adapter, as the brief requires.

---

## 5. Execution

### 5.1 Morsels, pipelines, breakers

- **Morsel-driven parallelism** (Leis, Boncz, Kemper, Neumann, SIGMOD 2014, pp. 743–754, [doi:10.1145/2588555.2610507](https://doi.org/10.1145/2588555.2610507), [pdf](https://db.in.tum.de/~leis/papers/morsels.pdf)):
  - Workers "run entire operator pipelines until the next pipeline breaker".
  - "A morsel size of about 100,000 tuples yields good tradeoff between instant elasticity adjustment, load balancing and low maintenance overhead."
  - The degree of parallelism "is not baked into the plan".
  - The dispatcher is NUMA-aware and steals work. The prototype's default morsel is 65 536 rows (`collect(...; morsel = 65_536)`), which is in the same range.
- **DuckDB** uses push-based pipelines (Raasveldt, "Push-Based Execution in DuckDB", DSDSD 2021-11-26, [talk](https://duckdb.org/library/push-based-execution-in-duckdb/)).
  - Each pipeline is source → operators → sink. The sink is the breaker (hash-aggregate build, hash-join build, sort), with Sink, Combine and Finalize steps.
  - The operator interface details come from secondary sources ([CMU 15-721 slides](https://15721.courses.cs.cmu.edu/spring2023/slides/22-duckdb.pdf), [arXiv:2502.15181](https://arxiv.org/pdf/2502.15181)) and are UNVERIFIED against DuckDB source.
- The prototype already has this shape. The fused `*(1)` stage is a pipeline, and the `HashAggregate` (partial → merge → final) is a breaker whose Combine is CC-004 `combine`.

### 5.2 Julia threading (B8)

- `Threads.@threads` schedules (Julia manual, built with 1.13.2):
  - `:dynamic` is the default (since 1.8).
  - `:greedy` was **added in 1.11**, so it is not on the 1.10 LTS.
  - `:static` errors when nested and is discouraged in libraries.
- `Threads.@spawn` can choose a threadpool since 1.9, and accepts `:samepool` since 1.12.
- **OhMyThreads.jl** 0.8.7 (2026-10-02, Julia `1.10.0 - 1`) offers `DynamicScheduler` (the default), `StaticScheduler`, `GreedyScheduler` and `SerialScheduler`, with `nchunks`, `chunksize`, `minchunksize` and `split` options. Its `GreedyScheduler` gives greedy scheduling on 1.10 as well.
- **Measured pitfall (§2):** results collected from `fetch` are `Any`, so typed containers or function barriers are needed.

### 5.3 Out-of-core

- **DuckDB external aggregation**, since 0.9.0 ([blog 2024-03-29](https://duckdb.org/2024/03/29/external-aggregation.html); Kuiper, Boncz, Mühleisen, ICDE 2024, [library](https://duckdb.org/library/robust-external-hash-aggregation/)):
  - Phase 1 is thread-local partitioned pre-aggregation into row-major pages. When a table fills, it is reset and its pages are unpinned so they can spill.
  - Phase 2 aggregates per partition.
  - A unified buffer manager covers persistent and temporary pages, and pointers are recomputed after a page is reloaded.
  - It ran H2O.ai 50 GB on a 16 GB laptop.
- **Larger-than-memory hash join:** Kuiper, Groß, Boncz, Mühleisen, "Saving Private Hash Join", PVLDB 18(8), 2025 ([pdf](https://www.vldb.org/pvldb/vol18/p2748-kuiper.pdf)). It covers an adaptive external hash join inside the same buffer pool.
- **Relevance:** the radix-partitioned group-by of §2 is the same partitioning that makes spilling possible. A partition that does not fit in memory is written out and processed later.

### 5.4 Hash joins: broadcast vs shuffle

- **Spark:** `spark.sql.autoBroadcastJoinThreshold` defaults to 10 MB. Hint priority is BROADCAST > MERGE > SHUFFLE_HASH. AQE can convert to a shuffled hash join ([Spark 4.2.0 tuning docs](https://spark.apache.org/docs/latest/sql-performance-tuning.html)).
- **DataFusion:** `hash_join_single_partition_threshold` defaults to 4 MiB, and `hash_join_single_partition_threshold_rows` to 128K rows. Below these, the build side is collected once (CollectLeft) instead of being partitioned (datafusion/common config.rs, main 7c918f9854).
- **Single node:** "broadcast" means one shared build table read by all probe morsels. "Shuffle" means radix-partitioning both sides, as in §2(e), then joining partition by partition.

### 5.5 Distributed options

| Option | Status (2026-10-20) | Notes |
|---|---|---|
| Dagger.jl | 0.22.7 (2026-10-13), Julia `1.10.0 - 1`, actively maintained | Depends on Distributed. DTables.jl 0.5.0 (2026-05-24) is registered but releases rarely (the previous release was 0.4.3, 2023-11). |
| Distributed | Still a stdlib in 1.13.2 (`pkgversion` 1.11.0) | Vendored from JuliaLang/Distributed.jl and not registered separately. DistributedNext.jl 1.3.2 is a registered alternative. |
| Arrow Flight | **No registered Julia Flight client** | Arrow.jl 2.8.1 has no flight module. apache/arrow-julia PR #591 "Add Julia native arrow flight support" was closed. An unregistered fork (JuliaCN/arrow-julia) has a flight module. gRPCClient.jl 1.1.1 (Julia `1.10.0 - 1`) and gRPCServer.jl 0.1.1 exist. |
| Substrait | **No Julia implementation found** (General registry and GitHub search) | Consumers: DuckDB community extension `substrait` (v1.5.6, 2026-10-13), datafusion-substrait 55.2.0, Arrow Acero. For Velox, Substrait conversion now lives in Apache Gluten. |

Sources: the General registry (`Versions.toml`, `Compat.toml`, `Deps.toml`), the GitHub API, the Julia 1.11 and 1.12 NEWS, and the [DuckDB community extension page](https://duckdb.org/community_extensions/extensions/substrait.html).

---

## 6. Design implications for the engine ADR (evidence, not decisions)

1. **The group-by core needs typed keys and its own hash table.**
   - The prototype's `Dict{Any}` path costs 14x (1k groups) to 75x (1M groups) against measured alternatives.
   - A strategy switch by estimated group count looks warranted: thread-local tables plus a merge for few groups, radix partitioning for many. DuckDB does the same.
   - Multi-column and string keys (dictionary codes) still need measuring.
2. **Radix partitioning is one mechanism that serves three needs:** many-group aggregation, partitioned (shuffle) hash joins, and spilling. That argues for building it once as an engine primitive.
3. **CC-005 constrains partitioned execution.** Order-dependent aggregators (`First`, `Last`, non-commutative `ReduceM`) need an order key in the accumulator, or must be combined in partition order. A test should cover radix plus `First`.
4. **Codegen: plan-shape-keyed kernels with constants as runtime values.**
   - These are closures or `@generated`. They avoid recompiling per literal and have no world-age issues.
   - RGF or `eval` with inlined literals pays 10–90 ms per new query.
   - Closures had the lowest compile latency. A size cap and an interpreter fallback are needed for very deep stages.
   - A threshold of the form "interpret when the shape is unseen and estimated rows are < N" looks right, with N on the order of 10⁵–10⁶ to be calibrated.
5. **Optimizer layering:**
   - A fixed, ordered list of rule passes, each a recursion-scheme traversal run to a fixpoint (§4.3), behind an internal adapter while ChuiCore's API is PROVISIONAL.
   - Then a narrow cost-based stage (join order, build side) using statistics.
   - Metatheory.jl 2.1.0 installs on 1.10 and 1.13, but its seconds-scale first use argues for making it optional (an extension) if adopted.
6. **Execution:**
   - Morsels of about 64k–100k rows and push-based pipelines with explicit breakers (sinks implementing CC-004 `partial`/`combine`/`final`).
   - Scheduling through `Threads.@spawn` with chunking, or OhMyThreads, if greedy scheduling is needed on 1.10.
7. **Distributed:**
   - Dagger.jl is the only maintained scheduler option, and it pulls in Distributed.
   - Arrow Flight would need a client written here, or adopting the unregistered fork.
   - Substrait would need a new Julia implementation.
   - Each of these is a large dependency or work item for phase 5, not phase 1.

---

## UNVERIFIED

- DuckDB's `JOIN_ORDER` pass uses DPhyp. The pass name was read, but its implementation was not.
- DuckDB's operator and pipeline interface details (Sink/Combine/Finalize naming). These come from secondary sources, not DuckDB source.
- Whether Calcite's HepPlanner always runs to a fixpoint. The docs say only "a more fixed order".
- That DataFusion type coercion runs in the analyzer rather than the optimizer.
- Behaviour of closure-composed and `@generated` kernels beyond depth 50 (inference limits) and for multi-column stages.
- Shape-keyed RGF/eval (constants passed as arguments): not measured.
- Group-by with multi-column, string or `missing` keys: not measured.
- Absolute timings under an unloaded machine. All runs had load averages of 19–65 on 12 cores.
- The prototype's DESIGN §4 timings on 1.11.7 were not reproduced on that version.

---

## Evidence

`S` is the session scratchpad,
`/private/tmp/claude-501/-Users-bonmac-personal-projects-julia-data-analysis-ChuiFrames-jl--worktrees-phase1-research/ec2d6965-575b-4df9-88c8-fd3cf43e61fc/scratchpad/engine`.
The prototype copy is at `$S/proto`.

- **EN-01:** `cp -R <coordinator>/reference/prototype $S/proto`, then for each of `demo.jl`, `review/fixcheck.jl` and `review/optcheck.jl`: `cd $S/proto; julia --startup-file=no -t 4 <f>`.
  - Output: `lazy == eager: true   lazy 1.119s vs eager 2.988s`, `all fix checks passed`, and `optimizer checks done` (with the rule log shown in §1.1).
- **EN-02:** `julia --startup-file=no --project=io/env -e 'using Pkg; Pkg.instantiate()'`, then `julia --startup-file=no --project=io/env -t 4 review/nancheck.jl`.
  - Output: `33 dependencies successfully precompiled in 176 seconds`, then `nan + select checks passed`.
- **EN-03:** `julia --startup-file=no -t 4 $S/proto/prof.jl`, run twice.
  - Output: `groupindices alone: median 2.915s`, `3.330795 seconds (10.56 M allocations: 275.119 MiB, 11.40% gc time)`.
  - Profile rows: `5846 … Tidy.jl 344 apply(t::Tbl, s::…SummariseStep)`, `3715 2054 … Tidy.jl 263 groupindices(t::Tbl)`, `6989 … top-level scope`.
  - Pipeline lines: `10-step eager pipeline n=100 per-call 1.384e-04 s`, `n=1000000 per-call 4.146e-02 s`.
- **EN-04:** the first `julia --startup-file=no -t 4 $S/gb.jl` run, at load average 44–65. This version of (d) was untyped and dispatched dynamically.
  - Output: `(d) G=1000000 median 4.927 s`; `(a) G=1000000 median 11.753 s`.
  - A probe check gave `cap=2097152 groups=999958 probes=(1.4178, 39)`. The hash table was sound and the slowness was the `Vector{Any}` from `fetch`.
- **EN-05:** `julia --startup-file=no -t 4 -e 'include("gb.jl")'` after the fix, at load average 40–45, plus `-t 1` for (c) and (e). These are the table in §2.
- **EN-06:** `uv run --python 3.13 --with polars --with duckdb --with numpy --with pyarrow python -I py/gb.py $S`.
  - Output: `polars 2.0.0 duckdb 1.5.6 numpy 2.5.4 polars threads 4`, `duckdb threads (4,)`, then the table in §2.
- **EN-07:** `for r in 1 2 3; for var in interp closure generated rgf eval: julia --startup-file=no --project=$S/cg -t 4 $S/cg/cg.jl $var`, at load average 19–40. These are the table in §3. A sample line: `rgf load 0.27s | first A 0.087s | first B 0.052s | first C 0.010s | steady 10M median 0.0018s`.
- **EN-08:** `julia --startup-file=no --project=$S/cg $S/cg/depth.jl {closure,generated,rgf}`.
  - Output: `closure depth 50 first call 0.047 s`, `generated depth 50 first call 0.630 s`, `rgf depth 50 first call 1.740 s`.
- **EN-09:** `julia --startup-file=no $S/cg/wa.jl` and `julia +lts --startup-file=no $S/cg/wa.jl`.
  - Output: `1.13.2 | direct call: MethodError: no method matching kk(::Vector{Int64}) … | invokelatest -> 3`, plus the 1.12+ binding world-age warning. The same `MethodError` appears on `1.10.12`.
  - The registry gave `RuntimeGeneratedFunctions` 0.5.27 (release 2026-09-26) with `julia = "1.10.0 - 1"`.
- **EN-10:** `uv run --python 3.13 --with polars python -I pl_explain.py` (helper lane). Output: `polars 2.0.0` and the plan quoted in §4.1.
- **EN-11:** Metatheory install and saturation in scratch environments on 1.13.2 and 1.10.12 (helper lane).
  - Output: `installed in 46.4s; version 2.1.0`, `Stop Reason: saturated / Iterations: 2 / EGraph Size: 2 eclasses, 6 nodes`, `extracted: x`, and `time to first saturation (incl. load): 4.2s` (1.13.2) or `2.6s` (1.10.12).
- **EN-12:** registry and GitHub reads (helper lane), via `curl` of raw General `Versions.toml`/`Compat.toml`/`Deps.toml` for Dagger, DTables, OhMyThreads, Metatheory, Arrow, gRPCClient and DistributedNext, and `gh api repos/...` for release dates and archive status.
  - Output: the versions and dates stated in §4.2, §5.2 and §5.5.
  - `julia -e 'using Distributed; pkgversion(Distributed)'` printed `1.11.0`.
