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

## Evidence (clean tree at `a5afed9`)

- Test counts: `.lanes/evidence/tests-a5afed9.txt` (1.13.2: 4420 pass, 3 broken) and
  `tests-all-a5afed9.txt` (`-- all`: 5439 pass, 3 broken). LTS 1.10.12 from a `git archive`
  export of `a5afed9`: 4420 pass, 3 broken (log in the lane's scratch; not an evidence file).
- LTS needs its own manifest: an empty, gitignored `Manifest-v1.10.toml` makes `julia +lts`
  resolve separately (the 1.13 manifest pins PrecompileTools 1.3.4, which needs Julia 1.11).
- quality, jet, format, guards, docs: OK. `dod.jl --base 1a2f1eb`: DONE (82 files, T2).
  `--base main` resolves to the stale `origin/main` `d778f93` and is not meaningful.
- Merge result with `main` `7e39416` (scratch clone, merge `387ea94`): `-- all` 5439 pass /
  3 broken, quality, guards, docs OK.
- Load time (ADR-0005 rule 5, warm runs, M3 Pro): 0.361 s on 1.13.2 (median of 3; budget
  0.5 s), 0.551 s on 1.10.12 (2 warm runs after one precompiling run; budget 0.8 s).
- Differentials: tidyr pivots 50/50, tidyr nest/complete 41/41, ranking tail 14/14 plus dplyr
  43/43; the IPC corpus regenerates byte for byte (88 files).

## Checks NOT run, and why

- `ci.jl contracts`: no upstream release exists (NOT RUN, waiting).
- `-t 4` runs: phase 2 is single-threaded (morsel parallelism is phase 3, ADR-0003 rule 18).
- Benchmarks and the performance ADR: not started (item 4, next branch).
- Verb differential tests against Polars and DuckDB (item 5, next branch). Only dplyr, tidyr,
  readr, pyarrow, Polars/R arrow (IPC corpus) were run.
- A Parquet file with nested timestamp columns: Parquet2 cannot open one.

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

## Review (2026-10-20)

- The read-only reviewer's first pass, on `adf0811`, requested changes. There were no blockers.
  - M1: CSV `T` turned sub-ms digits into `missing`.
  - M2: work in progress was uncommitted.
  - M3: ADR-0021 is Proposed.
  - Also 6 minors and 2 nits.
- All were fixed in `bcdf10d`, `b85b0eb` and `a5afed9`, except M3, which is the user's ★.
- Second pass, on `adf0811..b85b0eb`: **APPROVE**, with conditions:
  - green gates (met at `a5afed9`, above);
  - review of this HANDOFF diff;
  - a gate run on the merge result (met, above);
  - ADR-0021 accepted by the user before anything that depends on it lands.

## Minors left open (from earlier reviews, unchanged)

- `case_when`'s element type depends on whether its default fires.
- The Parquet µs/ns check now reads every top-level timestamp column exactly. Parquet2 cannot
  open files with nested timestamp columns at all (critic probe).
- No property test for the zero-null-slot invariant across verbs.
- Parquet writes one row group per partition (ADR-0020 rule 1; phase 3).
- The ExplicitImports ignore list matches by name, not by module, which its API does not
  support. It now also lists Parquet2 internals (`Column`, `SchemaNode`, `ParqInt64`,
  `encodevalue`) and Arrow.jl's `Timestamp`/`Meta`/`TimeUnit` (ADR-0021 rules 10-11).
- `read_csv` `T`/`DateTime` needs full `yyyy-mm-ddTHH:MM:SS` text (readr also takes a date
  alone or no seconds); documented in the divergence list.
- `complete(; fill)` on an all-`missing` column takes the fill's type (tidyr: logical);
  documented.
- Merge: this branch's commits each build on their own (checked for the engine commit), so a
  squash merge is optional here; the earlier branch's advice to squash still stands for it.
- The NITs: `glimpse` prints no trailing newline; `isempty(c.x)` is silently `false`; `take` on
  LargeUtf8 gives back Int32 offsets; LZ4/Zstd output size is not capped; `Not(...)` prints as
  `InvertedIndex{Symbol}(:b)` in verb `show`.

## Upstream notes for phase 3 (ChuiCore main b4f1ca3, NOT released)

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

The user's ★ answers (ADR-0021 acceptance, Parquet2 internals, TimeZones.jl, lossy
`DateTime(t)`), then the lead's reviewed merge. ADR-0021 must be Accepted before this branch
lands on `main`.
