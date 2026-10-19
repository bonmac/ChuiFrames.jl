#!/bin/sh
# dispatch_limit.sh: PreToolUse(Agent|Task). Refuses a new subagent or teammate when this
# session already has MAX_OPEN_LANES open lanes. "Open" = a SubagentStart in the ledger with
# no later SubagentStop for the same agent_id, in this session_id (written by lane_ledger.sh).
# The cap comes from [lanes] max_open in .agents/agent-registry.toml (generated limits.env);
# FACTORY_MAX_OPEN_LANES in the session env overrides it. Fails closed without jq.
d=$(dirname -- "$0") # a missing library must block (exit 2), not fail open
[ -f "$d/_lib.sh" ] || { printf '[factory] %s is missing; dispatch_limit fails closed.\n' "$d/_lib.sh" >&2; exit 2; }
. "$d/_lib.sh"
need_jq
max=${FACTORY_MAX_OPEN_LANES:-${MAX_OPEN_LANES:-4}}
open=0
if [ -f "$LEDGER_FILE" ]; then # a malformed line (a crash mid-write) is skipped, not fatal (0.2.3)
    open=$(jq -Rn --arg s "$(session)" "[inputs | fromjson? // empty | objects] | $OPEN_LANES_JQ | .count" "$LEDGER_FILE" 2>/dev/null) ||
        deny "cannot read the lane ledger $LEDGER_FILE, so the open-lane cap cannot be checked (fails closed). Repair or move the file."
fi
case $open in '' | *[!0-9]*) deny "the lane ledger $LEDGER_FILE gave no open-lane count ($open); dispatch_limit fails closed." ;; esac
if [ "$open" -ge "$max" ]; then
    ledger dispatch-denied open "$open" max "$max" subagent_type "$(field '.tool_input.subagent_type')"
    deny "$open lanes are open (cap $max). Read a finished lane's report and close it (TaskStop) before dispatching another. The cap is [lanes] max_open in .agents/agent-registry.toml."
fi
exit 0
