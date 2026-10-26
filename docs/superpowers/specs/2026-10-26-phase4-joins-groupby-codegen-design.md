# Phase 4 design: joins, the fast group-by with aggregate sinks, and codegen kernels

- **Date:** 2026-10-26 (revised the same day after critic REJECT and reviewer REQUEST CHANGES,
  then after critic pass 2 ACCEPT WITH CHANGES, then with the user's ★ answers K1–K4; see §8
  Review log). **Branch:** `feat/phase4` (integration). Sub-lanes, in order (§0.2):
  `feat/p4-groupby` and `feat/p4-codegen` (phase A), then `feat/p4-groupby2` and `feat/p4-join`
  (phase B), then `feat/p4-bench` (phase C). **Plan:**
  [2026-10-26-phase4.md](../plans/2026-10-26-phase4.md).
- **Tier:** T2 (new public verbs: `inner_join`, `left_join`, `right_join`, `full_join`,
  `semi_join`, `anti_join`, `nest_join`, `cross_join`, `join_by`, and the DataAPI join methods;
  new plan node; new `explain` sections).
- **Binding decisions:** ADR-0002 rule 16 (join keys, as amended 2026-10-26: `by`), ADR-0003
  rules 3–12 (engine, kept as written), ADR-0004
  (sources), ADR-0007 (DataAPI), ADR-0014 (upstream stand-ins), ADR-0022 (budgets), CF-008
  (lazy == eager, approximate frame equality for reductions), the phase-3 spec §1 R-total rule.
  New ADRs: 0023 (joins; records the ★ answers K1–K4), 0024 (group-by and aggregate sinks),
  0025 (codegen kernels and the interpreter threshold).
- **User ★ answers (2026-10-26, §0.4):** K1 the keyword is `by`; K2 ADR-0003 is kept (the cost
  stage picks the build side; partitioned joins partition both sides; an order-restoring sort);
  K3 the full phase-4 parity matrix (`nest_join`, `cross_join`, equality `join_by`, DataAPI
  methods); K4 integer/float key pairs are allowed, compared as `Float64`. p4-join (phase B)
  starts after the critic's FINAL on this revision.

## 0. Seam, lane order, forcing switches, the user's ★ answers

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
  tasks 3–7) and `p4-join`, in parallel. The ★ answers are in (§0.4); p4-join forks after the
  critic's FINAL on this revision. It uses the merged key and radix API (§2.2, §2.4) and must not
  duplicate it.
  - **K4 helper first (§1.1):** p4-groupby2's first task adds `_keypair_compare_type` to
    `src/engine/hashagg.jl` (and makes `_keypair_allowed` follow it). That commit is reviewed and
    merged into `feat/phase4` on its own, before p4-join's key-pair code (plan task 1); p4-join
    then merges `feat/phase4` into its branch. p4-join calls the helper and never redefines it.
    **p4-join stubs nothing** (critic pass 3 m7, coordinator's decision): its tasks that need
    the helper (compare types in `JoinNames`, the K4 conversion, the N1 check, the N2 pushdown
    condition) wait for that merge; everything else (verbs, names, the three shapes on
    same-type keys, the oracle) goes first.
- **Phase C:** `p4-bench`, after p4-groupby2, p4-join and p4-codegen have merged.

### 0.3 Forcing switches for tests (critic M8)

Internal module-level `Ref`s, each in its owner's file. Each is read **once per `collect`** (when
the kernel, the radix limit or the join strategy is chosen), never inside a morsel loop:

| Ref | File (owner) | Values |
|---|---|---|
| `_FORCE_KERNEL::Ref{Symbol}` | `src/lazy/kernels.jl` (p4-codegen) | `:auto` (default), `:compiled`, `:interpreter` |
| `_FORCE_RADIX_SWITCH::Ref{Int}` | `src/engine/hashagg.jl` (p4-groupby2) | `0` = use `RADIX_SWITCH`; `> 0` overrides it |
| `_FORCE_JOIN::Ref{Symbol}` | `src/engine/join.jl` (p4-join) | `:auto` (default), `:broadcast_x`, `:broadcast_y`, `:partitioned_x`, `:partitioned_y` |

- `_FORCE_KERNEL[] = :compiled` compiles every stage that is compilable (§3.2). A stage that is
  not compilable still runs the interpreter.
- `_FORCE_JOIN` forces the strategy **and** the build side together (one `Ref`, so one
  `withforce` pair covers a combination): `:broadcast_x` is a broadcast join building on x,
  `:partitioned_y` a partitioned join whose per-partition tables are built on y, and so on (§1.2).
  It is read by `join_decision` (§1.2), which eager, `collect` and `explain` all call. It applies
  to every keyed join (inner, left, right, full, semi, anti, nest). `cross_join` has no hash table
  and ignores it. Tests run every keyed join under all four forced values and `:auto`.
- Tests set the switches only through `withforce` (§0.1, Task 0b). The `Ref`s are process-global.
  That is safe because TestItemRunner 1.3.2 runs test items one at a time in one process
  (settled in critic pass 2).

### 0.4 The user's ★ answers (2026-10-26, at the ChuiFrames phase-4 ★)

- **K1. The join keyword is `by =`** (dplyr parity). ADR-0002 rule 16 carries a dated amendment
  (2026-10-26): `by` replaces `on`; key forms `nothing` (natural join, with `@info`), `:a`, `"a"`,
  `[:a, :b]`, `:a => :b`, and vectors of those. The **DataAPI methods** (`DataAPI.innerjoin(x, y;
  on)` and the rest, ADR-0007) keep DataAPI's own keyword `on` and forward it to the verb's `by`
  (§1.1). `by` is no longer a parity divergence.
- **K2. ADR-0003 is kept as written; no amendment.** The cost stage picks the build side (the
  smaller side by estimated bytes, rule 4). Below the broadcast limit a broadcast join builds one
  shared table on that side; above it **both** sides are radix-partitioned (rule 11) with the
  merged `radix_partition` (§2.4, src/engine/radix.jl). dplyr's row order is restored by a stable
  sort of the matched (xrow, yrow) pairs by x row, then y row; right/full append the unmatched y
  rows after, in y order. §1.2–§1.4 specify what streams and what is a pipeline breaker in each
  case. p4-bench measures the cost of the sort (§5).
