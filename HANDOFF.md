# Handoff

The one handoff file for this repo. Update it before stopping, before a compaction, and at
every checkpoint. Keep it short; history lives in git and in ADRs.

## State

- **Branch:** `feat/phase4`, in worktree `.worktrees/phase4`, from `main` `bc8c97a`. **Not
  merged**; the ecosystem lead merges after the final review.
- **Phase:** phase 4: joins, the fast group-by with aggregate sinks, codegen kernels.
  - Spec: `docs/superpowers/specs/2026-10-26-phase4-joins-groupby-codegen-design.md`.
  - Plan: `docs/superpowers/plans/2026-10-26-phase4.md`.
  - ADRs 0023 (joins), 0024 (group-by and sinks), 0025 (codegen): **Proposed**. The user accepts
    them at the phase-4 merge ★.
- **Merged into `feat/phase4`.** Each lane merged `--no-ff`, after `scripts/lane audit` and a
  reviewer FINAL:

  | Lane | What | Merge commit |
  |---|---|---|
  | p4-groupby | typed keys, `KeyTable`, `radix_partition` | `3ef418f` |
  | p4-codegen | compiled stage kernels, `INTERP_THRESHOLD` = 5×10⁵ | `3a61c69` |
  | p4-groupby2 | fast `group_by`, hash-aggregate and grouped-window sinks, the K4 key helpers | `eb1cb5c` |
  | p4-join | joins: `by =`, nest/cross/`join_by`, DataAPI, three hash-join shapes, lazy join trees | `0db65f4` |
  | p4-gbfix | limit-path dictionary kinds, sinks behind compiled kernels, a whitelist-first kernel decision | `50dbf18` |

  The worktrees are removed; the branches are kept. Reviewer reports are in
  `ChuiFrames.jl/.lanes/reports/`, and lane evidence is archived under `.lanes/reports/lanes/`.
- **Upstream:** unchanged. The ChuiCore and ChuiTypes stand-ins stay (ADR-0014).

## Open lanes

| Lane | Agent | File scope | Status |
|---|---|---|---|
| p4-perf | implementer | `src/columns.jl`, `src/engine/{join_shapes,hashagg_sink,verbs_bind,verbs_groups}.jl`, `benchmark/budgets.toml`, named test files | starting |

## Evidence (`.lanes/evidence/`)

- **Integrated head `3bc2be9`** (every file `dirty: false`, exit 0):

  | File | Result |
  |---|---|
  | `tests-3bc2be9.txt` | 14510 |
  | `tests-t4-3bc2be9.txt` | 14511 |
  | `tests-lts-3bc2be9.txt` | 14462 |
  | `tests-diff-3bc2be9.txt` | 1970 |
  | `quality-3bc2be9.txt` | 17 |
  | `jet-3bc2be9.txt` | OK |
  | `guards-3bc2be9.txt` | OK |
  | `docs-3bc2be9.txt` | OK |

  The commits after `3bc2be9` are documentation only.
- **Allocation budgets:** `run.jl --check` allocations and memory are within budget on 1.13 and
  1.10 at p4-codegen's `f946f0d` (`bench-check-11{3,0}-f946f0d.txt`, archived). The n=10 breach
  at `54a1b20` was fixed in code; no budget was changed.
- **Timings** (TTFX, `run.jl` time rows): every run so far was at load 5–12, so the results are
  INCONCLUSIVE (user ruling).

## Decisions at the phase-4 ★ (2026-10-26, the user)

- **K1:** the join keyword is `by =`. Recorded as an amendment to ADR-0002 rule 16, plus an
  addendum for `join_by`.
- **K2:** ADR-0003 is kept as written: the cost stage picks the build side; above the broadcast
  limit both sides are radix-partitioned; a stable sort restores dplyr's row order.
- **K3:** full join parity: `nest_join`, `cross_join`, equality `join_by`, the DataAPI methods.
  Inequality and rolling joins are deferred (no design exists).
- **K4:** integer/float key pairs are allowed and compared as Float64; the precision loss above
  2⁵³ is documented.
