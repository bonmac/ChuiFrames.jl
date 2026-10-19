#!/bin/sh
# precompact.sh: PreCompact. Writes .lanes/precompact.md, a short snapshot of the state that
# must survive compaction (branch, dirty files, worktrees, open lanes, what to preserve).
# PreCompact output cannot be injected into the summary, so session_start.sh (SessionStart,
# matcher "compact") prints this file back into context afterwards. Fails open.
. "$(dirname -- "$0")/_lib.sh"
out="$ROOT/.lanes/precompact.md"
mkdir -p "$ROOT/.lanes" 2>/dev/null || exit 0
{
    echo "# Pre-compaction snapshot ($(date -u +%Y-%m-%dT%H:%M:%SZ), trigger: $(field '.trigger'))"
    echo
    echo "- branch: $(git -C "$ROOT" branch --show-current 2>/dev/null)"
    echo "- head: $(git -C "$ROOT" log -1 --format='%h %s' 2>/dev/null)"
    echo "- dirty files (first 15):"
    git -C "$ROOT" status --short 2>/dev/null | head -15 | sed 's/^/    /'
    echo "- worktrees:"
    git -C "$ROOT" worktree list 2>/dev/null | head -10 | sed 's/^/    /'
    if have_jq && [ -f "$LEDGER_FILE" ]; then
        echo "- open lanes (started, not stopped, this session):"
        jq -rs --arg s "$(session)" "$OPEN_LANES_JQ | (.ids[] | \"    \" + .), \"    (count: \\(.count))\"" "$LEDGER_FILE" 2>/dev/null
    fi
    echo
    echo "Preserve: the task and its brief, file scopes in flight, decisions made, commands run"
    echo "with results, failures seen, checks NOT run, the agent roster, and the next action."
    echo "Update HANDOFF.md now if any of that is only in the conversation."
} >"$out" 2>/dev/null
exit 0
