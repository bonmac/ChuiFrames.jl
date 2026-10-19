#!/bin/sh
# write_guard.sh: PreToolUse(Edit|Write|MultiEdit|NotebookEdit).
#  1. Blocks writes outside the repo root (scratch dirs allowed, see _lib.sh `allowed`).
#  2. Blocks writes to T3 protected paths from risk.toml (via the generated
#     .claude/hooks/protected-paths.txt). T0-T2 are enforced at merge by scripts/dod.jl.
# The T3 check is bash_guard's (`t3_check` in _bash_guard_write.sh, 0.2.4): the path is matched
# against the nearest enclosing real git checkout (a worktree lane or a nested package repo,
# with its own protected-paths.txt when it has one) AND against the repo root's list. Writes
# below a .git directory are blocked, and a missing protected-paths.txt fails closed.
# Override (session env only, set by the user for an approved T3 change): FACTORY_ALLOW_T3=1
# Fails closed (0.2.4) on a payload that is not JSON or names no target path string.
d=$(dirname -- "$0") # a missing library must block (exit 2), not fail open
for _l in _lib.sh _bash_guard_write.sh; do
    [ -f "$d/$_l" ] || { printf '[factory] %s is missing; write_guard fails closed.\n' "$d/$_l" >&2; exit 2; }
done
. "$d/_lib.sh"
. "$d/_bash_guard_write.sh"
need_jq
fp=$(field '(.tool_input.file_path // .tool_input.notebook_path // .tool_input.path) | strings')
if [ -z "$fp" ]; then # 0.2.4: "could not check" is not "nothing to check"
    payload_ok || deny "the hook payload is not a JSON object, so write_guard cannot read the target; it fails closed."
    deny "no target path string in the payload (tool $(field .tool_name); looked for tool_input.file_path, notebook_path, path); write_guard fails closed."
fi
abs=$(abspath "$fp" "$(field '.cwd')")
allowed "$abs" || deny "write outside the repo root blocked: $abs (root: $ROOT)."
set -f
t3_check "$abs" # returns at once for a scratch path outside the root
exit 0