- **`nest_join`:** a name clash replaces x's column, with a `@warn`.
- **ADR-0003 notes:**
  - rule 12: `INTERP_THRESHOLD = 500_000`; more than 50 operations instead of depth; unknown
    row counts run the interpreter unless the shape is cached;
  - rules 3 and 5 (phase 4): only simple aggregates over plain keys stream; MapM/ReduceM keep
    `Vector{Any}` task state;
  - rule 11: `:never` follows dplyr (NaN matches nothing), unlike DuckDB.
- **Timing checks** move to one quiet-machine run before the main merge. Allocation and memory
  checks bind in each lane.

## Open conditions (block the merge into main)

1. **Quiet-machine timings.** `benchmark/ttfx.jl --check` and `benchmark/run.jl --check` on 1.13
   and LTS, at 1-minute load < 2, at the final head. The ecosystem lead provides the window.
2. ~~p4-joinfix lands~~: done, merged in `a06a090` (reviewer APPROVE FINAL).
3. ~~p4-bench lands~~: done, merged in `5956626` (reviewer APPROVE WITH CONDITIONS FINAL).
   - It added 86 SUITE rows and 516 budget rows, tightened 21 rows, and set `RADIX_SWITCH` to 2²⁰.
   - The DoD `tests` check was waived in the merge commit: the only src change is that constant.
4. **p4-perf lands** (approved by the ecosystem lead). It fixes:
   - the quadratic concatenations in `vcat_columns` and `_partitioned_join`, plus the same
     `init` pattern in `verbs_bind.jl` and `verbs_groups.jl`;
   - the per-row allocation of String keys in the sink.

   Then it re-tightens the memory and time rows of the join, lazy-join and lazy-gather budgets
   (p4-bench review MINOR-5).
5. **`julia scripts/ci.jl bench` against `main`**, in the quiet window (p4-bench review MINOR-4).
6. **ADR-0022 rule 1's "public API only":** the SUITE now uses the internal switches
   `_FORCE_JOIN`/`_FORCE_KERNEL` (p4-bench review MINOR-3). A dated note needs the
   user/lead decision.
7. **Reviewer APPROVE (FINAL)** on the full `main...feat/phase4` diff, and `dod.jl`.
8. **The user accepts ADRs 0023–0025** at the phase-4 merge ★.

## Process deviations

- p4-bench edited new `benchmark/compare` files with a `python3` heredoc before their first
  commit, against the Edit/Write-only rule. The reviewer read the committed content: sane.
- The phase-4 seam's first `src/lazy/execute.jl` edit (`b51ca4e`) was made by a script. The
  reviewer diffed it line by line against `bc8c97a`: clean.

## Follow-ups (phase 5 or later)

- **Group-by:** stream the eager fallbacks (holistic aggregates, computed keys, `across`, a row
  limit, grouped scans) and give MapM/ReduceM typed task state (lifts the ADR-0003 rule 3/5
  notes).
- **Joins:**
  - per-key-column static types: any upstream `mutate` now collects that side before the join;
  - an x key held as an `ObjectColumn{SubString}` keeps that kind on inner/left/nest joins;
  - the eager probe never runs in parallel;
  - the partition bits `p`, and the eager spawn trigger `nx + ny >= 65_536` (p4-bench
    recommends);
  - no compiled prefix kernel before a join probe.
- **Codegen:** the research note's caveats (proxy compile times, measured at `-t 1` only).
- **Sinks:** for `drop = false` queries, pruned partitions are still read in full; reading only
  their dictionaries would be cheaper. `explain`'s "pruned" count then overstates the saving.
- **Carried from phase 3:** filters past provably total `mutate`s; sort skipping from
  `source_ordering`.

## Next action

1. Run lane p4-perf, then merge it after its reviewer FINAL.
2. Run `dod.jl` and the full gates at the final head.
3. Ask the ecosystem lead for the quiet window.
4. Run the final reviewer on `main...feat/phase4`.
