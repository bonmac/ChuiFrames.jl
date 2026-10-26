# ADR-0024: Group-by runs on typed keys in an open-addressing table; lazy summaries of simple aggregates run in a two-phase, order-preserving hash-aggregate sink with an adaptive radix switch

- **Status:** Proposed (2026-10-26)
- **Date:** 2026-10-26
- **Deciders:** the lead (design, spec §2, critic-reviewed); the user (the ADR-0003 rule 3 and
  rule 5 notes, 2026-10-26, at the ChuiFrames phase-4 ★); acceptance of this record: the user,
  at the phase-4 merge ★
- **Scope:** ChuiFrames.jl

## Context

Phase 4 makes group-by fast (DESIGN §7 item 2). Before it, eager `group_by` coded each key
column through a `Dict` and combined columns through `Dict{Tuple{Int,Int}}` codes, and lazy
grouped summaries ran on the gathered frame. The design is spec
`docs/superpowers/specs/2026-10-26-phase4-joins-groupby-codegen-design.md` §2; this ADR records
it as built on `feat/phase4` at 50dbf18 (lanes p4-groupby 3ef418f, p4-groupby2 eb1cb5c, p4-gbfix
50dbf18). It implements ADR-0003 rules 6, 8, 9 and 10. Two departures are covered by the user's
dated notes on ADR-0003 (2026-10-26, phase-4 ★): the rule 3 note (only simple aggregates over
plain keys stream as hash-aggregate sinks; rule 4 below) and the rule 5 note (`Vector{Any}`
task state for `MapM`, `ReduceM` and other untyped aggregators; rule 5 below). Code:
src/engine/{hashagg,hashagg_acc,hashagg_sink,radix,groups}.jl, src/lazy/{sinks,execute}.jl.

## Decision

**Keys (frozen API, spec §2.2)**
1. `typed_keys(cols, n; codes)`, `keyhash`, `keyhashes`, `KeyTable{K}` (open addressing, linear
   probing, load ≤ 0.5, home slot from the **low** hash bits), `getorinsert!`, `lookup`,
   `keyvalues` are frozen; a signature change **must** go through a spec amendment. Keys are
   canonical (ADR-0003 rule 8: ±0.0 one key, NaN payloads one NaN, `missing` its own key);
   several key columns form a concrete `Tuple`. A `DictColumn` within one frame keys by `UInt32`
   codes (0 = `missing`), across frames by value. An abstract element type makes `typed_keys`
   return `nothing`: group-by then uses the `Dict`-coded path, a join raises `ArgumentError`.
2. `radix_partition(hashes, p; ntasks)` (src/engine/radix.jl) is the **one** radix primitive
   (ADR-0003 rule 10), shared by the sink and the partitioned join: a stable counting scatter on
   the **high** hash bits, `0 ≤ p ≤ 20`.

**Eager**
3. `build_gindex` **must** build the `GroupIndex` from typed keys with an unchanged meaning
   (ids, perm, starts, ascending keys, first-seen ±0.0); abstract key types and `drop = false`
   with dictionary keys keep their existing paths. Eager grouped `summarise` **must** keep the
   same Base call on the same values in the same order per group (bitwise equal to phase 3);
   typed accumulators are lazy-only.

**Lazy: the hash-aggregate sink**
4. A summary **must** run in the sink (`_hashagg_plan`, src/lazy/sinks.jl) if and only if all hold:
   no row limit in the stage; an ungrouped scan; it directly follows the streamed stage as
   `group_by(keys) ⨟ summarise` (no `reframe`, no `by` on the `summarise`) or
   `summarise(...; by)`; plain key columns of the stage's output (no computed or selector keys)
   with concrete element types or dictionary columns; only `Pair` outputs (no `across`), each a
   simple aggregate (one `Reduce` whose aggregator is not `Holistic` or `NDistinct`, over `Col`
   or `SkipMiss(Col)`, or `n_rows()`). Otherwise the eager summary runs on the gathered frame.
   `explain` names the reason only when such a summary directly follows the stage and a
   condition other than the limit, the grouped scan, `reframe` or `by` after `group_by` fails.
