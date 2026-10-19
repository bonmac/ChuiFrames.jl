# Handoff

The one handoff file for this repo. Update it before stopping, before a compaction, and at
every checkpoint. Keep it short; history lives in git and in ADRs.

## State

- Branch / last commit: `main`; the commit before the 0.2.4 alignment fixes is `e1676af`
  (`chore: sync factory 0.2.4 and refresh ecosystem copies`).
- Phase and current task: **scaffolded; phase 1 (Research and ADRs) not started.**
  - ChuiCore and ChuiTypes are not released yet, so there is **no upstream dependency**:
    nothing in `[deps]`, no committed `Pkg.develop` path. Their contracts (binding since
    2026-10-19) are vendored in `test/contracts/` (coordinator commit ff0100a);
    `test/contracts/USED.md` lists no IDs.
  - The empty `ChuiFrames` module loads; nothing is exported.
- Factory: 0.2.4, profile `package` (`.factory-version`). Ecosystem rules, brief and contracts
  copied from coordinator commit ff0100a.
- Remote: none yet. A public `bonmac/ChuiFrames.jl` is approved; the lead creates it.

## Open lanes

| Lane | Agent | File scope | Status | Report |
|---|---|---|---|---|
| — | — | — | none open | — |

Closure proof: no `.worktrees/` lanes are open.

## Evidence

Commands run on 2026-10-20 for the 0.2.4 alignment fixes (`julia` = stable, `julia +lts` = 1.10):

- `julia scripts/ci.jl guards`: `OK` (generated files, ratchets, doc references, factory tests).
- `julia scripts/ci.jl test`: `OK`. `julia +lts --project=. -e 'using Pkg; Pkg.test()'`: passed.
- `julia scripts/ci.jl jet`: `OK`.

## Checks NOT run, and why

- GitHub Actions workflows: need a remote (not created yet).
- `julia scripts/ci.jl contracts`: skips (no upstream URLs; nothing released).
- `julia scripts/ci.jl format` (Runic): not run; the formatter is ★ pending (ADR-0007).
- `julia scripts/ci.jl bench`: no benchmark/ yet (phase 1+).

## Blockers and decisions waiting

- ★ defaults taken from Proposed ADRs: version `0.0.1` (ADR-0004), `julia = "1.10"` (ADR-0006),
  TestItemRunner (ADR-0007), MIT license (ADR-0011).
- `.claude/hooks/read-only-roots.txt` is untracked now but remains in older commits; the lead
  handles it with the redaction gate before any push.

## Next action

- Phase 1 (Research and ADRs) per `docs/agent/BRIEF.md`, started by the lead at L1.
