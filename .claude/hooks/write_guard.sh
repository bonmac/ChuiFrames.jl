#!/bin/sh
# write_guard.sh: PreToolUse(Edit|Write|MultiEdit|NotebookEdit).
#  1. Blocks writes outside the repo root (scratch dirs allowed, see _lib.sh `allowed`).
#  2. Blocks writes to T3 protected paths from risk.toml (via the generated
#     .claude/hooks/protected-paths.txt). T0-T2 are enforced at merge by scripts/dod.jl.
# The path is matched relative to the nearest enclosing git checkout (a worktree lane or a
# nested package repo), using that checkout's protected-paths.txt when it has one.
# Override (session env only, set by the user for an approved T3 change): FACTORY_ALLOW_T3=1
. "$(dirname -- "$0")/_lib.sh"
need_jq
fp=$(field '.tool_input.file_path // .tool_input.notebook_path')
[ -n "$fp" ] || exit 0
abs=$(abspath "$fp" "$(field '.cwd')")
allowed "$abs" || deny "write outside the repo root blocked: $abs (root: $ROOT)."

case $abs in "$ROOT" | "$ROOT"/* | "$ROOT_P" | "$ROOT_P"/*) ;; *) exit 0 ;; esac # scratch dir

repo=$ROOT
d=$(dirname "$abs")
while :; do
    if [ -e "$d/.git" ]; then repo=$d; break; fi
    case $d in "$ROOT" | "$ROOT_P" | / | .) break ;; esac
    d=$(dirname "$d")
done
rel=${abs#"$repo"/}
list="$repo/.claude/hooks/protected-paths.txt"
[ -f "$list" ] || list="$HOOKS_DIR/protected-paths.txt"
[ -f "$list" ] || exit 0

lower() { printf '%s' "$1" | tr '[:upper:]' '[:lower:]'; }
rel_l=$(lower "$rel") # compare lowercased: APFS (macOS default) is case-insensitive
set -f
while read -r tier glob; do
    case $tier in '' | '#'*) continue ;; esac
    glob_l=$(lower "$glob")
    # shellcheck disable=SC2254 # the pattern IS a glob
    case $rel_l in
        $glob_l)
            if [ "$tier" = T3 ] && [ "${FACTORY_ALLOW_T3:-}" != 1 ]; then
                deny "$rel is a T3 protected path ($glob in risk.toml). It needs an ADR and the user's approval; the user sets FACTORY_ALLOW_T3=1 for that change."
            fi
            ;;
    esac
done <"$list"
exit 0
