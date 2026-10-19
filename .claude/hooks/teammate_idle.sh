#!/bin/sh
# teammate_idle.sh: TeammateIdle. The first idle of a teammate without a report is blocked
# (exit 2: stderr goes back to the teammate, which keeps working) and a report is demanded.
# A report counts if `.lanes/reports/<name>.md` exists. The second idle is allowed (a hook
# that blocks every idle is a loop) and logged as `idle-unreported` so the lead treats the
# lane as FAILED unless a SendMessage report arrived. Fails open.
. "$(dirname -- "$0")/_lib.sh"
have_jq || exit 0
name=$(field '.teammate_name')
[ -n "$name" ] || exit 0
safe=$(printf '%s' "$name" | tr -c 'A-Za-z0-9_.-' '_')
key="$(field '.session_id')/$(field '.team_name')/$safe"
report="$ROOT/.lanes/reports/$safe.md"
seen="$ROOT/.lanes/teammate-idle.seen"

if [ -f "$report" ]; then
    ledger idle-reported teammate "$safe"
    exit 0
fi
mkdir -p "$ROOT/.lanes" 2>/dev/null || exit 0
if grep -qxF -- "$key" "$seen" 2>/dev/null; then
    ledger idle-unreported teammate "$safe"
    exit 0
fi
printf '%s\n' "$key" >>"$seen" 2>/dev/null || exit 0 # cannot remember => never block
ledger idle-blocked teammate "$safe"
deny "Before going idle, send your final report to the lead with SendMessage (summary, files changed, commands run with output, checks NOT run and why, scorecard), or write it to .lanes/reports/$safe.md. An idle lane with no report is treated as FAILED."