- **K3. The full parity matrix ships in phase 4:** `nest_join` (§1.5; its output column reuses
  tidyr `nest`'s representation, an object column of `Frame`s), `cross_join`, `join_by` with
  **equality pairs only** (§1.5 says why the `a == b` form is not shipped), and the DataAPI join
  methods including `crossjoin`. Inequality and rolling `join_by` stay **deferred: no design
  exists**.
- **K4. Integer/float key pairs are allowed** (dplyr parity), compared in the pair's compare type
  (`Float64` for every integer/float pair that is not lossless). The helper
  `_keypair_compare_type(Sx, Sy)` lives in `src/engine/hashagg.jl` (added by p4-groupby2,
  §0.2; p4-join calls it). Keys are converted to the compare type before `typed_keys`/`keyhash`.
  The precision loss above 2⁵³ is documented (§1.1); it is no longer a recorded divergence.
  `Date`/`DateTime`, `Int64`/`UInt64` and string/number pairs stay rejected.

## 1. Joins (ADR-0023; DESIGN §7 item 1; parity rows `inner_join` … `anti_join`)

### 1.1 API (dplyr 1.2.0 semantics; verified facts in §1.6)

```julia
inner_join(y; by = nothing, suffix = ("_x", "_y"), na_matches = :na, keep = false,
           multiple = :all, unmatched = :drop)
left_join(y; …same…); right_join(y; …same…)
full_join(y; by = nothing, suffix, na_matches, keep, multiple)    # no `unmatched` (dplyr)
semi_join(y; by = nothing, na_matches = :na)
anti_join(y; by = nothing, na_matches = :na)
nest_join(y; by = nothing, keep = false, name = :y, na_matches = :na, unmatched = :drop)  # §1.5
cross_join(y; suffix = ("_x", "_y"))                                                      # §1.5
join_by(keys...)        # equality pairs only: join_by(:a => :b, :c); usable as `by = join_by(…)`
```

- Each verb returns a `JoinStep <: Step` holding `y`: any Tables.jl table, converted once with
  `Frame(y)`, or a `LazyFrame`/`Source`. Both `x |> inner_join(y; by)` and
  `inner_join(y; by)(x)` work (CF-007). An eager `x` with a lazy `y` collects `y` first (the
  eager meaning).
- **DataAPI methods (ADR-0007):** `DataAPI.innerjoin`, `leftjoin`, `rightjoin`, `outerjoin`,
  `semijoin`, `antijoin` and `crossjoin` on `(x::Frame, y)`. They keep **DataAPI's own keyword
  `on`** (ADR-0007; the ★ K1 amendment renames only the verbs' keyword): `innerjoin(x, y; on =
  :k, kw...)` is `inner_join(y; by = :k, kw...)(x)`, with `on` defaulting to `nothing` and every
  other keyword forwarded unchanged (so a DataFrames-only keyword such as `makeunique` raises the
  verb's keyword error). `crossjoin(x, y)` forwards to `cross_join`. `nest_join` and `join_by`
  have no DataAPI counterpart. All seven names exist in DataAPI 1.16.0 (checked:
  `names(DataAPI; all = true)` in this package's environment).
  - **ExplicitImports (critic pass 3 MAJOR-4a):** DataAPI declares the seven as bare
    `function innerjoin end` … `function crossjoin end`, with no docstring and no `public`
    declaration, under the source comment "The database-style join methods for tabular data
    type. The common interface is `*join(x, y; ...)`" (the DataAPI package's own source file
    src/DataAPI.jl, read in the local package depot, 2026-10-26). So `DataAPI.innerjoin` and the rest fail
    `check_all_qualified_accesses_are_public`. p4-join adds **exactly** these seven names
    (`:innerjoin, :leftjoin, :rightjoin, :outerjoin, :semijoin, :antijoin, :crossjoin`) to the
    `INTERFACE` tuple in `test/package_tests.jl`, with a comment citing that DataAPI source comment
    and ADR-0007, as the file's other entries cite their docs.
- **`by`** (ADR-0002 rule 16 as amended 2026-10-26): `nothing` is a natural join on the common
  column names. `:a`, `"a"`, `[:a, :b]` and `:a => :b` (x's `a` equals y's `b`, left `=>`
  right) work, as does a vector of those, and a `join_by(...)` value (§1.5). No common column
  under `nothing` → `ArgumentError` (dplyr errors too).
- **The natural-join message (one rule, critic n9):** a natural join logs
  `@info "Joining with by = [...]"` (silenceable with `with_logger`) **once, when its
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
- **Key types (critic N1, ★ K4).** Let `Sx = nonmissingtype(Tx)` and `Sy = nonmissingtype(Ty)`
  for a key pair. Each allowed pair has a **compare type** `T`, given by
  `_keypair_compare_type(Sx, Sy) -> Union{Nothing, Type}` (`src/engine/hashagg.jl`, p4-groupby2;
  `nothing` = rejected). `_keypair_allowed(Sx, Sy)` becomes
  `_keypair_compare_type(Sx, Sy) !== nothing`. The pair is **allowed only** in four cases:
  - `Sx === Sy` (`T = Sx`);
  - both are `<: AbstractString` (`T = String`). They are unified the way `bind_rows` unifies them: its
    `vcat_columns` (src/columns.jl) collects the values and calls `column`, which builds a
    `StringColumn` for any `AbstractString` element type. The output key is a `String` column
    (the join builds it). The typed keys keep each column's own string type (e.g. `StringView`;
    no per-row conversion): `isequal` and `keyhash` agree across `String`, `SubString` and
    `StringView` (tested), and a `KeyTable{String}` accepts `StringView` keys, converting once per
    new key. Two string types never promote to `AbstractString`;
  - both are in `Union{Bool, Base.BitInteger, Base.IEEEFloat}` and
    `_lossless_key_promotion(Sx, Sy)` holds (`T = promote_type(Sx, Sy)`, which keeps every value
    of both; merged in `src/engine/hashagg.jl`):
    - integer → integer when `typemin`/`typemax` fit in `T` (so `Int64`/`UInt64` is rejected:
      a negative key would throw `InexactError`);
    - integer → float when the integer's bit width ≤ the float's significand bits + 1
      (`Int32`/`Float64`, `Int8`/`Float16`);
    - float → wider float.

    This is the same "promote only when lossless" rule that `column` applies (ADR-0001 rule 12);
  - **(★ K4)** one is `Bool` or a `Base.BitInteger` and the other a `Base.IEEEFloat`, and the
    pair is not lossless (e.g. `Int64`/`Float64`, `Int32`/`Float32`, `UInt64`/`Float16`):
    `T = Float64`. (The user's rule is "`Float64`, or the float type when wider"; no IEEE float
    type is wider than `Float64`, so `T` is always `Float64` here.) This is dplyr's rule: an
    integer key joined with a double key is compared as double (§1.6).

  A side whose nonmissing type is `Union{}` (an all-`missing` key column) pairs with any type,
  with `T` the other side's type (`Union{}` when both are): it can only match `missing`. This is
  checked first, as the merged `_keypair_allowed` does.

  Every other pair → `ArgumentError` naming both columns and types, raised when the step is
  applied (eager), or in lazy mode at `JoinNode` construction when both key types are static and
  otherwise at `collect` (critic pass 3 MAJOR-1; §1.4 "Static key types"). Rejected pairs: `Date` vs `DateTime`
  (they are `isequal`-compatible in some cases but hash differently, so they would silently not
  match), integer vs integer pairs that are not lossless (`Int64`/`UInt64`, `Int8`/`UInt8`:
  conversion would throw `InexactError` or wrap), string vs number, and other `Real`s that are
  not identical (`Rational`, `BigFloat`, fixed-point types). The fix is to convert first.
  - **Conversion (★ K4).** Before `typed_keys`/`keyhash`, every numeric key column whose
    nonmissing type is not `T` is converted to `T` (`missing` stays `missing`): one typed vector
    per converted key column, per morsel on a streamed side, once on a built side. For a lossless
    pair the conversion is exact; for a lossy one it rounds to nearest. String keys are never
    converted (`StringView` keys are kept, as above). Both sides' typed keys then have one
    element type, so `keyhash` agrees trivially and `lookup` never compares across types.
  - **Precision above 2⁵³ (★ K4, documented, not a divergence).** `Float64` has a 53-bit
    significand, so integers above 2⁵³ in magnitude do not all survive the conversion: two
    different `Int64` keys can round to one `Float64` and then match the same y row. Example:
    x `Int64` keys `2^53` and `2^53 + 1` against y `Float64` key `2.0^53` → both x rows match.
    The output key (`keep = false`) is the converted value, so both rows show
    `9.007199254740992e15`. This is documented in the `inner_join` docstring and
    `docs/src/api.md`, with "convert the key first" as the remedy. (dplyr cannot show this case:
    R integers are 32 bits, and dplyr 1.2.0 rejects a `bit64::integer64` key against a double,
    "Can't join `x$k` with `y$k` due to incompatible types", §1.6.)
  - semi/anti return x's columns **unconverted**, keys included (critic pass 3 m3).
  - The output key column (`keep = false`; inner, left, right, full, nest) has element type `T`, with `Missing` added when
    either side is nullable; its values are x's converted values, or y's for right/full rows that
    exist only in y. With `keep = true` each side's key column keeps its own type, unconverted
    (dplyr 1.2.0: `k.x` integer, `k.y` numeric, §1.6). For a lossless pair `T` is
    `promote_type(Sx, Sy)` as before.
  - **Required test** (p4-groupby task 1 for `keyhash`, and p4-join for the pair rule): for every
    allowed pair of types and generated values, including ±0.0, NaN payloads, `NaN32` vs `NaN`,
    `true` vs `1` and `SubString` vs `String`, `isequal(a, b)` implies
    `keyhash(a) == keyhash(b)` **after conversion to `T`**. For the lossy integer/float pairs
    the generator includes values at the 2⁵³ boundary (`2^53 - 1`, `2^53`, `2^53 + 1`,
    `-(2^53 + 1)`, `typemax(Int64)`), and the test asserts the documented matches.
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
    `unmatched = :error` on the y side. Under every strategy and build side only the chosen y
    rows count as matched (§1.2). Verified against dplyr 1.2.0 (§1.6); the p4-join differential
    keeps this case.
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

### 1.2 The hash join (one physical operator, eager and lazy; ADR-0003 rules 4, 10, 11, ★ K2)

- **Build:** the build side's key columns, converted to the compare type (§1.1, K4), become
  typed keys (§2.2 `typed_keys(...; codes = false)`) in a `KeyTable` (§2.2) that maps a key to
  its dense id. A `first::Vector{Int}` maps the id to the build side's first row with that key,
  and a `next::Vector{Int}` chains the build side's rows with the same key **in that side's row
  order** (rows are inserted in ascending order).
  - Abstract key types (critic n6): when `typed_keys` returns `nothing` for either side (a key
    column of abstract element type, e.g. `Any`), the join raises `ArgumentError` naming the
    column and suggesting a conversion.
  - A `Dict`-based fallback is documented as later work (not in phase 4), so the hot path never
    holds a `Dict{Any}`.
- **The decision (cost stage, ADR-0003 rule 4):** `join_decision(spec, x::SideEstimate,
  y::SideEstimate) -> (strategy::Symbol, build::Symbol, p::Int, why::String)` in
  `src/engine/join.jl`, with `SideEstimate(rows::Union{Nothing, Int}, exact::Bool,
  coltypes::Union{Nothing, Vector{Type}})` per side (critic pass 3 m5): `rows` from
  `_estimated_rows` (or the frame's row count), `exact` whether that count is exact, and
  `coltypes` the element types of the columns the join reads from that side (keys and the columns
  kept above it, after projection pushdown), or `nothing` when they are not static (§1.4).
  Eager `apply`, the lowering at `collect` and `explain` all call it.
  1. `_FORCE_JOIN[] ≠ :auto` (§0.3) → that strategy and build side.
  2. **Build side:** the side with fewer **estimated bytes**; a tie → y. Estimated bytes =
     `rows` × the sum over `coltypes` of a nominal width: `sizeof(T)` for an `isbitstype`
     element type (after `nonmissingtype`), 16 bytes for any other element type (UNVERIFIED
     heuristic; p4-bench recalibrates it). **Nested columns:** a column of element type `Frame`
     (a `nest`/`nest_join` output) or any other `AbstractVector`/`NamedTuple` element has no
     useful width, so a side reading one has **unknown** bytes. A side with unknown rows, unknown
     `coltypes` or unknown bytes counts as larger; both unknown → y. Eager uses exact row counts
     and the frames' column types.
  3. **Strategy (rule 11):** `broadcast` when the build side has fewer than
     `BROADCAST_MAX_ROWS = 131_072` rows **and** fewer than `BROADCAST_MAX_BYTES = 4 MiB`
     estimated input bytes (every column the join reads from it, not only the keys); otherwise
     `partitioned` into 2ᵖ partitions, p = 4–8 chosen from the larger side's rows. These are
     DataFusion's defaults as ADR-0003 rule 11 records them. UNVERIFIED here (the critic reports
     the byte limit is on input bytes); p4-bench rechecks the DataFusion source and recalibrates.
     Both constants live in `src/engine/join.jl`.
  4. At `collect` the build side is always collected before the probe starts, so the strategy
     test uses its **collected** size (exact). The build side is chosen from estimates. `explain`
     (which never executes) prints the estimate-based prediction and says that the strategy is
     confirmed on the collected build side.
  5. **`explain` and `collect` agree only on exact inputs** (critic pass 3 m4). When both sides'
     `rows` are exact and their `coltypes` static, `explain` and `collect` report the same
     decision. Otherwise they may differ (an inexact upper bound, a side collected at `collect`
     because its key type is not static, a build side whose collected size crosses the broadcast
     limit). That is harmless: every shape gives the same result.
- **Three physical shapes.** Lowering (§1.4) turns a `JoinNode` into one of them:

  **(a) Broadcast, build y: the probe streams x.** `StepNode(ProbeStep(:y, build, spec, names),
  left)`. `ProbeStep` is streamable and sits in x's parallel streamed stage.
  - Per x morsel it probes statelessly against the frozen table. For each x row in order it walks
    the y chain in y order, so the morsel's (xrow, yrow) pairs come out in (xrow, yrow) order,
    and the executor keeps morsel order (ADR-0003 rule 6). The order-restoring sort is therefore
    the identity and is **skipped**; a test asserts `issorted` on the pairs in this shape.
  - For each x row, in ascending order, the probe first runs the **x-side checks** (the x-side
    pass of the error precedence below): no match under an x-side `unmatched = :error` (inner,
    right), or more than one match under `multiple = :error`, raises at once, whichever that row
    fails. Only then is `multiple` applied to the row. Right joins drop unmatched x rows here.
  - When a tail is needed, the probe also emits the hidden column `Symbol("##chui_yrow")` (the
    chosen y row, the build-side row index; `0` for an unmatched x row). There is no shared
    `BitVector` (critic M1). The tail, `JoinTailStep` (a pipeline breaker in `rest`, after the
    gather), is placed when the kind is right or full, or when `unmatched = :error` has a y-side
    check (inner, left). It builds the matched-y bitmap from the hidden column on one task, raises
    for the first unmatched y row under `unmatched = :error`, appends the unmatched y rows in y
    order for right/full (x columns `missing`, keys from y), and drops the hidden column.
  - **What streams:** x is never materialized. With no tail, the steps above the join fuse into
    the same streamed stage. y is collected (a pipeline breaker on y; y's own stage runs in
    parallel inside that collect).

  **(b) Broadcast, build x: the probe streams y.** x's subplan is collected into the build table
  (a pipeline breaker on x). Lowering swaps the streamed input:
  `StepNode(ProbeStep(:x, build, spec, names), right)`, so y's subplan is the streamed pipeline.
  - Per y morsel, for each y row in order, the probe walks x's chain in x order and emits one row
    per pair holding the y columns the output needs (after projection pushdown; y's key
    columns too when right/full or `keep = true` output them) plus two hidden columns:
    `Symbol("##chui_xrow")::Int` (the matched x row) and `Symbol("##chui_ystart")::Bool` (`true`
    on the first emitted row of each y row). When the kind needs y's unmatched rows (right/full,
    or a y-side `unmatched = :error` check), every y row with no match is emitted once with
    `##chui_xrow = 0`; otherwise it is dropped in the probe.
  - The probe applies no `multiple` and raises nothing: one x row's matches span y morsels.
  - A `JoinTailStep` always follows (a pipeline breaker in `rest`). It:
    1. numbers y rows: `yord = cumsum(##chui_ystart)` over the gathered rows. The gather is in
       morsel order, which is y order, so `yord` is y's row number whenever every y row was
       emitted (the cases that need it). This needs no morsel index from the executor, so
       `execute.jl` is unchanged;
    2. sorts the gathered rows stably by `##chui_xrow` (the order-restoring sort below; rows with
       `0` go last, in y order). Because y rows arrive in ascending order and each y row's x
       matches were emitted in ascending x order, the result is in (xrow, yrow) order;
    3. runs the **x-side pass** of the error precedence below: one ascending pass over all x
       rows (those with a run and those without), before `multiple` is applied;
    4. applies `multiple` to each x row's run (`:first`/`:any` keep the first, `:last` the last);
       y rows with no chosen pair become unmatched (n3);
    5. runs the **y-side check** (the first unmatched y row in `yord` order, under a y-side
       `unmatched = :error`);
    6. merges in the unmatched x rows (left/full) at their x positions, with y columns `missing`;
    7. appends the unmatched y rows (right/full) in `yord` order, taking each one's y values from
       its first gathered row, with x columns `missing` and keys from y;
    8. adds x's columns with one `take` per column from the built x frame (`missing` where
       `##chui_xrow = 0`), drops the hidden columns, and rebuilds x's grouping.
  - semi/anti under build x: the probe emits only `Symbol("##chui_xkey")` (the distinct matched
    x key ids of the morsel). The tail ORs them into a bitmap over key ids and returns x's rows
    whose key is (semi) or is not (anti) marked, in x order. nest_join: §1.5.
  - **What streams:** y streams through its stage into the probe, and only the matched rows are
    gathered, so a 10³-row x against a 10⁷-row y builds 10³ entries and never materializes y.
    The tail is a pipeline breaker: everything above the join runs after it.

  **(c) Partitioned: both sides radix-partitioned (ADR-0003 rule 11).**
  `StepNode(PartitionedJoinStep(right, spec, names), left)`. `PartitionedJoinStep` is not
  streamable, so `physical` puts it in `rest`: it receives x gathered from x's stage and
  collects y's subplan (both sides are pipeline breakers).
  - Both sides' converted keys are hashed (`keyhashes`, §2.2) and partitioned by
    `radix_partition(hashes, p; ntasks)` (§2.4) with the same `p`. Because the partitions take
    the high hash bits and `KeyTable` the low bits (§2.2 n5), a partition's table never degrades.
  - One task per contiguous range of partitions (ADR-0003 rule 6). Per partition, the build
    side's rows (ascending, so chains stay in row order) fill the partition's table, and the
    other side's rows probe it in ascending order, emitting global (xrow, yrow) pairs. The
    partition probes **raise nothing** (critic pass 3 m8): a partition sees only part of x and
    y, so every check runs afterwards, in the tail steps below.
  - **Invariant:** each x row's pairs are emitted in ascending y order (probing with x, the
    chains are in y order; probing with y, y rows are visited in ascending order), and one x
    row's pairs all fall in one partition. So the order-restoring sort by xrow alone over the
    concatenated pairs gives (xrow, yrow) order.
  - Then steps 3–8 of shape (b) run on the pairs, with the y columns taken from the collected y
    (`yord` is the y row index itself, since y is collected).
