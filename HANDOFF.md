# Handoff

The one handoff file for this repo. Update it before stopping, before a compaction, and at
every checkpoint. Keep it short; history lives in git and in ADRs.

## State

- **Branch:** `feat/phase2b-tidyr`, in worktree `.worktrees/phase2b-tidyr`, from `main` `1a2f1eb`.
  **Not merged**; the lead merges after review.
- **Phase:** phase 2 (eager frame), second milestone, items 1–3 of the plan
  (`docs/superpowers/plans/2026-10-20-phase2b-tidyr.md`):
  - **ADR-0021, `ArrowTimestamp{U,TZ}`** (Proposed; critic: no blockers). Timestamps in
    s/ms/µs/ns, naive or zoned, read and round-trip exactly through Arrow IPC.
    - Polars', R arrow's and DuckDB's µs defaults now read.
    - Parquet reads every unit exactly; CSV reads sub-ms digits exactly.
    - It also fixes Parquet ms timestamps on `main`, which are 1 ms off for about 1 value in
      170 on read and 1 in 110 on write (TS-12).
  - **tidyr reshaping:** pivots, `separate_*`, `unite`, `nest`/`unnest*`, `pack`/`unpack`,
    `fill`, `expand`/`nesting`/`complete`.
  - **The ranking tail:** `percent_rank`, `cume_dist`, `ntile`, `when_any`/`when_all`,
    `slice_sample(weight_by)`, `group_by(drop = false)`, `arrange(locale = "C")`, and
    `typed(T, f)`.
- **Upstream:** unchanged. ChuiCore and ChuiTypes are not released; the stand-ins stay in
  `src/engine/upstream.jl` (ADR-0014).
- **Remote:** `origin/main` is stale. Run `dod.jl` and `lane audit` with `--base 1a2f1eb` as well
  as `--base main`.

## Open lanes

| Lane | Agent | File scope | Status | Report |
|---|---|---|---|---|
| phase2b-tidyr | the phase-2b lane (lead's teammate) | `src/**`, `ext/**`, `test/**`, `Project.toml`, `docs/**`, `benchmark/**`, `HANDOFF.md`, `changelog.d/phase2b-tidyr.md`, `JuliaTestItems.toml`, `.gitignore` | items 1–3 done; see the lead report | to the lead |

The sub-lanes `tidyr-pivot`, `tidyr-nest`, `rank-tail` and `ts-corpus` are closed. Each built in
a scratch copy of this worktree (the guard hooks block sibling worktrees). This lane audited
each copy's diff against its scope and applied the files here; the reviewer should diff them.

## Remaining in phase 2 (next branch)

- The performance ADR and benchmarks (ADR-0003 consequences): TTFX, per-verb overhead, ratios
  against Polars/DuckDB/dplyr. Set budgets from measurements; report losses too.
- Verb differential tests against Polars and DuckDB (`uv`).
- `group_by(drop = false)`: store the flag on `Frame`, so that `filter`/`arrange`/slices keep
  empty groups as dplyr does (a `@test_broken` marks it). This changes the frame struct (T2).
- `Frame` has no structural `==`/`isequal` (identity only). `frame_equal` on frames that hold
  nested `Frame`s (from `nest`) is therefore always false. Decide whether frames compare by
  content.
- Parquet timestamp statistics: decode the raw bounds exactly, to bring back row-group pruning
  on timestamps (they report none now).
- The ★ questions in the lead report: Parquet2 internals, TimeZones.jl, and lossy `DateTime(t)`.

## Minors left open (from earlier reviews, unchanged)

- `case_when`'s element type depends on whether its default fires.
- The Parquet µs/ns check now reads every top-level timestamp column exactly. Parquet2 cannot
  open files with nested timestamp columns at all (critic probe).
- No property test for the zero-null-slot invariant across verbs.
- Parquet writes one row group per partition (ADR-0020 rule 1; phase 3).
- The ExplicitImports ignore list matches by name, not by module.
- The NITs: `glimpse` prints no trailing newline; `isempty(c.x)` is silently `false`; `take` on
  LargeUtf8 gives back Int32 offsets; LZ4/Zstd output size is not capped; `Not(...)` prints as
  `InvertedIndex{Symbol}(:b)` in verb `show`.

## Upstream notes for phase 3 (ChuiCore main b4f1ca3, NOT released)

Unchanged from the first milestone: keep `head`/limits on `Take`/`foldxl`; give plan nodes
`Any`-typed child fields; type the style argument of any instance (ChuiFrames still defines none).
The banner stand-in differs from R9 only in scanning `Main`.

## Next action

The reviewer's FINAL verdict on this branch, then the lead's reviewed merge, then the user's ★
answers (ADR-0021 acceptance, the Parquet2 internals question).
