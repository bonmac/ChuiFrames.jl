# Handoff

The one handoff file for this repo. Update it before stopping, before a compaction, and at
every checkpoint. Keep it short; history lives in git and in ADRs.

## State

- **Branch:** `feat/phase2c-perf`, in worktree `.worktrees/phase2c-perf`, from `main` `038f286`.
  **Not merged**; the lead merges after review. `main` has since gained 3 commits (vendored
  contracts, a Parquet2 research note). `git merge-tree` shows they merge cleanly.
- **Phase:** phase 2 (eager frame), last milestone (plan
  `docs/superpowers/plans/2026-10-20-phase2c-perf.md`, spec
  `docs/superpowers/specs/2026-10-20-phase2c-perf-design.md`):
  - **Performance:** ADR-0022 (**Proposed**). `benchmark/` holds the `SUITE` (47 entries),
    `run.jl --check`, `ttfx.jl --check` and `budgets.toml` (1.13 and 1.10 tables).
    `docs/src/performance.md` has ratios against DataFrames.jl, Polars and DuckDB, losses
    included.
  - **Differentials:** Polars 2.0.0 and DuckDB 1.5.6 (`test -- polars_duckdb`), 56/56 cases each.
    Every divergence is documented in `docs/research/differentials-polars-duckdb.md`.
  - **Leftovers:**
    - the `drop` flag is stored on `Frame`, and the `@test_broken` is gone;
    - content `isequal`/`==`/`hash` for `Frame`;
    - `case_when`'s element type comes from types, not data;
    - exact Parquet timestamp statistics.
- **Upstream:** unchanged. ChuiCore and ChuiTypes are not released; the stand-ins stay
  (ADR-0014).

## Open lanes

| Lane | Agent | File scope | Status | Report |
|---|---|---|---|---|
| phase2c-perf | the phase-2c lane (lead's teammate) | `src/**`, `ext/**`, `test/**`, `Project.toml`, `docs/**`, `benchmark/**`, `HANDOFF.md`, `changelog.d/phase2c-perf.md`, `JuliaTestItems.toml`, `.gitignore` | done; in review | to the lead |

Sub-lanes, all closed:
- `p2c-frame`, `p2c-parquet`, `p2c-diff` and `p2c-bench` each ran in a real worktree (factory
  0.2.6).
- `lane audit` passed on each before its `--no-ff` merge here.
- Their worktrees are removed; the branches are kept.

## Evidence (`.lanes/evidence/`, clean tree `fd30b98` unless noted)

- Tests:
  - `tests-fd30b98.txt` (1.13.2): 4785 pass, 2 broken.
  - `tests-lts-fd30b98.txt` (1.10.12): 4785 pass, 2 broken.
  - `tests-all-fd30b98.txt` (`-- all`): 6439 pass, 2 broken.
- quality, jet, format, guards, docs: OK (`<job>-fd30b98.txt`).
- Budgets on the merged tree `30c36b8` (only docs uncommitted):
  - `bench-check-113-30c36b8.txt` and `bench-check-110-30c36b8.txt`: 47/47 within budget.
  - `ttfx-check-113-30c36b8.txt`: load 486.6 ms against a 500 ms budget, at load average
    10.6–12.2.
  - `ttfx-check-110-30c36b8.txt`: load 688.7 ms against an 800 ms budget, at load average
    15.7–20.0.
  - All four ran on a loaded, shared machine. No budget was tightened from them.
- Base-commit measurements: `bench-11{3,0}-6250cad.txt`, `ttfx-*-6250cad.txt`.
  - The bench lane's earlier `ttfx-check-113-7f0d685.txt` failed on load: 508.9 ms against
    500 ms, under load.
- Differentials: `diff-polars-duckdb-723cf0e.txt`.

## Checks NOT run, and why

- `ci.jl contracts`: no upstream release exists (waiting).
- `-t 4`: phase 2 is single-threaded.
- A quiet-machine baseline: the load average was 8–89 throughout.
- The DataFrames.jl and Polars comparison on the LTS.
- A profile of the per-row allocations. The interpreter appears to box each element (PF-11);
  this is UNVERIFIED.
- AirspeedVelocity: 0.6.6 cannot resolve the benchmark environment. Its JSON3 caps Parsers at
  2.8.8, and CSV 1.x needs Parsers 3 (PF-12). `scripts/bench.jl` is the regression gate meanwhile.
  It shows ±20 % noise on this machine (PF-13).
- JET does not load Parquet2, so the extension is not analysed.

## Open decisions (★, in the lead report)

ADR-0022's policy items:
- the time multiplier;
- the allocation multiplier;
- the one-way rule;
- where the checks run;
- the benchmark CI job (a T3 workflow draft is in the report);
- the load budget values.

Other decisions:
- `group_by` inheriting the drop flag (dplyr does);
- the flag in `isequal` vs `frame_equal`;
- `==` semantics;
- `case_when` type errors (an ADR-0002 rule 10 line);
- `var`/`std` of one value (NaN here, NA in dplyr);
- the deprecated Parquet `min`/`max` fields.

## Remaining (phase 3 and later)

- Pruning: nothing in `src/` reads `partition_stats` yet (lazy pruning is phase 3). The exact
  timestamp statistics are ready for it.
- The losses of ADR-0022's rule 7 table (large-frame verbs 3.5–43× slower than DataFrames.jl) are
  phase-4 engine work (codegen, typed kernels).
- The PrecompileTools workload buys almost nothing for the first call (PF-05); why is UNVERIFIED.

## Minors left open (unchanged unless noted)

- The Parquet µs/ns check reads every top-level timestamp column exactly. Parquet2 cannot open
  files with nested timestamp columns.
- No property test for the zero-null-slot invariant across verbs.
- Parquet writes one row group per partition (ADR-0020 rule 1; phase 3).
- The ExplicitImports ignore list matches by name, not module (unchanged; phase 2c added no
  qualified internals).
- `read_csv` `T`/`DateTime` needs full `yyyy-mm-ddTHH:MM:SS` text.
- `complete(; fill)` on an all-`missing` column takes the fill's type.
- The NITs: `glimpse` prints no trailing newline; `isempty(c.x)` is silently `false`; `take` on
  LargeUtf8 gives back Int32 offsets; LZ4/Zstd output size is not capped; `Not(...)` prints as
  `InvertedIndex{Symbol}(:b)` in verb `show`.
- Done in 2c: `case_when`'s element type, timestamp statistics, the drop flag, frame equality.

## Upstream notes for phase 3 (ChuiCore main b4f1ca3, NOT released)

Keep the stand-ins until the release; then switch per ADR-0014 rule 3.
- **First n rows:** keep `head`/limits on `Take` or `foldxl`, never an accumulator-dependent
  `Reduced` from `op` under `foldparts` (ChuiCore S1). Phase 2 complies.
- **Plan nodes:** use `Any`-typed child fields; parametric child fields recompile per tree shape.
- **Instances:** type the style argument (`ap(::IsApplicative, …)`, ChuiCore rule N5). ChuiFrames
  defines no instances yet.
- **Available on ChuiCore main:**
  - R6: `cata`/`ana`/`para` and `Fix`;
  - R7: transducers and `aggregate`;
  - R9: `binding_conflicts`/`conflict_banner`. The banner stand-in scans `Main` only.

## Next action

The read-only reviewer's FINAL verdict, then the user's ★ answers (ADR-0022 acceptance first),
then the lead's reviewed merge.
