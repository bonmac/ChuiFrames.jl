# ADR-0024: Group-by runs on typed keys in an open-addressing table; lazy summaries of simple aggregates run in a two-phase, order-preserving hash-aggregate sink with an adaptive radix switch

- **Status:** Proposed (2026-10-26)
- **Date:** 2026-10-26
- **Deciders:** the lead (design, spec §2, critic-reviewed); acceptance of this record: the
  ecosystem lead or the user
- **Scope:** ChuiFrames.jl

## Context

Phase 4 makes group-by fast (DESIGN §7 item 2). Before it, eager `group_by` coded each key
column through a `Dict` and combined columns through `Dict{Tuple{Int,Int}}` codes, and lazy
grouped summaries ran on the gathered frame. The design is spec
`docs/superpowers/specs/2026-10-26-phase4-joins-groupby-codegen-design.md` §2; this ADR records
it as built on `feat/phase4` at 50dbf18 (lanes p4-groupby 3ef418f, p4-groupby2 eb1cb5c, p4-gbfix
50dbf18). It implements ADR-0003 rules 5, 6, 8, 9 and 10 and **refines** rule 3: rule 3 makes
every lazy grouped summary a hash-aggregate sink; here only simple aggregates are (rule 4 below).
No ADR-0003 rule is amended. Code: src/engine/{hashagg,hashagg_acc,hashagg_sink,radix,groups}.jl,
src/lazy/{sinks,execute}.jl.

## Decision

**Keys (frozen API, spec §2.2)**
1. `typed_keys(cols, n; codes)`, `keyhash`, `keyhashes`, `KeyTable{K}` (open addressing, linear
   probing, load ≤ 0.5, home slot from the **low** hash bits), `getorinsert!`, `lookup`,
   `keyvalues` are frozen; a signature change **must** go through a spec amendment. Keys are
   canonical (rule 8: ±0.0 one key, NaN payloads one NaN, `missing` its own key); several key
   columns form a concrete `Tuple`. A `DictColumn` within one frame keys by `UInt32` codes
   (0 = `missing`), across frames by value. An abstract element type makes `typed_keys` return
   `nothing`: group-by then uses the `Dict`-coded path, a join raises `ArgumentError`.
2. `radix_partition(hashes, p; ntasks)` (src/engine/radix.jl) is the **one** radix primitive
   (rule 10), shared by the sink and the partitioned join: a stable counting scatter on the
   **high** hash bits, `0 ≤ p ≤ 20`.

**Eager**
3. `build_gindex` **must** build the `GroupIndex` from typed keys with an unchanged meaning
   (ids, perm, starts, ascending keys, first-seen ±0.0); abstract key types and `drop = false`
   with dictionary keys keep their existing paths. Eager grouped `summarise` **must** keep the
   same Base call on the same values in the same order per group (bitwise equal to phase 3);
   typed accumulators are lazy-only.

**Lazy: the hash-aggregate sink**
4. `group_by ⨟ summarise` (and `summarise(...; by)`) **must** run in the sink when every output
   is a simple aggregate (one `Reduce` whose aggregator is not `Holistic` or `NDistinct`, over
   `Col` or `SkipMiss(Col)`, or `n_rows()`), every key is a plain column of the streamed stage
   and the summary directly follows it (`_hashagg_plan`); otherwise the eager path runs on the
   gathered frame and `explain` names the reason.
5. Accumulators are typed per aggregator where a concrete state type exists: `Sum` and `Prod`
   take Base's one-element `sum`/`prod` result type (so `Int8`/`Bool` widen to `Int`); `Mean`
   **must** use a float sum plus an `Int` count (no overflow); `Spread` uses Welford's update
   per row and Chan's merge per run; `First`/`Last` keep order stamps. As built, `Vector{Any}`
   state is used by `MapM`, `ReduceM`, any other aggregator, and element types with no common
   concrete type.
6. Each task owns a contiguous morsel range and its own `KeyTable`. Dictionary keys **must** be
   remapped per morsel to one global value-keyed dictionary (once per distinct local code).
7. **Adaptive switch.** A task table past `RADIX_SWITCH = 2¹⁶` groups (pending p4-bench
   calibration; `_FORCE_RADIX_SWITCH` in tests) **must** flush its accumulators as a run stamped
   `(range, seq)` ahead of later rows; the merge combines each group's accumulators in
   `(range, seq)` order per radix partition. As built, `_starts_radix` reads only partition 1's
   `ndistinct` before the partial phase and only makes the merge partitioned from the start;
   the result never depends on it.
