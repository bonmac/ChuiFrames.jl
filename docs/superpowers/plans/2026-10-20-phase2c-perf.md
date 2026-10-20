# Phase 2c: performance budgets, Polars/DuckDB differentials, phase-2 leftovers

- **Branch:** `feat/phase2c-perf` from `main` `038f286`. Tier T2 (the `Frame` struct, public
  `==`/`isequal`, `ext/`).
- **Goal:** finish phase 2 (eager frame). The performance ADR owed by ADR-0003's consequences,
  a `benchmark/` suite AirspeedVelocity can run (ecosystem ADR-0011), verb differentials against
  Polars and DuckDB, and the HANDOFF leftovers.
- **Binding:** accepted ADRs 0001–0021 (0021: exact Parquet timestamps through Parquet2
  internals, fail closed; `DateTime(t)` floors); contract ADR-0014 and `contracts/chui-frames.md`;
  ChuiCore notes (first n rows through `Take`/`foldxl`; style-typed instances); ChuiCore ADR-0009
  as the budget model.

## Sub-lanes (factory 0.2.6 worktrees, branched from `feat/phase2c-perf`, disjoint scopes)

| Lane | Owns | Deliverable |
|---|---|---|
| `p2c-bench` | `benchmark/**`, `docs/adr/0022-*.md`, `docs/adr/README.md`, `docs/src/performance.md`, `docs/make.jl`, `docs/research/performance.md` | `SUITE`, `run.jl --check`, `ttfx.jl --check`, `budgets.toml` (1.13 and 1.10 tables), ADR-0022 (Proposed), DataFrames.jl and Polars comparison (scratch envs) |
| `p2c-diff` | `test/engine/differential_polars_duckdb_tests.jl`, `docs/research/differentials-polars-duckdb.md` | `:differential` test item running Polars and DuckDB through `uv` in a scratch dir; every divergence encoded and documented |
| `p2c-frame` | `src/frame.jl`, `src/engine/**`, `test/engine/**` except the differential file above, `test/storage_tests.jl` | `drop` flag stored on `Frame` (remove the `@test_broken`), content `isequal`/`==`/`hash` for `Frame`, `case_when` element type independent of whether the default fires |
| `p2c-parquet` | `ext/ChuiFramesParquet2Ext.jl`, `test/io/parquet_tests.jl`, `test/io/data/**` | exact timestamp bounds from the raw Parquet statistics (fail closed), row-group pruning on timestamps back |

`src/ChuiFrames.jl`, `Project.toml`, `HANDOFF.md`, `changelog.d/phase2c-perf.md` stay with this
lane. A sub-lane that needs an export or a dependency asks; it does not edit them.

## Steps

1. Baseline: tests on `038f286` (1.13.2), load time.
2. Dispatch the four lanes in parallel. Each works TDD (failing test first) and commits in its own
   worktree with the trailer; every commit builds.
3. Review each lane's diff here (`scripts/lane audit <lane>`), merge into `feat/phase2c-perf`
   in order frame → parquet → diff → bench (bench last, so its budgets are measured on the final
   tree; re-run `run.jl --check` and `ttfx.jl --check` after the merge).
4. Gates on the merged tree: `test` on 1.13.2 and `+lts`, `test -- all`, quality, jet, format,
   guards, docs, `dod.jl --base main`, `lane audit`.
5. Read-only reviewer; iterate to its FINAL verdict.
6. Changelog fragment, HANDOFF, report to the lead with the ★ questions (multipliers, one-way
   rule, CI or not, `==` semantics) and draft requests.

## Out of scope (deferred, with reasons in HANDOFF)

- A benchmark CI workflow: `.github/workflows/*` is T3 (ADR-0011: warning-only first; the user
  approves it).
- Morsel parallelism, lazy entry point, codegen (phases 3–4): the budgets cover the
  single-threaded eager path only.
