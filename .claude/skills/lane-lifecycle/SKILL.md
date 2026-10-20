---
name: lane-lifecycle
description: Rules for dispatching, monitoring, closing and reporting agent lanes (subagents, teammates, worktree lanes). Use whenever you dispatch an agent or a lane goes quiet.
---
<!-- Factory-managed (see .factory-version). -->
# Lane lifecycle

**Dispatch**
- One lane = one repo, one file scope, one deliverable, one definition of done. No two open
  lanes share a file.
- Give the agent its brief, its scope, and the output format from its registry entry.
- Worktree lanes: `scripts/lane new <name> --owns '<globs>' [--base main]` creates
  `.worktrees/<name>` and records the globs the lane may touch (`changelog.d/<name>.md` is
  added). The brief's file scope and `--owns` are the same list. It copies the machine-local,
  gitignored `.agents/factory.local.toml` into the lane and runs `scripts/gen.jl` there (the
  user's own file; without it a repo that requires read-only roots blocks every Bash call in the lane).
- Sub-lanes: `scripts/lane new` run inside a lane creates a SIBLING, `<repo>/.worktrees/<sub>`.
  A session rooted in a lane worktree may write the repo's other lane worktrees (`.worktrees/*`,
  `.claude/worktrees/*`) and `<repo>/.lanes/reports/`, not the main checkout; T3 paths stay
  blocked there. Do not work in scratch copies. The parent lane still owns the merge.
- The brief says: change files with Edit/Write only, never `sed -i`, redirects or heredocs.
- Each lane records its change in `changelog.d/<name>.md`, never in `CHANGELOG.md`.
- The cap is `[lanes] max_open` (default 4). `dispatch_limit.sh` refuses the next spawn.

**Monitor**
- Wait for completion notifications; do not poll output files.
- Reviewers may send a preview first. Wait for the final report.

**Idle**
- An agent idle without a report is unproven: nudge it once (SendMessage) asking for the report.
- Still nothing: it is a FAILED lane. Re-dispatch with a narrower brief, or review its diff
  yourself, and say which you did. Never count its work as reviewed.

**Close**
- Before a lane lands, `scripts/lane audit <name> --reported <file>` (the changed files the lane
  reported) must pass; a path outside `--owns` is a finding, not a formality. It diffs against
  the local base when that contains `origin/<base>` (local merges not yet pushed are not the
  lane's); `--base B` audits against another base.
- A lane's report: SendMessage, or `.lanes/reports/<name>.md` in its worktree or the repo root
  (`teammate_idle` reads both).
- Close the agent (TaskStop) in the same step as reading its report. A listing is not proof of
  closure. Before recording a lane as `no_report`, check once more for a late message: a report
  can arrive after the stop.
- Remove a merged worktree lane with `scripts/lane remove <name>`; show `git worktree list`.

**Report**
- `subagent_mode: actual | simulated | mixed`. Simulated means the pass was not spawned.
- The roster: which agents ran, which lanes were skipped and why, which failed or went idle.
- Verify a lane's claims (re-run its test command) before building on them. Test counts come
  from an evidence file (`julia scripts/evidence.jl tests -- <cmd>`); cite it.