- **The order-restoring sort** (shapes b and c; ★ K2): a stable counting sort of the m pairs by
  xrow: a histogram over |x| + 1 buckets, prefix sums, scatter. O(m + |x|) time; two `Int`
  vectors of length m plus |x| + 2 counts. In shape (b) it permutes the gathered rows (one extra
  `take` per gathered column). p4-bench measures its cost (§5).
- **Error precedence (critic pass 3 MAJOR-3; dplyr 1.2.0 verified, §1.6):**
  1. **x-side pass:** one ascending pass over x's rows, **before** `multiple` is applied. The
     first x row that fails either x-side check raises, whichever kind it is: no match under an
     x-side `unmatched = :error` (inner, right) gives "Each row of `x` must have a match in
     `y`"; more than one match under `multiple = :error` gives "Each row in `x` must match at
     most 1 row in `y`". dplyr: x k = [2, 1], y k = [1, 1] with both options raises "Row 1 of
     `x` does not have a match"; x k = [1, 2] raises "Row 1 of `x` matches multiple rows".
  2. **y-side check**, after `multiple` (so unchosen y rows count, n3): the first unmatched y
     row in y order, under a y-side `unmatched = :error` (inner, left, nest).

  Eager follows this order under every shape, so its exception (type and message) does not
  depend on the build side or the strategy; a unit test checks the two dplyr cases above under
  every `_FORCE_JOIN` value.
