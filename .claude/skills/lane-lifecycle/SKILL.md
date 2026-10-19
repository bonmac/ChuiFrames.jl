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
- Worktree lanes: `scripts/lane new <name> [--base main]` creates `.worktrees/<name>`.
- The cap is `[lanes] max_open` (default 4). `dispatch_limit.sh` refuses the next spawn.

**Monitor**
- Wait for completion notifications; do not poll output files.
- Reviewers may send a preview first. Wait for the final report.

**Idle**
- An agent idle without a report is unproven: nudge it once (SendMessage) asking for the report.
- Still nothing: it is a FAILED lane. Re-dispatch with a narrower brief, or review its diff
  yourself, and say which you did. Never count its work as reviewed.

**Close**
- Close the agent (TaskStop) in the same step as reading its report. A listing is not proof of
  closure.
- Remove a merged worktree lane with `scripts/lane remove <name>`; show `git worktree list`.

**Report**
- `subagent_mode: actual | simulated | mixed`. Simulated means the pass was not spawned.
- The roster: which agents ran, which lanes were skipped and why, which failed or went idle.
- Verify a lane's claims (re-run its test command) before building on them.
