#!/bin/sh
# lane_ledger.sh: SubagentStart / SubagentStop. Appends one slim JSON line per event to the
# lane ledger (.lanes/ledger.jsonl): {ts, ev: start|stop, session, agent_id, agent_type}.
# dispatch_limit.sh and precompact.sh read it. Advisory: fails open, never blocks.
. "$(dirname -- "$0")/_lib.sh"
have_jq || exit 0
case $(field '.hook_event_name') in
    SubagentStart) ev=start ;;
    SubagentStop) ev=stop ;;
    *) exit 0 ;;
esac
ledger "$ev" agent_id "$(field '.agent_id')" agent_type "$(field '.agent_type')"
exit 0