- **Lazy exceptions (critic pass 3 MAJOR-2, coordinator's decision):** in shape (a) several x
  morsels run in parallel, and no claim is made that the lazy run names the same row as eager.
  What holds is: the lazy run raises an exception of the **same type** (an `ArgumentError` from
  the same check family), and `collect` replays the unoptimized plan eagerly on any lazy failure
  (ADR-0003 rule 7 note), so the exception `collect` reports, message included, is eager's. The
  join property tests' raw runner (no replay, §4) therefore compares exception **types** only.
- **Same result under every shape (CF-008):** the output is identical because (i) rows come out
  in (xrow, yrow) order, (ii) `multiple` is applied per x row over its y-ordered matches, (iii)
  only chosen y rows count as matched (n3), (iv) eager errors follow one precedence, and (v)
  element types are static by kind (§1.1). The property tests force all four `_FORCE_JOIN`
  values plus `:auto` (§4).
- **Hidden columns (critic n10, extended; pass 3 m9):** the prefix `##chui_` is reserved. A user
  column whose name starts with it, on either side, or a `nest_join` `name` that starts with it,
  → `ArgumentError` when the step is applied or the `JoinNode` is built, so no hidden column
  (`##chui_yrow`, `##chui_xrow`, `##chui_ystart`, `##chui_xkey`, `##chui_ykey`) can collide.
- No change to `execute.jl` for joins: `isstreamable(::ProbeStep) = true`,
  `isstreamable(::JoinTailStep) = false` and `isstreamable(::PartitionedJoinStep) = false` are
  methods in `src/lazy/joins.jl`, so `physical` puts the breakers in `rest`. A `head` above a
  join with a breaker stays in `rest`, after it.
- **Totality:** `_steptotal(::ProbeStep, below)` (a method in `src/lazy/joins.jl`) is `true` only
  in shape (a) with no tail and for a total join (§1.3); shapes (b) and (c) always have a breaker.
  Otherwise a limit never stops early past it.
- **Eager:** `JoinStep` applied to a frame calls `join_decision` with exact sizes and runs the
  same shape on the whole frames, the probe side as a single morsel, on the calling task below
  65 536 probe rows (ADR-0003 rule 2).

### 1.3 Filter pushdown through a join (critic B1, minor "key copy")

A join is **total** for pushdown only when `unmatched = :drop` and `multiple ∈ (:all, :first,
:last, :any)` (semi/anti and `cross_join` are always total; `nest_join` is total when
`unmatched = :drop`). Pushdown is a logical rule pass: it runs before the cost stage and does
not depend on the build side or the strategy, because every shape gives the same result (§1.2).
The rules:

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
  - left: x only; right: y only (when `multiple = :all`); full: never;
  - nest_join: x only (a filter reading the nested column is never pushed);
  - cross_join: either side.
- **semi/anti return x unconverted** (critic pass 3 m3): their output is x's own columns, key
  columns included, with no compare-type conversion (the conversion is internal to hashing and
  lookup). So a predicate on any x column, key included, moves to x with no type condition.
- **Key columns under `keep = false`:** a predicate on the output key is pushed to **x only**,
  only for inner/left/nest (the output key is x's value, converted to the compare type
  `T`), only when **both key types are static** (§1.4 "Static key types"; critic pass 3
  MAJOR-1: otherwise `T` is not known until `collect`, after the passes), and only when
  `T === nonmissingtype(Tx)`, with `T = _keypair_compare_type(Sx, Sy)` (critic N2, re-checked
  under ★ K4). Then x's key is not converted, the output key holds x's values
  unchanged, and the predicate gives the same answer on x as on the output. Otherwise x's key is
  converted (x `Int32` vs y `Float64`: `T = Float64`, lossless; x `Int64` vs y `Float64`: `T =
  Float64`, lossy above 2⁵³), and the predicate could answer differently on x's unconverted
  values. Example: x `Int64` keys `[2^53, 2^53 + 1]`, y `Float64` key `2.0^53`, and
  `filter(c.k .== 2^53 + 1)` above the join. Eager: both rows match and the output key is
  `2.0^53` in both, and `2.0^53 == 2^53 + 1` is `false`, so 0 rows. Pushed to x, the filter would
  keep x's second row, which matches, so 1 row. Hence no push. Two string types give `T = String`
  while a `StringColumn`'s element type is not `String`, so mixed string-type key predicates are
  not pushed (conservative); same-type keys have `T = Sx` and are pushed. A key predicate is
  **never** copied to y. A copy
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
  - a key predicate when the compare type is not x's key type (x `Int32` vs y `Float64`; N2);
  - the 2⁵³ case (★ K4): x `Int64` keys `[2^53, 2^53 + 1]` vs y `Float64` key `2.0^53` with
    `filter(c.k .== 2^53 + 1)` above an inner join: not pushed (`T = Float64 ≠ Int64`); lazy and
    eager both give 0 rows, under every `_FORCE_JOIN` value;
  - a `nest_join` filter that reads the nested column, and any filter above a `nest_join` with
    `unmatched = :error`;
  - a `nest_join` whose `name` equals x's key column under `keep = false` (critic pass 3 m1):
    the output column of that name is the nested column, not the key, so a filter on it is not
    mapped to x's key and is not pushed (`JoinNames` maps that output name to the nested column);
  - a key predicate when a key type is not static (MAJOR-1): x's key from
    `mutate(:k => f.(c.a))` with `f(a) = a > 1 ? 1.5 : 1`; not pushed;
  - a non-R-total predicate.

  The positive cases (fires) are tested for each kind too, including x `Float64` vs y `Int64`
  (`T = Float64 = Sx`: a key predicate is pushed to x) and a semi join with x `Int64` vs y
  `Float64` keys (pushed: semi returns x unconverted).

### 1.4 The plan becomes a tree

- `JoinNode(left, right, spec::JoinStep, names::JoinNames) <: PlanNode` has **`Any`-typed**
  children (R6), and a `fmap` that maps both children, so the R6 stand-ins (`cata`, `para`)
  traverse trees. `Base.:(==)(a::JoinNode, b::JoinNode) = a.spec === b.spec && a.left == b.left
  && a.right == b.right` follows the existing `StepNode` rule (`step ===`, src/lazy/plan.jl), so
  the optimizer's fixpoint check sees an unchanged join as unchanged.
- **The name map is resolved once, at `JoinNode` construction, from the unprojected schemas
  (critic M3).** Each side's schema is its subplan applied to the empty frame of its source schema
  (the probe technique of `render_kernel`, src/lazy/render.jl). `JoinNames` records:
  - the resolved key pairs (including `by = nothing`);
  - every output name and its source (side, column), including a `nest_join` `name` that
    replaces an x column (§1.5);
  - the clashing names;
  - each pair's compare type **only when both key types are static** (below), else `nothing`.

  The output names never depend on later projection, and **must not depend on types**: the probe
  is trusted for names only.
- **Static key types (critic pass 3 MAJOR-1).** The empty-frame probe's column types are not
  the data's types after a `mutate` (an empty input gives no evidence about `f.(c.a)`), so they
  are never used for key types. A side's key types are **static** only when `node_schema` of that
  side's subplan (src/lazy/plan.jl) returns its schema: it does so only through name-only steps
  and filters over a source schema, where the types are proven (`name_map` accepts only
  name-only steps, src/lazy/plan.jl). p4-join adds `node_schema(::JoinNode)`: it returns the
  join's output schema (types by §1.1's static rules) only when both sides' `node_schema` do,
  so a join of static joins stays static. Then:
  - both static: the compare type and the N1/n6 checks are resolved at `JoinNode` construction
    (as before), and the N2 key pushdown may fire (§1.3);
  - otherwise: `JoinNames` stores no compare type, the N2 key pushdown does not fire, and at
    `collect` the lowering **collects every side whose key type is not static before choosing
    the shape**. The collected frame's column types (probed equal to eager's for the subplan, and
    checked by the join comparator, MAJOR-4b; CF-008's `isequal` alone does not see types) give
    the compare type and run the N1/n6 checks, raising the eager
    `ArgumentError` there. The collected side is then replaced by `lazy(collected)` (a
    `FrameSource`, exact rows and types), so it can still stream as a probe side, and
    `join_decision` sees exact estimates for it.
  - Test (lazy == eager, every `_FORCE_JOIN` value, morsel sizes 1–7): with
    `f(a) = a > 1 ? 1.5 : 1`, `lazy(Frame(a = [1, 2])) |> mutate(:k => f.(c.a)) |>
    inner_join(Frame(k = [1.5]); by = :k)` against the same pipeline on the eager frame. Per
    morsel, the key column would be `Int` in one morsel and `Float64` in the next; the test
    asserts that lazy gives eager's result or eager's exception type, whatever eager's key
    column type is (UNVERIFIED here which; the test records it).
