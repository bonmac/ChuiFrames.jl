# Handoff

The one handoff file for this repo. Update it before stopping, before a compaction, and at
every checkpoint. Keep it short; history lives in git and in ADRs.

## State

- **Branch:** `feat/phase1-research`, in worktree `.worktrees/phase1-research`, from `main`
  `d778f93`. **Not merged.** The phase-1 ★ is answered (2026-10-20); the lead merges.
- **Phase:** **phase 1 (Research and ADRs) done and accepted by the user.** Nothing is
  implemented; `src/` and the tests are unchanged.
  - Research is in `docs/research/` (index: `docs/research/README.md`): parity matrices for the
    9 R packages, Polars, the Julia frame packages and other engines; storage, dependency,
    Parquet/CSV, engine, grammar and source/sink notes; the lane owner's checks LC-01 to LC-09.
  - ADRs 0001–0020 are in `docs/adr/`, all **Accepted (2026-10-20)** (index: `docs/adr/README.md`).
  - The spec is `docs/superpowers/specs/2026-10-20-phase1-research-design.md` (accepted).
- **Upstream:** ChuiCore and ChuiTypes are not released, so there is still no upstream
  dependency. ADR-0014 and ADR-0015 define the adapters. ChuiCore's phase-1 ADRs (accepted
  2026-10-20) are reflected in ADR-0003 and ADR-0014.
- **Factory:** 0.2.5, profile `package` (`.factory-version`).
- **Remote:** none yet.

## Open lanes

| Lane | Agent | File scope | Status | Report |
|---|---|---|---|---|
| phase1-research | the phase-1 lane (lead's teammate) | `docs/adr/**`, `docs/research/**`, `docs/superpowers/**`, `HANDOFF.md`, `changelog.d/phase1-research.md` | ★ answered, ADRs accepted; waiting for the lead's reviewed merge | sent to the lead |

The phase's subagents (5 research lanes, 1 Parquet/CSV spike lane, 4 critics) all reported and
are closed. The roster is in the lead's phase report.

## Evidence

Commands run in this worktree on 2026-10-20:
- `julia --startup-file=no scripts/check_docs.jl`: `OK`.
- `scripts/lane audit phase1-research`: `OK`.
- `julia --startup-file=no scripts/dod.jl --base main`: the result is in the phase report.
- The research commands and their outputs are in each note's Evidence section. Scratch scripts
  stayed in the session scratchpad.

## Checks NOT run, and why

- `julia scripts/ci.jl test`, `jet`, `quality`, `format`: no code changed (docs only).
- `julia scripts/ci.jl contracts`: no upstream release exists.
- Benchmarks: none exist yet. Engine timings are research measurements on a shared machine
  (`docs/research/engine.md`), not a benchmark suite.

## Phase-1 ★: answered (user, 2026-10-20)

All recommendations accepted; ADRs 0001–0020 and the spec are **Accepted** as written:
1. **Arrow IPC reads:** ChuiFrames' own reader, behind a phase-2 spike gate with a fallback;
   Arrow.jl is the writer only (ADR-0001, ADR-0010).
2. **Parquet:** a package extension on Parquet2 (ADR-0020). Brief deviation, user-approved.
3. **Arrow writer:** stays in the core (ADR-0010).
4. **Morsel parallelism:** phase 3, not phase 5 (ADR-0003 rule 18). Brief deviation,
   user-approved.
5. **`rename`:** `new = :old`, as dplyr (ADR-0002 rule 15).
6. **`Not`:** from InvertedIndices (ADR-0008).

## Pending (lead)

- The lead files the cross-repo requests (a)–(e) drafted in the phase report.
- The `chui-frames.md` contract updates (Source/Sink, `code_lowered`, `arrange` order) go to
  the user as a T3 change.
- Still the lead's call: the CF-001 reading for DataAPI interop methods (ADR-0002 rule 5);
  ordered-factor sort order vs CF-008 (ADR-0001 rule 5).

## Next action

Once the lead merges `feat/phase1-research` through a reviewed PR: phase 2, "Eager frame" (per
`docs/agent/BRIEF.md`), starting with the own-IPC-reader spike (ADR-0001 rule 10) and the plan
outlined in the spec.
