# Handoff

The one handoff file for this repo. Update it before stopping, before a compaction, and at
every checkpoint. Keep it short; history lives in git and in ADRs.

## State

- Branch / last commit: `main`, the initial commit `chore: scaffold ChuiFrames.jl from factory 0.2.1`.
- Phase and current task: **scaffolded; phase 1 (Research and ADRs) not started.**
  - ChuiCore and ChuiTypes are not released yet, so there is **no upstream dependency**:
    nothing in `[deps]`, no committed `Pkg.develop` path. Their contracts are vendored in
    `test/contracts/` (coordinator commit 275e879); `test/contracts/USED.md` lists no IDs.
  - The empty `ChuiFrames` module loads; nothing is exported.
- Factory: 0.2.1, profile `package` (`.factory-version`).

## Open lanes

| Lane | Agent | File scope | Status | Report |
|---|---|---|---|---|
| — | — | — | none open | — |

Closure proof: no `.worktrees/` lanes were created by the scaffold.

## Evidence

`subagent_mode: actual` (the scaffold was done by one lane, `scaffold-frames`; no subagents).
Commands run on 2026-10-19 (Julia 1.13.2 = `julia`, 1.10.12 = `julia +lts`):

- `sync_factory.jl --profile package` (dry run, then `--apply`): `add=58 seed=16`, `gen.jl: wrote 30 files`.
- `julia scripts/gen.jl --check`: `OK (30 files)`.
- `julia --project=. -e 'using Pkg; Pkg.test()'`: 1.13.2 `3/3 pass`; 1.10.12 `3/3 pass`.
- `julia scripts/ci.jl test`: `OK` (3 pass). `julia scripts/ci.jl quality`: `OK` (17 pass on
  1.13.2; 15 pass on 1.10.12 via `Pkg.test(test_args=["quality"])`, the `*_are_public` checks
  being gated to ≥ 1.11).
- `julia scripts/ci.jl jet`: `OK`. `julia scripts/ci.jl docs`: `OK` (builds `objects.inv`).
- `julia scripts/contract_usage.jl`: `OK (0 IDs listed, 0 tested, 0 upstream names used; 0 warnings)`.
- `julia scripts/test/runtests.jl`: `factory | 631 631` (sync tests run only in factory/template).
- `uvx --from actionlint-py actionlint .github/workflows/*.yml`: exit 0, no findings.
- Fresh clone + `Pkg.instantiate(); Pkg.test()`: pass (see the scaffold report to the lead).

## Checks NOT run, and why

- GitHub Actions workflows: need a remote (no remote until the user's ★ decision); only linted.
- `julia scripts/ci.jl contracts`: skips (no upstream URLs; nothing released).
- `julia scripts/ci.jl format` (Runic): not run; the formatter is ★ pending (ADR-0007).
- `julia scripts/ci.jl bench`: no `benchmark/` yet (phase 1+).

## Blockers and decisions waiting

- **`ci.jl guards` fails** on two factory 0.2.1 issues (reported to the lead; managed/T3 files not patched):
  1. `ratchet.jl`: managed `.claude/hooks/bash_guard.sh` has 210 lines > the seeded 150-line
     limit (the template itself fails the same check).
  2. `check_docs.jl`: 5 stale references in the copied `docs/agent/ECOSYSTEM.md` and the vendored
     `test/contracts/chui-*.md`. Proposed fix (T3, needs approval): in `.agents/factory.toml`
     `[check_docs] exclude = ["docs/agent/*", "test/contracts/chui-*.md"]` (verified with `--config`: OK).
- ★ defaults taken from Proposed ADRs: version `0.0.1` (ADR-0004), `julia = "1.10"` (ADR-0006),
  TestItemRunner (ADR-0007), MIT license (ADR-0011).

## Next action

- Lead: decide the factory fixes above; then phase 1 (Research and ADRs) per `docs/agent/BRIEF.md`.
