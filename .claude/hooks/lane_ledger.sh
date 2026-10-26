#!/bin/sh
# lane_ledger.sh: appends one slim JSON line per lane event to the lane ledger (.lanes/ledger.jsonl).
# - SubagentStart / SubagentStop: {ev: start|stop, agent_id, agent_type}. A stop closes a background
#   subagent's lane (its agent_id was recorded as `spawned`); starts and stops alone count nothing.
# - PostToolUse / PostToolUseFailure (Agent|Task|TaskStop), 0.2.8:
#   Agent|Task: status teammate_spawned, async_launched or remote_launched -> {ev: spawned, key,
#   agent_id} (stays open); status completed (a foreground agent returned) or PostToolUseFailure -> {ev: close, key};
#   any other result -> {ev: unknown-result, key, status}, and the lane stays OPEN (fail toward
#   counting; critic M3). TaskStop -> {ev: close, ref: task_id, desc: the stopped task's command}.
#   A TaskStop for a GONE agent fails validation and fires no hook (docs), so its lane is released
#   with `scripts/lane release <key>` instead (critic B1).
# - PermissionDenied (Agent|Task; auto mode only): {ev: close, key}. A denied permission DIALOG fires
#   no hook, so that lane stays until its TTL (it never ran) or `scripts/lane release`.
# dispatch_limit.sh (which writes `dispatch`) and precompact.sh read it. Advisory: fails open.
. "$(dirname -- "$0")/_lib.sh"
have_jq || exit 0
[ -f "$HOOKS_DIR/_lanes.sh" ] || exit 0 # `.` of a missing file would exit 1 in sh
. "$HOOKS_DIR/_lanes.sh"
ev=$(field '.hook_event_name')
# the spawned agent's id: agentId (async_launched, docs), agent_id (teammate_spawned, transcripts), taskId (remote_launched, docs)
AGENT_ID_JQ='.tool_response.agentId? // .tool_response.agent_id? // .tool_response.taskId?'
case $ev in
    SubagentStart) ledger start agent_id "$(field '.agent_id')" agent_type "$(field '.agent_type')" ;;
    SubagentStop) ledger stop agent_id "$(field '.agent_id')" agent_type "$(field '.agent_type')" ;;
    PostToolUse | PostToolUseFailure)
        case $(field '.tool_name') in
            TaskStop)
                why=stopped
                [ "$ev" = PostToolUse ] || why=stop-failed
                ledger close ref "$(field '.tool_input.task_id')" desc "$(field '.tool_response.command?')" why "$why"
                ;;
            Agent | Task)
                st=$(field '.tool_response.status?')
                if [ "$ev" = PostToolUseFailure ]; then
                    ledger close key "$(lane_key)" why failed
                elif [ "$st" = completed ]; then # documented foreground result
                    ledger close key "$(lane_key)" why returned
                elif [ "$st" = teammate_spawned ] || [ "$st" = async_launched ] || [ "$st" = remote_launched ]; then
                    ledger spawned key "$(lane_key)" agent_id "$(field "$AGENT_ID_JQ")"
                else # critic M3: an unknown status must not silently uncount a lane; it stays open
                    ledger unknown-result key "$(lane_key)" status "${st:-none}" agent_id "$(field "$AGENT_ID_JQ")"
                fi
                ;;
        esac
        ;;
    PermissionDenied) # auto mode denied the call after dispatch_limit recorded it (docs: no PostToolUseFailure)
        case $(field '.tool_name') in Agent | Task) ledger close key "$(lane_key)" why denied ;; esac ;;
esac
exit 0
