# Phase 2b (the rest of the eager frame): plan

- **Date:** 2026-10-20. **Branch:** `feat/phase2b-tidyr` (lane `phase2b-tidyr`), from `main` `1a2f1eb`.
- **Tier:** T2 (public API, one new ADR). **Spec:** the accepted phase-1 spec
  ([2026-10-20-phase1-research-design.md](../specs/2026-10-20-phase1-research-design.md)), ADRs
  0001–0020, and the new ADR-0021 (timestamps). No other spec: the verbs implement accepted rows
  of the parity matrices ([parity-tidyr.md](../../research/parity-tidyr.md),
  [parity-dplyr.md](../../research/parity-dplyr.md)).
- **Inputs:** `HANDOFF.md` "Remaining in phase 2", the open review MINORs, ChuiCore notes
  (first-n rows through `Take`/`foldxl`; typed style arguments on instances).

## Order (the lead's)

1. **ADR-0021, `ArrowTimestamp`** (ADR-0001 rule 6). Research first (Julia side: Arrow.jl's
   `Timestamp` writer, Parquet2's timestamp decoding, CSV.jl, Dates hashing; producer side:
   Polars, pyarrow, R arrow, DuckDB semantics). Draft (Proposed) → read-only critic → iterate
   to no blockers → implement:
   - the type and its API in `src/timestamps.jl` (equality, hashing, order, conversion);
   - the IPC reader (`src/ipc/meta.jl`, `src/ipc/decode.jl`): Timestamp(s/ms/µs/ns, zone);
   - the Arrow writer adapter (`src/io/arrow.jl`): units and zones round-trip;
   - Parquet (`ext/`): µs/ns and UTC-adjusted columns read exactly (no truncation);
   - CSV (`src/io/csv.jl`): sub-millisecond digits and the written text form;
   - printing (`src/show/`), ingest (`column`), `vcat_columns`;
   - corpus cases from Polars, pyarrow and R arrow (`test/data/ipc/`, generator scripts
     extended), with pyarrow dumps as expected values.
2. **tidyr reshaping**, each differential-tested against tidyr 1.3.1 through `Rscript`:
   - `pivot_longer`, `pivot_wider` (`src/engine/verbs_pivot.jl`);
   - `separate_wider_delim`/`_position`/`_regex`, `separate_longer_delim`/`_position`, `unite`
     (`src/engine/verbs_strings.jl`);
   - `nest`, `unnest`, `unnest_longer`, `unnest_wider`, `pack`, `unpack`
     (`src/engine/verbs_nest.jl`);
   - `fill` (a method of `Base.fill` on nodes, CF-009), `complete`, `expand`, `nesting`
     (`src/engine/verbs_complete.jl`).
3. **The ranking tail:** `percent_rank`, `cume_dist`, `ntile`; `slice_sample(weight_by)`;
   `group_by(drop = false)`; `arrange(locale)`; `when_any`/`when_all`; the declared result type
   of `c.x |> f` (ADR-0002 rule 11 leaves its spelling to phase 2).
4. **The performance ADR and benchmarks** (ADR-0003 consequences): budgets from measurements.
5. **Polars and DuckDB verb differentials** (`uv`).

Items 4–5 go to a follow-up branch if items 1–3 make this branch too large to review.

## Lanes

The engine's shared entry (`src/engine/engine.jl`: includes and exports) is edited by this lane
only, before the sub-lanes start, so the sub-lanes own disjoint files. The guard hooks block
sibling worktrees, so each sub-lane builds in a scratch copy of this worktree; this lane copies
its files back and commits them.

| Sub-lane | Owns | Deliverable |
|---|---|---|
| `tidyr-pivot` | `src/engine/verbs_pivot.jl`, `src/engine/verbs_strings.jl`, `test/engine/tidyr_pivot_tests.jl`, `test/engine/tidyr_strings_tests.jl`, `test/engine/differential_tidyr_pivot_tests.jl` | pivots, separate_*, unite; unit + differential tests |
| `tidyr-nest` | `src/engine/verbs_nest.jl`, `src/engine/verbs_complete.jl`, `test/engine/tidyr_nest_tests.jl`, `test/engine/tidyr_complete_tests.jl`, `test/engine/differential_tidyr_nest_tests.jl` | nest/unnest*/pack/unpack, fill, complete/expand/nesting; unit + differential tests |
| `rank-tail` | `src/engine/interpreter.jl`, `src/engine/helpers.jl`, `src/engine/nodes.jl`, `src/engine/groups.jl`, `src/engine/verbs_groups.jl`, `src/engine/verbs_rows.jl`, `src/engine/verbs.jl`, `test/engine/rank_tail_tests.jl`, `test/engine/differential_rank_tail_tests.jl` | item 3 |
| `ts-corpus` | `test/data/ipc/**`, `test/ipc/**` | the timestamp corpus (Polars, pyarrow, R arrow) and its reader tests |

Outcome: items 1–3 are on this branch. Items 4–5 move to a follow-up branch.
| this lane | everything else in the file scope | ADR-0021 and its implementation, integration, gates, docs, HANDOFF, changelog |

## Definition of done

Tests on 1.13.2 and `+lts` (counts from evidence files); `test -- all`, quality, jet, format,
guards, docs; `dod.jl --base main` and `--base 1a2f1eb`; load time against ADR-0005 (0.5 s on
1.13, 0.8 s on 1.10); differential results; ADR-0021 with the critic's verdict; the reviewer's
FINAL verdict; the exported-name delta and the clash check; ★ questions; draft requests.
