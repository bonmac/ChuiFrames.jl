---
description: Show open worktree lanes and subagent lanes, and flag stale or failed ones.
allowed-tools: Bash(scripts/lane:*), Bash(julia scripts/lane.jl:*), Bash(git worktree list:*), Bash(tail:*), Read
---
<!-- Factory-managed (see .factory-version). -->
1. Run `scripts/lane list` and paste its output.
2. Run `git worktree list` and compare: a worktree outside `.worktrees/` is not managed by the
   lane tool; say so.
3. Read the last 20 lines of the lane ledger (`.lanes/ledger.jsonl`, if present). List agents
   with a `start` but no `stop`, and any `idle-unreported` or `dispatch-denied` events.
4. For each lane, report: name, branch, ahead/behind its base, dirty or clean, and one action:
   keep, review, close (`scripts/lane remove <name>` once merged), or re-dispatch.
5. Lanes open vs the cap in `.agents/agent-registry.toml` `[lanes] max_open`.