8. The output is sorted ascending by key value (CF-008), with each group's raw first-seen key;
   empty groups and empty input follow CC-006/CC-007.
9. **Floats.** Lazy float results **must** agree with eager within CC-004's tolerance
   (`rtol = √eps(T)`, `atol = τ(agg, v)`); integer, `Bool`, string, `first`/`last`,
   `minimum`/`maximum` results are exact.
10. **Grouped-window sink.** A lazy grouped `mutate` materializes, builds the index, runs the
    existing `apply(::MutateStep)` per contiguous group range, one task each, and scatters back
    in row order; the column type is `promote_type` over non-empty ranges.
11. **Dictionary levels (CF-008).** When a later step shows levels (`group_by(drop = false)` or a
    `drop = false` scan; `_needs_levels`), partitions pruned by statistics and partitions an
    early-stopped limit never reached **must** be read for their column kinds (an empty slice
    through the stage), as eager `read_source` reads every partition.

## Alternatives rejected

| Alternative | Why rejected |
|---|---|
| Typed accumulators in eager `summarise` too | Critic M5: pairwise `sum` and two-pass `var` differ from a fold; eager would stop being bitwise equal to phase 3. |
| `add_sum` integer sum for `Mean` | Critic N4: overflows on `Int` data; `UP.Mean` uses a float sum plus a count. |
| Group by per-morsel dictionary codes | Critic M6: per-batch Arrow dictionaries differ or are permuted; one value would split. |
| A `Dict` per task | Boxes keys and allocates per insert (EN-05); the old eager path allocated per row (evidence below). |
| Radix only from source statistics | Most sources report no `ndistinct`; the switch must trigger on observed groups (rule 9). |
| A second radix routine for joins | ADR-0003 rule 10; critic B3. |

## Consequences

- Joins use the same keys and radix primitive (ADR-0023), so key semantics agree.
- `drop = false` queries read pruned and unreached partitions in full (dictionary-only reads are
  a follow-up); `explain`'s "pruned" count then overstates the saving.
- **Owed before main (ADR-0022 rules 5, 6):** p4-groupby2 changed the engine but ran no
  `run.jl --check`, only a scratch benchmark; `benchmark/budgets.toml` is unchanged on the
  branch, so allocation rows that fell by more than half (e.g. eager `group_by` at 10⁶ rows)
  are not yet tightened. Whether the `summarise` rows fell that far is UNVERIFIED.
- Open: the sink's output element types come from a zero-row `vcat_columns`; `RADIX_SWITCH` and
  2ᵖ are uncalibrated until p4-bench; the `Vector{Any}` fallbacks of rule 5 are slow paths.
- `hashagg.jl` was split three ways to stay under the 600-line `src/*.jl` ratchet.

## Verification

- Eager `group_by` before/after (main checkout, gitignored, `dirty: false`; a scratch
  BenchmarkTools script on a shared machine, not `run.jl --check`):
  `.lanes/reports/lanes/p4-groupby2/evidence/bench-n10-before-3ef418f.txt` and
  `bench-n10-after-36d79f9.txt`. Read the numbers there; they are not retyped here.
- Reviewers (main checkout `.lanes/reports/`): `reviewer-p4-groupby.md` (`-t 4` radix,
  canonicalisation and `KeyTable` growth probes), `reviewer-p4-groupby2-pass2.md` (APPROVE WITH
  CONDITIONS, FINAL at 36d79f9), `reviewer-p4-gbfix-pass2.md` (APPROVE FINAL at 12bf9fc: the
  limit-path dictionary kinds, sinks behind a forced compiled kernel).
- UNVERIFIED: `RADIX_SWITCH = 2¹⁶` as the right limit on this hardware (p4-bench).

## Revisit when

- p4-bench calibrates `RADIX_SWITCH`, or finds the sink slower than the gathered eager path at
  any measured size → change the constant line (p4-bench's scope) or the routing.
- A source reports `ndistinct` for every partition → let `_starts_radix` start tasks in radix mode.
- A `drop = false` query with pruned partitions is more than 2× slower than the same query with
  `drop = true` → read dictionaries only.
- A `MapM`/`ReduceM` sink row is more than 3× slower than eager → typed state for them.
- A frozen signature (rules 1, 2) must change → spec amendment, then this ADR.
