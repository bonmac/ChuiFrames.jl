#!/bin/sh
# session_start.sh: SessionStart (matcher "compact"). Prints the snapshot precompact.sh wrote,
# capped at 40 lines; SessionStart stdout is added to Claude's context. Fails open.
. "$(dirname -- "$0")/_lib.sh"
snap="$ROOT/.lanes/precompact.md"
[ -f "$snap" ] || exit 0
head -40 "$snap"
exit 0
