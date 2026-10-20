# Handoff

The one handoff file for this repo. Update it before stopping, before a compaction, and at
every checkpoint. Keep it short; history lives in git and in ADRs.

## State

- **Branch:** `feat/phase1-research`, in worktree `.worktrees/phase1-research`, from `main`
  `d778f93`. **Not merged.** This is the phase-1 ★ checkpoint.
- **Phase:** **phase 1 (Research and ADRs) done; waiting for the user at ★.** Nothing is
  implemented; `src/` and the tests are unchanged.
  - Research is in `docs/research/` (index: `docs/research/README.md`): parity matrices for the
    9 R packages, Polars, the Julia frame packages and other engines; storage, dependency,
    Parquet/CSV, engine, grammar and source/sink notes; the lane owner's checks LC-01 to LC-09.
  - ADRs 0001–0020 are in `docs/adr/`, all **Proposed** (index: `docs/adr/README.md`).
  - The spec is `docs/superpowers/specs/2026-10-20-phase1-research-design.md`.
- **Upstream:** ChuiCore and ChuiTypes are not released, so there is still no upstream
  dependency. ADR-0014 and ADR-0015 define the adapters. ChuiCore's phase-1 ADRs (accepted
  2026-10-20) are reflected in ADR-0003 and ADR-0014.
- **Factory:** 0.2.5, profile `package` (`.factory-version`).
- **Remote:** none yet.

## Open lanes

| Lane | Agent | File scope | Status | Report |
|---|---|---|---|---|
| phase1-research | the phase-1 lane (lead's teammate) | `docs/adr/**`, `docs/research/**`, `docs/superpowers/**`, `HANDOFF.md`, `changelog.d/phase1-research.md` | committed, waiting at ★ | sent to the lead |

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

## Blockers and decisions waiting (★)

The user decides, each with a recommendation (details in the spec):
1. **Arrow IPC reads.** Own reader (recommended), or Arrow.jl's reader with known silent
   failures (LC-04, ST-04, #610).
2. **Parquet.** Extension on Parquet2 (recommended), or built in at about +1.2 s load
   (ADR-0020).
3. **Arrow writer.** Core (recommended), or an extension (ADR-0010).
4. **Morsel parallelism** in phase 3 instead of phase 5 (recommended; ADR-0003 rule 18).
5. **`rename` direction** `new = :old`, as dplyr (recommended; ADR-0002 rule 15).
6. **`Not` via InvertedIndices** (recommended; ADR-0008), or `except(…)`.

For the lead, not the user:
- the CF-001 reading for DataAPI interop methods (ADR-0002 rule 5);
- ordered-factor sort order vs CF-008 (ADR-0001 rule 5);
- the `chui-frames.md` updates after acceptance (Source/Sink, `code_lowered`, `arrange` order);
- drafted requests to ChuiCore and ChuiTypes (in the phase report, not written to the
  coordinator).

## Next action

After the ★: mark the accepted ADRs, then merge `feat/phase1-research` through a reviewed PR.
Phase 2 starts with the own-IPC-reader spike (ADR-0001 rule 10) and the plan outlined in the
spec.
