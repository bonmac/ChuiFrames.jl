#!/bin/sh
# bash_guard.sh: PreToolUse(Bash). Blocks a short denylist, writes outside the repo root, and
# any command that RUNS inside a read-only root (.agents/factory.toml [bash_guard]) unless
# it is a read-only command. `cd`/`pushd` are tracked across `&&`, `;`, `|` segments.
# A speed bump, not a sandbox: blind spots are listed in docs/CHECK_COVERAGE.md.
# Exit 2 = blocked (stderr goes to Claude). Overrides are read from the SESSION env only
# (an inline `FACTORY_ALLOW_PUSH=1 git push` does not reach this hook):
#   FACTORY_ALLOW_PUSH=1     allow `git push` (not --force) once the user approved pushing
#   FACTORY_ALLOW_OUTWARD=1  allow gh actions that create or change things on GitHub
#   FACTORY_ALLOW_T3=1       allow modelled Bash writes to T3 paths (as for write_guard; 0.2.4)
d=$(dirname -- "$0")
for _l in _lib.sh _bash_guard_lib.sh _read_only_roots.sh _bash_guard_cmd.sh _bash_guard_write.sh; do # a missing library must block (exit 2), not fail open
    [ -f "$d/$_l" ] || { printf '[factory] %s is missing; bash_guard fails closed. Restore it (julia scripts/sync_factory.jl).\n' "$d/$_l" >&2; exit 2; }
done
. "$d/_lib.sh"
. "$d/_bash_guard_lib.sh"
. "$d/_read_only_roots.sh"
. "$d/_bash_guard_cmd.sh"
. "$d/_bash_guard_write.sh"
T3_HINT=" For other files use the Edit/Write tools, not sed -i, redirects or heredocs."
need_jq
raw=$(field '.tool_input.command | strings')
if [ -z "$raw" ]; then # 0.2.4: no command string to check is not "nothing to check" (an empty command runs nothing)
    printf '%s' "$PAYLOAD" | jq -e '.tool_input.command == ""' >/dev/null 2>&1 && exit 0
    deny "the hook payload has no command string (not JSON, or tool_input.command missing or not a string); bash_guard fails closed."
fi
# A huge command could outlast the 10 s hook timeout, which fails OPEN: refuse it (0.2.3).
[ ${#raw} -le 65536 ] || deny "this command is longer than 64 KiB, too long to check within the hook timeout. Split it, or write a script file and review it first."
cwd=$(field '.cwd')
cwd=${cwd:-$ROOT}
if [ -n "$RO_MISSING" ]; then # read-only roots are required here but none are configured or generated
    case $raw in
        'julia scripts/gen.jl' | 'julia scripts/gen.jl --check') ;;
        *) deny "this repo requires read-only roots (.agents/factory.toml require_read_only_roots) but .claude/hooks/read-only-roots.txt is missing or lists none; bash_guard fails closed. Put the roots in .agents/factory.local.toml (gitignored) and run \`julia scripts/gen.jl\`." ;;
    esac
fi

# One simple command per line (_bash_guard_lib.sh): heredoc bodies dropped, quoted text one
# word with its quotes removed, `\`+newline joined. The denylist and the per-command checks
# both read it, so a quoted commit message is not a command and `"git" reset` is.
segs=$(printf '%s\n' "$raw" | segments)
has() { printf '%s\n' "$segs" | grep -Eq -- "$1"; }
S='(^|[;&|(`[:space:]])'                          # start of a command word
G="${S}git([[:space:]]+(-[Cc][[:space:]]+[^[:space:]]+|--(git-dir|work-tree|namespace)[[:space:]]+[^[:space:]]+|-[[:alpha:]]|--[a-z-]+(=[^[:space:]]+)?))*[[:space:]]+" # git + global options
has "${G}reset[[:space:]]+--hard" && deny "git reset --hard is blocked: it discards work. Use a WIP commit or ask."
has "${G}clean([[:space:]].*)?[[:space:]](--force([[:space:]=]|$)|-[[:alnum:]]*f)" && deny "git clean -f is blocked: it deletes untracked files."
has "${G}add[[:space:]]+(-A|--all|\.|:/)([[:space:]]|$)" &&
    deny "git add -A/./:/ is blocked: stage named paths so nothing stray is committed."
if has "${G}stash([[:space:]]|$)"; then
    has "${G}stash[[:space:]]+(list|show|apply)([[:space:]]|$)" ||
        has "${G}stash[[:space:]]+push[[:space:]].*(-m|--message)" ||
        deny "only 'git stash push -m <tag>', 'git stash apply <sha>', list and show are allowed: the stash stack is shared by all worktrees. Prefer a WIP commit; ask the lead to drop entries."
fi
has "${G}[a-z-]+[[:space:]].*--no-verify" && deny "--no-verify is blocked: fix the failing hook instead."
has "${G}commit[[:space:]](.*[[:space:]])?-[a-ln-zA-Z]*n" && deny "git commit -n (--no-verify) is blocked: fix the failing hook instead."
has "${S}git[[:space:]](.*[[:space:]])?-c[[:space:]]*alias\." && deny "git -c alias.* is blocked: an alias hides the command that runs."
has "${S}(pkill|killall)[[:space:]]" && deny "pkill/killall are blocked: kill a named PID you started."
if has "${G}push([[:space:]]|$)"; then
    has "--force([^-]|$)|[[:space:]]-f([[:space:]]|$)" && deny "git push --force is blocked; use --force-with-lease, with the user's approval."
    [ "${FACTORY_ALLOW_PUSH:-}" = 1 ] || deny "git push needs the user's confirmation (ECOSYSTEM.md §1.6). The user sets FACTORY_ALLOW_PUSH=1 for the session once approved."
fi
GH="${S}gh[[:space:]]+"
if has "${GH}(repo[[:space:]]+(create|delete|edit|rename|archive|fork)|release[[:space:]]+(create|delete|edit|upload)|issue[[:space:]]+(create|comment|close|edit|reopen|delete)|pr[[:space:]]+(create|merge|comment|close|edit|review|ready|reopen)|workflow[[:space:]]+(run|enable|disable)|run[[:space:]]+(rerun|cancel|delete)|(secret|variable)[[:space:]]+(set|delete)|label[[:space:]]+(create|edit|delete))" ||
    has "${GH}api[[:space:]].*(-X[[:space:]]*|--method[[:space:]=]*)(POST|PATCH|PUT|DELETE)" ||
    has "${GH}api[[:space:]].*[[:space:]](-[fF]|--field|--raw-field|--input)([[:space:]=]|$)"; then
    [ "${FACTORY_ALLOW_OUTWARD:-}" = 1 ] || deny "This gh command acts on GitHub and needs the user's confirmation (ECOSYSTEM.md §1.6)."
fi

# --- per command: rm -rf, writes outside the repo root, read-only roots (_bash_guard_cmd.sh) ---
set -f
printf '%s\n' "$segs" | {
    while IFS= read -r seg; do
        # shellcheck disable=SC2086
        set -- $seg
        prev="" T3_DIR=""
        for tok in "$@"; do # redirection targets: >f, >>f, 2>f, &>f, >|f, x->f, or `> f` (quoted text is never one)
            case $prev in *'>') outside "$tok" ;; esac
            case $tok in *'>'?*) outside "${tok##*>}" ;; esac
            prev=$tok
        done
        check_cmd "$@"
    done
}
status=$?
set +f
exit $status
