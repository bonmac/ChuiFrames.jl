- Synced the ecosystem factory template 0.2.7 -> 0.2.8 (`.factory-version`, coordinator commit
  c667a95): the lane cap (`dispatch_limit.sh`) now counts Agent dispatches instead of
  SubagentStart minus SubagentStop, which never balanced for in-process teammates, so `max_open`
  is enforced again. Adds the managed hook library `.claude/hooks/_lanes.sh`, closes lanes from
  Agent/TaskStop results and PermissionDenied (`lane_ledger.sh`, `settings.json`), serialises
  dispatches under `.lanes/.dispatch.lock`, adds `scripts/lane release <name>` for lanes whose
  agent is gone, and keeps the ledger intact after a truncated line (`_lib.sh`). The new blind
  spots are in `docs/CHECK_COVERAGE.md`. No seeded file changed in 0.2.8, so there are no hand edits.
