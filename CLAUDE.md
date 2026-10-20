# ChuiFrames.jl: agent instructions

<!-- Seeded by the ecosystem factory (see .factory-version). This file is the SOURCE:
     AGENTS.md is generated from it by `julia scripts/gen.jl`. Keep it under 150 lines
     (ratchets.toml); put detail in the linked files, not here. -->

**What this repo is:** one package (data frames) of the Chui ecosystem. It stands alone: a fresh clone
plus `]instantiate; ]test` must pass using only *released* upstream packages.

**Read first:** `docs/agent/ECOSYSTEM.md` (shared rules), `docs/agent/BRIEF.md` (this
package's brief), `HANDOFF.md` (current state).

## Non-negotiables

1. Verify; don't guess. API claims come from running code, Context7, official docs or
   source. Otherwise write `UNVERIFIED`.
2. Evidence before assertions: never report a test, benchmark or review as done unless it
   ran; paste the command and its output. Say which checks you did not run.
3. Outward actions need the user: creating repos, pushing, tagging, registering, deleting,
   posting to GitHub.
4. Never edit another repo. Need something upstream? Write a request (see `/contract-check`).
5. main stays green. Every change lands through a reviewed PR with a changelog entry: a new
   `changelog.d/<lane>.md` fragment (folded into `CHANGELOG.md` at release by
   `julia scripts/changelog.jl fold`), or a `CHANGELOG.md` edit outside lanes.
6. Python only through `uv`; R through `Rscript`.
7. Change files with the Edit/Write tools, never `sed -i`, redirects or heredocs onto tracked
   files. Test counts and benchmark numbers in docs cite an evidence file
   (`julia scripts/evidence.jl <kind> -- <cmd>`, written to `.lanes/evidence/`).

## How work flows

Intake → Classify → Design → Plan → Execute → Verify → Review → Finish, using the
`superpowers:*` skills. The risk tier decides which stages run (`risk.toml`):

| Tier | Meaning | Stages |
|---|---|---|
| T0 | typo, comment, formatting | Execute → Verify |
| T1 | normal change in this package | short plan → TDD → review |
| T2 | public API, contracts, deps, compat | spec → plan → TDD → review |
| T3 | CI, hooks, process, release machinery | ADR + spec → plan → TDD → review, user approves |

- Specs: `docs/superpowers/specs/YYYY-MM-DD-<slug>-design.md`. Plans: `docs/superpowers/plans/`.
- Decisions: `docs/adr/`, from `docs/adr/0000-template.md`, indexed in `docs/adr/README.md`.
- Run scratch: `.superpowers/` and `.lanes/` (gitignored).
- Definition of done is checked by `julia scripts/dod.jl` (see `docs/CHECK_COVERAGE.md`).

## Lanes and agents

- One lane = one worktree, one file scope, one deliverable:
  `scripts/lane new <name> --owns '<globs>'` → `.worktrees/<name>` on branch `feat/<name>`;
  `scripts/lane audit <name>` checks the lane's diff stays inside those globs.
- At most 6 lanes open <!-- claim: max_open=6 --> (`[lanes] max_open` in `.agents/agent-registry.toml`;
  `scripts/check_claims.jl` fails when this number drifts from it).
- Close each agent as soon as its report is read. An agent that goes idle without a
  report is a FAILED lane: nudge once, then re-dispatch narrower or review directly.
- Mark simulated work as simulated. Report the roster: ran, skipped (why), failed.
- The reviewer is read-only; a merge or rebase done by a subagent is reviewed before it lands.
- Roles and their output formats: `.agents/agent-registry.toml` (prose in `.agents/bodies/`).

<!-- claude-only:begin -->
Claude Code specifics:

- Agents are generated into `.claude/agents/`; never edit them, edit the registry and run
  `julia scripts/gen.jl`.
- Commands: `/intake`, `/lanes`, `/change-review`, `/contract-check`, `/release-check`,
  `/test-changed`. Lifecycle rules: the `lane-lifecycle` skill.
- Hooks (`.claude/settings.json`): `bash_guard`, `write_guard`, `dispatch_limit`,
  `teammate_idle`, `lane_ledger`, `precompact`. If a hook blocks you, read its message;
  do not work around it. Each one's blind spots are in `docs/CHECK_COVERAGE.md`.
- After a compaction, read `.lanes/precompact.md` and `HANDOFF.md` before acting.
<!-- claude-only:end -->

## Commands (one entry point; CI calls the same jobs)

```sh
julia scripts/ci.jl --list          # every job and the commands it runs
julia scripts/ci.jl test            # unit tests (not :slow/:quality/:contract/:differential)
julia scripts/ci.jl quality         # Aqua, ExplicitImports
julia scripts/ci.jl jet             # JET, own env test/jet/ (stable Julia only)
julia scripts/ci.jl format          # Runic --check
julia scripts/ci.jl guards          # gen --check, ratchets, doc references, factory tests
julia scripts/dod.jl --base main    # definition of done for the current branch
```

## Testing

- `@testitem` (TestItemRunner) with tags `:unit :laws :property :contract :differential
  :snapshot :doctest :slow :quality`; `:snapshot`/`:doctest` run on stable only. Select tags with `julia scripts/ci.jl test -- laws`.
- `JuliaTestItems.toml` keeps `.worktrees/` and `.lanes/` out of test-item discovery (TestItemRunner
  >= 1.3.2): a stale `@testmodule` in a lane worktree would shadow the real one.
- Write the failing test first. Every typeclass instance gets law tests.
- Snapshot files live in `test/snapshots/`; update only with the documented env var.
- Supposition properties: `sr = @check record=false db=false prop(gen)`, then
  `@test Supposition.results(sr).ispass` (why: `test/runtests.jl`). Never commit a SuppositionDB directory.
- Testing on the LTS locally: give it its own gitignored manifest (`touch Manifest-v1.10.toml`, then
  `julia +lts --project -e 'using Pkg; Pkg.resolve()'`); a 1.13-resolved `Manifest.toml` may not load on 1.10.

## Style

- Runic formatting (no configuration). Conventional Commits on feature branches.
- `[compat]` bound on every dependency; each dependency has an ADR.
- Optional integrations are package extensions (`[weakdeps]` + `ext/`).

## Where things are

| Need | File |
|---|---|
| Shared ecosystem rules | `docs/agent/ECOSYSTEM.md` |
| Package brief | `docs/agent/BRIEF.md` |
| Current state, open lanes, blockers | `HANDOFF.md` |
| Risk tiers, protected paths | `risk.toml` |
| One-way limits | `ratchets.toml` |
| What each check misses | `docs/CHECK_COVERAGE.md` |
| Factory version | `.factory-version` |