- **Optimizer, tree-aware:**
  - Constant folding, filter splitting and the phase-3 pushdown rules run in each subtree.
  - Projection pushdown runs per side. Each side supplies its keys, the columns read above
    (mapped through `JoinNames`), and **every clashing column, on both sides**, so a suffix never
    disappears. Example: for x(k, v), y(k, v), `inner_join(y; by = :k) ⨟ select(:v)` throws
    in eager (`v` is `v_x`/`v_y`), and lazy must keep `y.v` and throw too.
  - The hidden columns (§1.2) are added by the lowering, after every pass, so no pass sees them.
  - A side whose schema cannot be computed statically (the probe throws) is not projected. Its
    `JoinNames` is then resolved at collect time, and that is when the natural-join message is
    logged (§1.1, n9). The N1 key-type check and the n10 hidden-name check also run then.
- **Lowering for execution** (`src/lazy/joins.jl`): before `physical`, the cost stage calls
  `join_decision` (§1.2) for every `JoinNode`, innermost first, and the node becomes one of the
  three shapes of §1.2:
  - (a) broadcast, build y: `StepNode(ProbeStep(:y, build, spec, names), left)`, with
    `JoinTailStep` above it when §1.2 says so; `build` is the right subplan;
  - (b) broadcast, build x: `StepNode(JoinTailStep(...), StepNode(ProbeStep(:x, build, spec,
    names), right))`; `build` is the left subplan, and the right subplan is the streamed input;
  - (c) partitioned: `StepNode(PartitionedJoinStep(right, spec, names), left)`.
  - At `collect`, the lowering first collects every side whose key type is not static (above),
    then executes the build side's subplan, then picks broadcast or partitioned from its
    collected size (§1.2 step 4), and only then builds the physical steps. Under (c) the already
    collected side is passed to `PartitionedJoinStep` (never executed twice); the other side is
    gathered (x) or collected (y). Every choice gives the same result.
  - **Unguarded inner execution (critic pass 3 m6):** the lowering runs a subplan with
    `execute(physical(lower(sub)))`, **without** the CF-008 replay guard. Only the top-level
    `collect` guards, so a failure anywhere in the tree replays the whole unoptimized plan
    eagerly once (no nested replays).
  - The lowering is one package function (e.g. `_lower_joins(plan)` in `src/lazy/joins.jl`);
    the join property tests' raw runner calls it, never a copy (§4).
  - `explain` prints the subplans and does not execute them.
  - `cross_join` lowers to `StepNode(ProbeStep(:y, collected y, spec, names), left)` with no hash
    table and no tail (§1.5).
- **Replay (`reference`)** handles trees: a `JoinNode` replays as an internal apply of `spec` with
  the resolved `JoinNames` to `reference(left)`, with `y = reference(right)` (no second
  `@info`, and no second nest_join `@warn`). It **recomputes the compare type** (and the N1/n6
  checks) from its own frames' column types and never reuses the one in `JoinNames` (critic
  pass 3 MAJOR-1).
- **`explain`:**
  - The logical and optimized plans are drawn as trees (box-drawing `├─`/`└─`, the prototype's
    printer style): `join(inner; by = [:a => :b])` with `x:` and `y:` children. Linear plans
    print exactly as before.
  - The physical section names, from `join_decision`: the strategy (`broadcast` /
    `partitioned into 2ᵖ`), the build side and its estimated rows and bytes (or "unknown"),
    which side the probe streams (shape a: x; shape b: y; shape c: none, both gathered), the
    build subplan, the tail or partitioned step when there is one, and whether the
    order-restoring sort runs (shapes b and c). It says "predicted from estimates; confirmed on
    the collected build side" and, when forced, `forced by _FORCE_JOIN`.
  - The rendered-kernel section for a stage holding a `ProbeStep` prints
    `not rendered (the stage holds a join probe)` instead of `none (no streamed stage)`
    (src/lazy/explain.jl; `render_kernel` returns `nothing` there).
  - Snapshot-tested on stable Julia in the new directory test/snapshots/lazy_join/.

### 1.5 Parity rows in this phase (★ K3: the full matrix)

Phase 4 ships the six keyed joins (§1.1), `nest_join`, `cross_join`, `join_by` (equality pairs)
and the seven DataAPI methods (§1.1). Inequality and rolling `join_by` stay **deferred: no
design exists** ([parity-dplyr.md](../../research/parity-dplyr.md) "UNVERIFIED" list).

