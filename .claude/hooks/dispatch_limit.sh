#!/bin/sh
# dispatch_limit.sh: PreToolUse(Agent|Task). Refuses a new subagent or teammate when this
# session already has MAX_OPEN_LANES open lanes. "Open" = a SubagentStart in the ledger with
# no later SubagentStop for the same agent_id, in this session_id (written by lane_ledger.sh).
# The cap comes from [lanes] max_open in .agents/agent-registry.toml (generated limits.env);
# FACTORY_MAX_OPEN_LANES in the session env overrides it. Fails closed without jq.
. "$(dirname -- "$0")/_lib.sh"
need_jq
max=${FACTORY_MAX_OPEN_LANES:-${MAX_OPEN_LANES:-4}}
open=0
if [ -f "$LEDGER_FILE" ]; then
    open=$(jq -s --arg s "$(session)" "$OPEN_LANES_JQ | .count" "$LEDGER_FILE" 2>/dev/null) || open=0
fi
case $open in '' | *[!0-9]*) open=0 ;; esac
if [ "$open" -ge "$max" ]; then
    ledger dispatch-denied open "$open" max "$max" subagent_type "$(field '.tool_input.subagent_type')"
    deny "$open lanes are open (cap $max). Read a finished lane's report and close it (TaskStop) before dispatching another. The cap is [lanes] max_open in .agents/agent-registry.toml."
fi
exit 0