5. Accumulators are typed per aggregator where a concrete state type exists: `Sum` and `Prod`
   take Base's one-element `sum`/`prod` result type (`Int8`/`Bool` widen to `Int`); `Mean`
   **must** use a float sum plus an `Int` count (no overflow); `Spread` uses Welford's update
   per row and Chan's merge per run; `First`/`Last` keep order stamps. `MapM`, `ReduceM`, any
   other aggregator, and element types with no common concrete type keep `Vector{Any}` task
   state (ADR-0003 rule 5 note).
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
10. **Grouped-window sink.** A grouped `mutate` after the stage (grouped frame, or `by`) **must**
    run in the sink only when more than one thread is available, at least one output is not
    row-wise, there is no `across` output, and the frame has more than one group and more than
    one range; otherwise `apply(::MutateStep)` runs on the whole frame. The sink runs the
    existing `apply(::MutateStep)` per contiguous group range, one task each, and scatters back
    in row order. A computed column's type is `promote_type` over non-empty ranges; when that
    type is abstract (and not `Union{Missing, T}` with `T` concrete), the values are narrowed
    by value, as `typed_column` does (`_scatter_column`).
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
| Radix only from source statistics | Most sources report no `ndistinct`; the switch must trigger on observed groups (ADR-0003 rule 9). |
| A second radix routine for joins | ADR-0003 rule 10; critic B3. |

## Consequences

- Joins use the same keys and radix primitive (ADR-0023), so key semantics agree.
- `drop = false` queries read pruned and unreached partitions in full (dictionary-only reads are
  a follow-up); `explain`'s "pruned" count then overstates the saving.
- **Owed before main (ADR-0022 rules 1, 3, 5 and 6; p4-bench):** p4-groupby2 changed the engine
  but ran no `run.jl --check`, only a scratch benchmark; `benchmark/budgets.toml` is unchanged
  on the branch, so allocation rows that fell by more than half (e.g. eager `group_by` at 10⁶
  rows) are not yet tightened, and whether the `summarise` rows fell that far is UNVERIFIED.
  Memory rose for the String and two-key `group_by` inputs in the scratch benchmark, so
  `run.jl --check` may flag memory rows (UNVERIFIED; p4-bench checks). `SUITE` rows for the lazy
  group-by and the `group_by` `n=10` row (spec §5) are also owed.
- Open: the sink's output element types come from a zero-row `vcat_columns`; `RADIX_SWITCH` and
  2ᵖ are uncalibrated until p4-bench.
- `hashagg.jl` was split three ways to stay under the 600-line `src/*.jl` ratchet.

## Verification

- Eager `group_by` before/after (main checkout, gitignored, `dirty: false`; a scratch
  BenchmarkTools script on a shared machine, not `run.jl --check`):
  `.lanes/reports/lanes/p4-groupby2/evidence/bench-n10-before-3ef418f.txt` and
  `bench-n10-after-36d79f9.txt`. Read the numbers there; they are not retyped here.
- Reviewers (main checkout `.lanes/reports/`): `reviewer-p4-groupby.md` (`-t 4` radix,
  canonicalisation and `KeyTable` growth probes), `reviewer-p4-groupby2-pass2.md` (APPROVE WITH
  CONDITIONS, FINAL at 36d79f9), `reviewer-p4-gbfix-pass2.md` (APPROVE FINAL at 12bf9fc: the
  limit-path dictionary kinds, sinks behind a forced compiled kernel); `critic-p4-adrs.md`.
- UNVERIFIED: `RADIX_SWITCH = 2¹⁶` as the right limit on this hardware (p4-bench).

## Revisit when

- p4-bench's lazy group-by rows (spec §5; owed) calibrate `RADIX_SWITCH`, or show the sink slower
  than the gathered eager path at any measured size → change the constant line (p4-bench's
  scope) or the routing.
- A source reports `ndistinct` for every partition → let `_starts_radix` start tasks in radix mode.
- A `drop = false` query with pruned partitions is more than 2× slower than the same query with
  `drop = true` (no row yet; p4-bench owes one) → read dictionaries only.
- A frozen signature (rules 1, 2) must change → spec amendment, then this ADR.
- **Phase-5 follow-ups (listed with the user's phase-4 ★ answer that accepted the narrowing of
  ADR-0003 rules 3 and 5 for phase 4; they lift those notes):** stream the eager fallbacks of rule 4 (holistic
  aggregates, computed keys, `across`, a row limit, grouped scans), and give `MapM`, `ReduceM`
  and the other untyped aggregators typed task state (rule 5); each lifts the matching ADR-0003
  note.