- **`nest_join(y; by = nothing, keep = false, name = :y, na_matches = :na, unmatched =
  :drop)`**, dplyr 1.2.0's `nest_join(x, y, by, copy, keep, name, ..., na_matches, unmatched)`
  (formals verified, §1.6). It returns a `JoinStep` of kind `:nest`.
  - **Output column (the tidyr `nest` representation, verified to exist):** x's columns in
    order, then one column `name`: an `ObjectColumn` whose element type is `Frame`, exactly
    what `nest` builds (src/engine/verbs_nest.jl `apply(::NestStep, …)`:
    `ObjectColumn(Frame[take(sub, m) for m in members])`; `ObjectColumn` in src/columns.jl). So
    `unnest(name)` already accepts it (`_istable_el(::Frame)`), and no new list-column support
    is needed. `ListColumn`/`StructColumn` are not used: a nested table is a `Frame` element, as
    for `nest`.
  - **Each element** is a `Frame` of the y rows matching that x row, in y order (verified:
    y keys `[2, 1, 2]` give the x row with key 2 the `w` values `[1, 3]`). Its columns are y's
    non-key columns under `keep = false`, or all of y's columns (keys included, each with its own
    type, unconverted) under `keep = true`, in y's order. Names inside the nested frame never get
    a suffix (verified: x and y both have `v`, and the nested frame keeps `v`). The nested
    columns keep y's column types and kinds: they are `take`s of y's columns, so no `Missing` is
    added.
  - **No match:** a 0-row `Frame` with the same names and column types (`take(ysub, Int[])`, as
    `nest` builds an empty member). dplyr gives a `tibble [0 × 2]` with `w <dbl>, v <chr>`
    (verified). A 0-row x gives a 0-row result that still has the `name` column (verified).
  - **Keys:** `by` as for every join (§1.1, compare type included). The output key under
    `keep = false` has the compare type: dplyr converted an integer x key to `<dbl>` against a
    double y key (verified). `na_matches = :never`: a `missing` or NaN x key gets an empty frame
    (verified: NA and NaN rows give 0-row frames).
  - **`unmatched = :error` checks y only:** "Each row of `y` must be matched by `x`" (verified).
    Under `na_matches = :never`, a y row whose key holds `missing` or NaN matches nothing and so
    counts as unmatched (critic pass 3 m9; dplyr verified: y k = [1, NA] raises "Row 2 of `y`
    was not matched"). In shape (a) its key id is never marked: such y rows get no key id in the
    build table, and the tail treats a y row with no key id as unmatched.
    An x row with no match is never an error; it gets an empty frame (verified). There is no
    `multiple` (dplyr rejects it: "`...` must be empty", verified) and no `suffix`.
  - **Rows:** each x row once, in x order. A grouped x keeps its groups (verified); a grouped y
    is ungrouped first, so the nested frames are ungrouped (verified).
  - **Element type** of the `name` column: `Frame`, never `Union{Missing, Frame}` (every x row
    gets a frame), static by kind.
  - **Divergences (recorded in parity-dplyr.md by p4-join):**
    - dplyr's default `name` is the deparsed `y` argument (verified: `nest_join(x, yy)` names the
      column `yy`). A Julia function cannot see the argument expression, so the default is
      `:y`, as the parity matrix already sketches;
  - **`name` equal to an x column (user, phase-4 ★, 2026-10-26):** as dplyr, the nested column
    replaces x's column (verified: x's column `y` is lost), so the result is identical to dplyr's.
    ChuiFrames adds a warning: a `@warn` log record (silenceable with `with_logger`) naming the
    overwritten column. This is a "warning added" note in parity-dplyr.md, not a divergence.
    Details (critic pass 3 m1, m2; dplyr 1.2.0 verified 2026-10-26):
    - the nested column takes the **replaced column's position** (x(a, y, k) with
      `name = "y"` gives `a y k`);
    - `name` equal to x's **key column** under `keep = false` replaces the key too (x(k, v) with
      `name = "k"` gives `k v`, `k` a list column); `JoinNames` maps that output name to the
      nested column, so no key predicate is pushed through it (§1.3 must-not-fire case);
    - `name` equal to a **grouping column** keeps the grouping, which is now by the list column
      (dplyr: `group_vars` is still `"v"` and `v` is a list). The group index is rebuilt over
      the `Frame` elements, whose `isequal`/`hash` are by value (src/frame.jl), so two x rows
      with equal nested frames share a group;
    - `name` starting with `##chui_` → `ArgumentError` (§1.2 hidden columns, m9);
    - the `@warn` follows the n9 rule (m2): logged **once, when `JoinNames` are resolved**
      (eager apply, `JoinNode` construction, or `collect` when a schema is not static), and
      never again in `optimize`, `collect` or replay.
  - **Physical shapes (§1.2):**
    - (a) build y: per x morsel, each x row's chain gives `take(ysub, rows)`, one `Frame` per x
      row (an allocation per row, measured by p4-bench). Under `unmatched = :error` the probe
      also emits the hidden `Symbol("##chui_ykey")` (the matched y key id, `0` = none), and a
      `JoinTailStep` marks the matched key ids, raises for the first y row (in y order) whose key
      id is unmarked, and drops the hidden column. Otherwise there is no tail and x streams.
    - (b) build x and (c) partitioned: the left join's pairs, sorted (§1.2 shape b steps 1–5;
      the y-side check uses `yord`), then one `Frame` per x row from its run (`take` of the
      gathered or collected y columns), and an empty frame for an x row with no run.
  - Pushdown: §1.3 (x only; never a filter on the nested column).
- **`cross_join(y; suffix = ("_x", "_y"))`** (critic n10). It returns a `JoinStep` of kind
  `:cross` with no keys and no `na_matches`/`keep`/`multiple`/`unmatched`, as dplyr's
  `cross_join(x, y, suffix)`.
  - Output: x's columns, then all of y's columns. Clashing names get `suffix`.
  - Rows: |x| × |y|, in x order, each x row's block in y order.
  - Element types are unchanged (no row is unmatched). A grouped x keeps its groups.
  - Lazily it is a `ProbeStep` whose "build" is the collected y (no hash table, streamed over x
    morsels, no tail), so its output is in dplyr's order with no sort. ADR-0003 rule 4's
    build-side choice is about hash tables, and a cross join has none: the output has |x| × |y|
    rows, so materializing y never costs more than the output. `_FORCE_JOIN` does not apply.
    Filter pushdown sends a one-side filter to that side (cross joins are total).
  - `DataAPI.crossjoin(x::Frame, y)` forwards to it.
- **`join_by(keys...)`, equality pairs only.** It returns a `JoinBy` value holding the resolved
  key list. It accepts `:a`, `"a"`, `:a => :b`, `"a" => "b"` and vectors of those (the same forms
  as `by`, §1.1), and prints as `join_by(:a => :b, :c)`. `by = join_by(:a => :b)` is the same
  join as `by = :a => :b`; every verb, including `nest_join` and the DataAPI methods' `on`,
  accepts it.
  - **The `a == b` form is not shipped.** Plain `c.a == c.b` returns a `Bool` (CF-005; ADR-0002
    "Alternatives rejected"). The dotted `c.a .== c.b` does build a node, and recognising a lone
    `==` of two `Col`s would be simple. But it would fix a side convention (left operand is x,
    right is y, both written `c.`) before the inequality/rolling design, which parity-dplyr
    constraint 5 says needs explicit sides. It also adds nothing over `:a => :b`. So it is
    deferred with that design. A node passed to `join_by` → `ArgumentError` pointing to
    `:a => :b`.
  - **Deferred, no design exists:** inequality (`join_by(a >= b)`) and rolling/overlap helpers
    (`closest`, `between`, `within`, `overlaps`).

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
  double key gives a `numeric` output key (ChuiFrames follows, ★ K4: compare type `Float64`,
  §1.1). With `keep = TRUE` the two keys keep their types: `k.x` integer, `k.y` numeric.
- R integers are 32 bits. A `bit64::integer64` key against a double key is rejected: "Can't join
  `x$k` with `y$k` due to incompatible types. `x$k` is a <integer64>. `y$k` is a <double>."
  So the 2⁵³ behaviour (§1.1) has no dplyr counterpart and is tested against the oracle only.
- `nest_join` (the facts §1.5 relies on; scratch-directory run 2026-10-26, Rscript, dplyr 1.2.0):
  - formals `x, y, by, copy, keep, name, ..., na_matches, unmatched`; `multiple = "first"` →
    "`...` must be empty";
  - x(k = 1L, 2L, 3L, NA), y(k = 1, 1, 3, NA): column `y` of `<tibble [2 × 2]>`,
    `<tibble [0 × 2]>`, `<tibble [1 × 2]>`, `<tibble [1 × 2]>`; the empty one is a
    `tbl_df` with `w <dbl>, v <chr>`; x's key became `<dbl>`; nested columns `w`, `v` with no
    suffix although x has `v`; `keep = TRUE` nests `k w v`;
  - `na_matches = "never"`: nested row counts `2 0 1 0`; NaN x key: `1` under the default, `0`
    under `"never"`;
  - `unmatched = "error"` with every y row matched and x row 2 unmatched: no error; with a
    y row unmatched: "Each row of `y` must be matched by `x`. Row 2 of `y` was not matched.";
  - grouped x keeps `group_vars` `"v"`; a grouped y nests plain `tbl_df`s;
  - an x column named `y` is silently replaced by the list column; the default name of
    `nest_join(x, yy)` is `yy`; a 0-row x gives a 0-row result with the list column;
  - y keys `[2, 1, 2]`: the x row with key 2 nests `w = [1, 3]` (y order).
