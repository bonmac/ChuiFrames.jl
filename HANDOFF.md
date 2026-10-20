# Handoff

The one handoff file for this repo. Update it before stopping, before a compaction, and at
every checkpoint. Keep it short; history lives in git and in ADRs.

## State

- **Branch:** `feat/phase2-eager`, in worktree `.worktrees/phase2-eager`, from `main` `c5db1cb`.
  **Not merged**; the lead merges after review.
- **Phase:** phase 2 (eager frame), first milestone done (plan:
  `docs/superpowers/plans/2026-10-20-phase2-eager.md`):
  - storage: own Arrow-layout columns and `Frame` (ADR-0001);
  - Arrow IPC: own reader (the spike gate **passed**: 23/23 readable corpus cases, 20/20
    must-raise cases), Arrow.jl writer adapter;
  - engine: upstream adapter stand-ins, the `c.x` grammar, the single-threaded interpreter, the
    core dplyr verbs (73 exported names in all);
  - I/O: Source/Sink interface and registry (public, not exported), CSV, the Parquet2 extension;
  - tibble-style printing, `glimpse`, the conflict-banner stand-in.
- **Upstream:** ChuiCore and ChuiTypes are not released; ChuiFrames depends on neither. The
  adapter stand-ins live in `src/engine/upstream.jl` (ADR-0014). `⨟` is not exported.
- **Factory:** 0.2.5, profile `package` (`.factory-version`). **Remote:** `origin` exists, but
  `origin/main` is stale at `d778f93` (local `main` was fast-forwarded to `c5db1cb` without a
  push). `dod.jl` and `lane audit` prefer `origin/<base>`, so run them with `--base c5db1cb`.

## Open lanes

| Lane | Agent | File scope | Status | Report |
|---|---|---|---|---|
| phase2-eager | the phase-2 lane (lead's teammate) | `src/**`, `ext/**`, `test/**`, `Project.toml`, `docs/**`, `benchmark/**`, `HANDOFF.md`, `changelog.d/phase2-eager.md` | milestone done; review in progress | to the lead |
| p2-ipc, p2-engine, p2-io, p2-show | sub-lanes (closed) | worktrees created, **unused**: the guard hooks blocked writes outside the active worktree, so each built in a scratch copy and its files were committed on `feat/phase2-eager` | integrated | to the phase-2 lane |

The four sub-lane worktrees (`.worktrees/p2-*`, branches `feat/p2-*` with no commits) can be
removed with `scripts/lane remove <name>`. `.worktrees/p2-ipc` holds a stray gitignored
`Manifest.toml` (needs `--allow-ignored`).

## Evidence

- Test counts: `.lanes/evidence/tests-3d518a7.txt` (1.13.2), `tests-lts-3d518a7.txt`
  (1.10.12), `tests-all-3d518a7.txt` (`-- all`), clean tree at `3d518a7`.
- LTS needs its own manifest: an empty, gitignored `Manifest-v1.10.toml` makes `julia +lts`
  resolve separately (the 1.13 manifest pins PrecompileTools 1.3.4, which needs Julia 1.11).
- Load time (ADR-0005 rule 5, median of three warm runs, M3 Pro): 0.472 s on 1.13.2 (budget
  0.5 s), 0.715 s on 1.10.12 (budget 0.8 s). Little headroom on 1.13.

## Checks NOT run, and why

- `ci.jl contracts`: no upstream release exists (NOT RUN, waiting).
- `-t 4` runs: phase 2 is single-threaded (morsel parallelism is phase 3, ADR-0003 rule 18).
- Benchmarks and the performance ADR: not started (remaining, below).
- Differential tests against Polars and DuckDB for the verbs (only dplyr, readr, pyarrow and R
  arrow were run).

## Remaining in phase 2

- tidyr reshaping: `pivot_longer`/`pivot_wider`, `nest`/`unnest*`, `separate_*`, `unite`,
  `fill`, `complete`/`expand`, `pack`/`unpack`.
- The ranking tail (`percent_rank`, `cume_dist`, `ntile`), `slice_sample(weight_by)`,
  `group_by(drop = false)`, `arrange(locale)`, `when_any`/`when_all`, a spelling for declaring a
  `c.x |> f` result type.
- `ArrowTimestamp` (Timestamp µs/ns/zone) needs its phase-2 ADR first (ADR-0001 rule 6). Until
  then the reader raises on those types, including Polars' default `Datetime`, which is µs
  (verified: Polars 2.0.0 gives `Datetime(time_unit='us', time_zone=None)`). This ADR is the
  most urgent remaining item for Polars interop.
- The performance ADR (ADR-0003 consequences): TTFX, per-verb eager overhead, ratios.
- Verb differential tests against Polars/DuckDB (`uv`).

## Review (2026-10-20)

The read-only reviewer requested changes: 3 blockers and 1 major, all fixed.
- **B1** (verb outputs typed from the data): fixed in `22ebcd6`.
- **B2** (docs job red): fixed in `101c6ff`.
- **B3** (`dod.jl` spec link on the real base): the commits now name the spec.
- **M1** (Parquet µs/ns timestamps truncated): fixed in `cc21bbb`.
- **Minors fixed:** lossless NaN, `vcat_columns` precision, the NaN-group oracle, the skip labels, and the ADR-0014 amendment note.

Final verdict: **approve** (on `38ad1c8`). After it, rank nullability was fixed to follow the
argument's declared type (a float argument may rank NaN as `missing`).

Minors left open, with reasons:
- `case_when`'s element type still depends on whether its default fires (its static type is
  unknown unless all branches are Bool); phase 3 must type it before lazy == eager.
- The Parquet µs/ns check reads units from the first row group's top-level columns only (not
  nested timestamps).
- No property test for the zero-null-slot invariant across verbs. The constructors enforce it.
- Parquet writes one row group per partition, not per morsel (ADR-0020 rule 1). Re-split in phase 3, when morsels exist.
- The ExplicitImports ignore list matches by name, not by module, which its API does not support.
- The intermediate engine commits do not build on their own. Prefer a squash merge.
- The review NITs (`glimpse` prints no trailing newline; `isempty(c.x)` is silently `false`; `take` on LargeUtf8 gives back Int32 offsets; LZ4/Zstd output size is not capped).

## Upstream notes for phase 3 (ChuiCore phase 3 merged on its main b4f1ca3, NOT released)

Keep the stand-ins until the release; then switch per ADR-0014 rule 3.
- **First n rows:** keep `head`/limits on `Take` or `foldxl`, never an accumulator-dependent
  `Reduced` from `op` under `foldparts` (ChuiCore S1). Phase 2 complies: `head` is a direct
  `take`, and `Reduced` appears only inside the `Take` stand-in.
- **Plan nodes:** use `Any`-typed child fields; parametric child fields recompile per tree shape.
- **Instances:** type the style argument (`ap(::IsApplicative, …)`, ChuiCore rule N5). ChuiFrames
  defines no instances yet.
- **Available on ChuiCore main:** R6 `cata`/`ana`/`para` over an own node type with a
  registered `fmap`, plus `Fix`; R7 transducers and `aggregate` (`isstateless` fail-closed); R9
  `binding_conflicts`/`conflict_banner` (`CHUI_QUIET_CONFLICTS`). The banner stand-in
  (`src/show/banner.jl`) differs in one point: it scans modules bound in `Main`, while R9 also
  scans `Base.loaded_modules`. It takes an extra optional `others` argument. The difference
  disappears at the switch.

## Next action

The reviewer's re-check of the fixes, then the lead's reviewed merge (squash recommended).