- Critic pass 3 checks (scratch-directory run 2026-10-26, Rscript, dplyr 1.2.0):
  - `inner_join(unmatched = "error", multiple = "error")`, y k = [1, 1]: x k = [2, 1] →
    "Each row of `x` must have a match in `y`. Row 1 of `x` does not have a match."; x k =
    [1, 2] → "Each row in `x` must match at most 1 row in `y`. Row 1 of `x` matches multiple
    rows in `y`." (one ascending x pass, whichever check fails first);
  - `nest_join` `name` clashes: x(a, y, k) with `name = "y"` → `a y k`; x(k, v) with
    `name = "k"` → `k v`, `k` a list; grouped by `v` with `name = "v"` → `group_vars` `"v"`,
    `v` a list;
  - `nest_join(na_matches = "never", unmatched = "error")`, x k = [1, NA], y k = [1, NA] →
    "Each row of `y` must be matched by `x`. Row 2 of `y` was not matched."
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
  key type. (★ K4: the join converts numeric keys to the pair's compare type before
  `typed_keys`, §1.1, so a join's `lookup` always sees one key type. The frozen signatures do
  not change; cross-type `lookup` stays supported.)
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
  *As built (p4-groupby2, review pass 2):* `_starts_radix` reads only partition 1's `ndistinct`
  for the key columns, before the partial phase, and only makes the merge partitioned from the
  start; each task still begins with one table and flushes it past the limit. The result never
  depends on it.
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
  within CC-004's tolerance (CF-008's approximate frame equality: `rtol = √eps(T)` of the
  input's float type, `atol = τ(agg, v)`; test/contracts/chui-core.md, "Float tolerance"). Integer
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
  - **Decline path (as built, p4-codegen; reviewer-approved):** when a computed value's type
    differs from the static type the interpreter's `typed_column` would narrow to (e.g. `c.y ./ 2`
    on `Int` columns), the kernel hands the morsel to the interpreter and rejects that shape and
    column types for the session. This is decided by types, not data, so nothing is lost; it is
    not counted in `_KERNEL_DISAGREE`.
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
      allowed cross-type pairs (`Int32`/`Float64`, `Int32`/`Int64`, `String`/`SubString`, and
      the ★ K4 pairs `Int64`/`Float64` and `Float64`/`Int64` with values at the 2⁵³ boundary)
      and empty tables, with x and y sizes drawn so that `:auto` picks either build side;
    - every keyed kind including `nest_join` (nested `Frame` elements compared frame by frame,
      names and column types included), plus `cross_join`;
    - **its own raw runner** (critic n8). LazyProp's `run_raw` calls `execute(physical(plan))`
      on a linear plan and cannot run join trees, so the join runner calls the **package's own
      lowering** (§1.4, `_lower_joins`; critic pass 3 m6, never a copy of it) and then
      `execute(physical(...))`, with no replay;
    - **its own comparator** (critic pass 3 MAJOR-4b), defined in this file (LazyProp stays
      read-only): `frames_agree`'s checks plus, for every column, `eltype` equality between lazy
      and eager, in every shape. `frames_agree` compares values with `isequal`, which cannot see
      `Int` vs `Float64` or a missing `Union{Missing, …}`; the static element types of §1.1 and
      the compare type of K4 are exactly what it must check.

    Cross-file reuse works: `@testmodule Oracle` (`test/engine/oracle.jl`) is used by
    `test/engine/property_tests.jl`.
  - Both run at morsel sizes 1–7, with `withforce(_FORCE_RADIX_SWITCH => 4)` and every
    `_FORCE_JOIN` value (`:auto`, `:broadcast_x`, `:broadcast_y`, `:partitioned_x`,
    `:partitioned_y`), at `-t 1` and `-t 4`. They compare with approximate frame equality,
    row order included (joins: with the eltype-checking comparator above), and also compare
    exception **types** only (critic pass 3 MAJOR-2: the raw runner has no eager replay, and a
    parallel shape-(a) run may name a different row than eager; `collect`'s replay gives eager's
    message, tested separately in the unit tests).
  - The MAJOR-1 test of §1.4 (a `mutate`d key whose type differs per morsel) is part of the join
    property file.
  - A Source whose partitions carry **permuted dictionaries** is included for the sink (M6).
- **Oracle:** `test/engine/oracle.jl` gains a nested-loop join reference (row loops, rule 8
  equality, dplyr order, `multiple`, `unmatched`, the compare-type conversion of §1.1, and
  `nest_join`'s nested frames), used by the join property tests and the 2⁵³ unit tests.
- **Differential:** joins against dplyr (`Rscript`, dplyr 1.2.0) and DuckDB/Polars (`uv`,
  pinned as in the existing suite) on generated data that includes `missing`, NaN, ±0.0,
  duplicates and empty inputs. DuckDB's and Polars' null-key semantics differ (the
  `na_matches = :never` equivalent). That is recorded as an encoded divergence in the new file
  docs/research/differentials-joins.md (created by p4-join). Grouped summaries already have
  differential coverage, and the new operator runs under it.
  - dplyr only: `nest_join` (nested frames compared per x row, as the tidyr nest differential
    test/engine/differential_tidyr_nest_tests.jl compares nested data), `cross_join`, and
    mixed integer/double keys (★ K4) with integer values inside R's 32-bit range (an R integer
    against a double; the 2⁵³ case has no dplyr counterpart, §1.6, and is checked against the
    oracle).
- **Unit:**
  - per accumulator against the protocol (§2.3);
  - radix stability;
  - the switch at 4 groups with `First`/`Last`/`ReduceM(string *)`;
  - each join kind × `na_matches` × `keep` × `multiple`/`unmatched` × every `_FORCE_JOIN`
    value;
  - `join_decision`: build side by estimated bytes (tie and unknown → y), nested columns giving
    unknown bytes, the broadcast limits, the forced values, and, **on inputs with exact
    estimates and static column types only** (critic pass 3 m4), that `explain` and `collect`
    report the same decision;
  - the error precedence (MAJOR-3), under every `_FORCE_JOIN` value, eager and through `collect`
    (message included): x k = [2, 1], y k = [1, 1] with `unmatched = :error, multiple = :error`
    raises the x-unmatched error for row 1; x k = [1, 2] raises the multiple error for row 1;
    the y-side error only after a clean x-side pass;
  - the order-restoring sort: shape (a) pairs are already sorted (`issorted`), shapes (b)/(c)
    restore (xrow, yrow) order with duplicates on both sides, and unmatched y rows come last in
    y order;
  - ★ K4: `_keypair_compare_type` for every pair class (identical, strings, lossless, lossy
    integer/float → `Float64`, `Union{}`, rejected `Date`/`DateTime`, `Int64`/`UInt64`,
    string/number); the 2⁵³ matches in both orientations; output key types under `keep = false`
    (`T`) and `keep = true` (unconverted);
  - `nest_join`: empty matches (0-row frames with y's names and types), `keep`, a `name` clash
    (x's column replaced as dplyr — differential — and the `@warn` naming it fires, `@test_logs`),
    the clash keeping x's position, `name` equal to a key column and to a grouping column
    (regrouped by the list column), `name = Symbol("##chui_…")` → `ArgumentError`, the `@warn`
    logged once (not again in `collect` or replay),
    `na_matches = :never` (y rows with `missing`/NaN keys count as unmatched under
    `unmatched = :error`), y-only `unmatched`, grouped x and y; on inputs with
    no clashing non-key names and a `name` that is none of x's names, `unnest(name)` of the
    result equals the inner join (clashes are excluded because the inner join suffixes and
    `unnest` refuses duplicate names, and a `name` in x's names replaces an x column);
  - semi/anti return x's key columns unconverted (x `Int64` vs y `Float64`);
  - `test/package_tests.jl` (MAJOR-4a): the ExplicitImports checks pass with the seven DataAPI
    join names in `INTERFACE`;
  - `join_by` forms equal the `by` forms; a node passed to `join_by` → `ArgumentError`;
  - the DataAPI methods forward `on` to `by` and the other keywords unchanged;
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
  - joins (inner, left; 1:1 and 1:n; broadcast and partitioned) at 10⁴/10⁶ rows, each with the
    build side forced to x and to y (`_FORCE_JOIN`), plus a small-x/large-y case (10³ × 10⁶)
    under `:auto`;
  - **the order-restoring sort (★ K2):** its cost measured on its own and as a share of the
    join, for inner and left joins at 10⁴/10⁶ rows in shapes (b) and (c), against shape (a)
    (where it is skipped), with 1:1 and 1:n matches; the result goes into the research doc and
    feeds the revisit trigger of §7;
  - `nest_join` at 10⁴/10⁶ x rows (one `Frame` per x row) and `cross_join` at 10³ × 10³;
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

Inequality and rolling joins (`join_by(a >= b)`, `closest`, `between`, `within`, `overlaps`) and
the dotted `join_by(c.a .== c.b)` form: no design exists (★ K3). Also: join reordering,
spilling, async I/O, `source_ordering`-based sort skipping, filters past total `mutate`s,
partially compiled stages (a compiled prefix before a non-whitelisted step), hashing x's keys
inside its streamed stage for the partitioned join, and a `Dict`-based join path for abstract key
types. Also deferred (critic pass-3 p1): per-key-column static types. `node_schema` is
all-or-nothing, so any upstream `mutate` (even one not touching a key) makes a side's key types
non-static and that side is collected before the join (correct, but shape (a) then does not
stream x).

## 7. Revisit triggers

- p4-bench measures the order-restoring sort above 25 % of a shape-(b)/(c) join's time, or a
  small-x/large-y join more than 2× slower than DuckDB → reopen the K2 shapes in ADR-0023 (for
  example a merge of per-partition sorted runs instead of a global counting sort).
- p4-bench's join with an upstream `mutate` (not on a key) is more than 1.5× slower than the
  same join without it → track static types per key column (§6, critic pass-3 p1).
- The user reports the 2⁵³ precision loss (★ K4) as a problem in practice → reconsider an
  opt-in strict mode that rejects lossy integer/float pairs.
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
| critic M7 ADR deviations | (i) DataAPI methods added; (ii) build side/partitioning and parity rows settled by the user's ★ K2/K3 (ADR-0003 kept; full matrix) | §0.4, §1.1, §1.2, §1.5 |
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
row's "`promote_type` + 2⁵³ caveat" is replaced by N1 (Int64/Float64 is now rejected). The ★ K4
answer (below) later allows integer/float pairs again, compared as `Float64`; the N1 and N2 rows
are amended there.

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
| n10 hidden-column collision; `cross_join` | a user column named `##chui_yrow` → `ArgumentError` (extended under ★ K2 to the reserved prefix `##chui_`); `cross_join` defined, shipped under ★ K3 | §1.2, §1.5 |

p4-groupby review (APPROVE WITH CONDITIONS, at 657cdaa), spec amendments by the sub-lead:

| Finding | Answer | Where |
|---|---|---|
| M1 `Union{}` (all-missing key) in the pair rule | pairs with any type; fixed in the lane | §1.1 |
| OQ1 `_lossless_key_promotion` location | `src/engine/hashagg.jl`; p4-join calls it | §1.1 |
| OQ2 string keys keep their type | `StringView` keys kept; hash agrees with `String`; the join builds the `String` output | §1.1 |
| OQ3 dictionary codes | `UInt32`, 0 = `missing` | §2.2 |
| OQ4 re-canonicalisation | `getorinsert!`/`lookup` canonicalise `k` | §2.2 |
| OQ5 / m4 / m6 radix bounds and wording | `p <= 20`, `ntasks >= 1`, memory bound, prefix order | §2.4 |

User ★ answers (2026-10-26, at the ChuiFrames phase-4 ★), folded in by the architect; p4-join
starts after the critic's FINAL on this revision:

| Item | Answer | What changed | Where |
|---|---|---|---|
| K1 join keyword | `by =` (dplyr parity) | the keyword placeholder → `by` everywhere; ADR-0002 rule 16 dated amendment (key forms `nothing` + `@info`, `:a`, `"a"`, `[:a, :b]`, `:a => :b`, vectors); DataAPI methods keep DataAPI's `on` (ADR-0007) and forward it to `by`; `by` is no longer a divergence | §0.4, §1.1, §1.4, docs/adr/0002-expression-grammar.md rule 16 |
| K2 build side, partitioning | ADR-0003 kept, no amendment | `join_decision` (build side by estimated bytes, tie/unknown → y; strategy confirmed on the collected build side); three shapes: (a) broadcast build y, x streams, sort skipped (pairs already ordered); (b) broadcast build x, y streams, `JoinTailStep` with `yord = cumsum(##chui_ystart)` and the stable counting sort by xrow; (c) partitioned, both sides `radix_partition`ed, `PartitionedJoinStep` in `rest`, same sort; strategy-independent error precedence; reserved `##chui_` prefix; `_FORCE_JOIN` ∈ `:auto`, `:broadcast_x`, `:broadcast_y`, `:partitioned_x`, `:partitioned_y`; old "always build on y" text and its option paragraph removed; p4-bench measures the sort | §0.3, §0.4, §1.2, §1.3, §1.4, §4, §5, §7 |
| K3 parity | full matrix in phase 4 | `nest_join` (object column of `Frame`s as tidyr `nest`; dplyr 1.2.0 semantics verified with Rscript, §1.6), `cross_join`, `join_by` equality pairs only (the dotted `==` form deferred with inequality/rolling: it would fix a side convention before that design), `DataAPI.crossjoin`; inequality/rolling deferred, no design | §1.1, §1.5, §1.6, §6 |
| K4 integer/float keys | allowed, compared as `Float64` | `_keypair_compare_type(Sx, Sy)` in hashagg.jl (p4-groupby2, merged first); keys converted before `typed_keys`/`keyhash`; 2⁵³ precision loss documented (no divergence); `Date`/`DateTime`, `Int64`/`UInt64`, string/number still rejected; 2⁵³ tests and a dplyr differential within R's 32-bit integers (dplyr rejects `integer64` vs double, verified) | §0.2, §1.1, §1.6, §2.2, §4 |
| N1 (pass 2) under K4 | amended | `Int64`/`Float64` moves from rejected to allowed (lossy, compare type `Float64`); the `isequal` ⇒ `keyhash` test runs after conversion | §1.1 |
| N2 (pass 2) under K4 | re-checked, holds | push a key predicate to x only when the compare type equals x's nonmissing type; 2⁵³ must-not-fire case and the `Float64`/`Int64` fires case | §1.3 |
| B1, M1, M3 (pass 1) under K2 | kept | totality unchanged and independent of the shape; hidden-column tails in every shape, no `execute.jl` change; names still resolved at `JoinNode` construction, hidden columns added only by the lowering | §1.2, §1.3, §1.4 |

Critic pass 3 (ACCEPT WITH CHANGES, at 8375452, which includes the coordinator's nest_join
name-clash edit: replace x's column with a `@warn`), answered 2026-10-26:

| Finding | Answer | Where |
|---|---|---|
| MAJOR-1 types after a `mutate` are not static; the empty-frame probe is untrustworthy for types | key types only from `node_schema` (proven static); otherwise compare type and N1/n6 resolved at `collect` from the collected side's types, collecting every non-static side before the shape is chosen (then streamed as `lazy(collected)`); `reference` recomputes the compare type from its frames; names still at construction and type-independent; N2 fires only with both key types static; `node_schema(::JoinNode)`; the `f(a) = a > 1 ? 1.5 : 1` lazy == eager test | §1.1, §1.3, §1.4, §4 |
| MAJOR-2 shape (a) "same row" claim (coordinator's decision) | claim dropped; lazy raises the same exception type; `collect`'s eager replay gives eager's message; the raw runner compares types only | §1.2, §4 |
| MAJOR-3 x-side check order | one ascending x pass before `multiple`, the first failing row raises whichever check it fails; y-side check after; dplyr verified (x k = [2, 1] vs y k = [1, 1] → "Row 1 of `x` does not have a match"); tested under every `_FORCE_JOIN` value | §1.2 (shape a, shape b steps 3–5, precedence), §1.6, §4 |
| MAJOR-4a ExplicitImports | `test/package_tests.jl` in p4-join's scope; exactly the seven DataAPI join names added to `INTERFACE`, citing DataAPI's source comment (no docstring, not `public`) and ADR-0007 | §1.1, §4, plan lanes table |
| MAJOR-4b `frames_agree` blind to eltypes | p4-join's own comparator in its own file adds per-column `eltype` equality in every shape; LazyProp read-only | §4 |
| m1 nest_join name clash details | position kept; `name` = key column replaces the key (pushdown must-not-fire case); `name` = grouping column regroups by the list column (value `isequal`/`hash` on `Frame`); `unnest == inner_join` property excludes any `name` in x's names; dplyr verified | §1.3, §1.5, §1.6, §4 |
| m2 nest_join `@warn` timing | the n9 rule: once, when `JoinNames` are resolved; never in `collect`/replay | §1.4, §1.5 |
| m3 semi/anti conversion | return x unconverted; x-column filters (keys included) push to x with no type condition | §1.1, §1.3 |
| m4 explain == collect decision | tested only on exact estimates and static types; may differ otherwise, harmlessly | §1.2 step 5, §4 |
| m5 `join_decision` inputs | `SideEstimate(rows, exact, coltypes)` per side; nested (`Frame`, vector, `NamedTuple`) columns give unknown bytes | §1.2 |
| m6 nested replay; runner copy | inner subplans run unguarded `execute(physical(lower(sub)))`, only the top-level `collect` guards; the raw runner calls the package's `_lower_joins` | §1.4, §4 |
| m7 no stubs (coordinator's decision) | p4-join's helper-dependent tasks wait for p4-groupby2 3a's merge; verbs, names, shapes on same-type keys and the oracle first | §0.2, plan |
| m8 shape (c) checks | partition probes raise nothing; all checks in the tail | §1.2 |
| m9 hidden names, `:never` y-check | `##chui_ykey` listed; `name` starting with `##chui_` rejected; under `na_matches = :never` nest's y-side check counts `missing`/NaN-key y rows as unmatched (dplyr verified) | §1.2, §1.5, §1.6 |
