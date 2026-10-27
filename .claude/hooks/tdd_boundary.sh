#!/bin/sh
# shellcheck disable=SC1091,SC2034,SC2154 # eval sets the payload fields; the guard reads AN, AE and CWD_OK
# tdd_boundary.sh (factory 0.3.0, spec §0.6): PreToolUse(Read|Grep|Glob|Edit|Write|MultiEdit|NotebookEdit|Bash)
# and PreToolUse(Agent|Task). The role is the payload's agent_type ONLY (plan Task 0: a named teammate has no
# agent_id; the lead is the caller with no agent_type). A test-side role (test_role, _lib.sh: the test-writer and
# the law/property/differential testers, critic C1) reads and writes only allowlisted paths
# and runs only allowlisted Bash (_tdd_allow.sh); an implementer writes no test/**; every caller's `git commit`
# passes the commit guard (_tdd_commit_guard.sh, §0.5); only the lead dispatches a role, on a clean lane with
# a current tdd-brief, and the prompt is saved. Paths resolve, symlinks followed, to their checkout (co_of).
# Exit 2 = deny (logged as tdd-boundary-denied). Fails closed, for every caller, without jq, a library or a
# parseable payload. Blind spots: docs/CHECK_COVERAGE.md.
case $0 in */*) d=${0%/*} ;; *) d=. ;; esac
for _l in _lib.sh _lanes.sh _bash_guard_lib.sh _tdd_commit_guard.sh _tdd_allow.sh; do # a missing library must block (exit 2)
    [ -f "$d/$_l" ] || { printf '[factory] %s is missing; tdd_boundary fails closed. Restore it (julia scripts/sync_factory.jl).\n' "$d/$_l" >&2; exit 2; }
done
. "$d/_lib.sh"
. "$d/_lanes.sh"
. "$d/_bash_guard_lib.sh"
. "$d/_tdd_commit_guard.sh"
. "$d/_tdd_allow.sh"
need_jq
ok=""
eval "$(printf '%s' "$PAYLOAD" | jq -r 'select(type == "object") | (.tool_input | objects // {}) as $i | @sh "tool=\(.tool_name // "" | tostring) at=\(.agent_type // "" | tostring) aid=\(.agent_id // "" | tostring) tu=\(.tool_use_id // "" | tostring) cwd=\(.cwd // "" | tostring) bg=\($i.run_in_background // false | tostring) cmd=\($i.command // "" | tostring) fp=\($i.file_path // $i.notebook_path // "" | tostring) gp=\($i.path // "" | tostring) pat=\($i.pattern // "" | tostring) sub=\($i.subagent_type // "" | tostring) ok=1"' 2>/dev/null)"
[ "$ok" = 1 ] || deny "tdd_boundary: cannot parse the hook payload as a JSON object (fails closed, spec §0.6)."
case $tu in '' | *[!A-Za-z0-9_-]*) tu="x$$" ;; esac
cwd=${cwd:-$ROOT}
TW="" CWD_OK=1 PENDING=""
! test_role "$at" || TW=1 # critic C1: every test-side role (_lib.sh) gets the test-writer's boundary
tdeny() { ledger tdd-boundary-denied agent_type "${at:--}" tool "${tool:--}" rule "$1"; deny "tdd_boundary $2 ($1): $3"; }
for _f in "$PEND"/*; do # the sweep (§0.5): an entry left by a cancelled call (no post event) is recorded late
    [ -e "$_f" ] && [ -n "$(find "$PEND" -mindepth 1 -maxdepth 1 -mmin +"$TDD_STALE_MIN" 2>/dev/null)" ] &&
        printf '%s' "$PAYLOAD" | sh "$d/tdd_commit_post.sh" sweep >/dev/null 2>&1
    break
done
dispatch() { # the lead dispatches a role only on a clean lane worktree with a current tdd-brief (_lanes.sh); the prompt is saved
    tdd_role "$sub" || exit 0
    tdd_dispatch "$sub" "$at" || tdeny "$TD_RULE" §0.6 "$TD_MSG"
    _dir="$TD_MAIN/.lanes/briefs/$TD_LN/dispatched"
    { mkdir -p "$_dir" && printf '%s\n' "$TD_PR" >"$_dir/$(date -u +%Y%m%dT%H%M%SZ)-$sub-$tu.md"; } 2>/dev/null ||
        tdeny brief-save §0.6 "cannot save the prompt under $_dir (fails closed)"
}

case $tool in
    Agent | Task) dispatch; exit 0 ;;
    Bash) ;;
    Read | Grep | Glob)
        [ -n "$TW" ] || exit 0
        _t=$fp
        [ "$tool" = Read ] || _t=$gp
        [ -n "$_t" ] || tdeny tw-read-no-path §0.6 "a test-writer's $tool names a path inside its read allowlist"
        [ "$tool" != Glob ] || case $pat in /* | '~'* | *..*) tdeny tw-glob §0.6 "a Glob pattern may not be absolute or contain ..: $pat" ;; esac
        tw_read_ok "$(abspath "$_t" "$cwd")" || tdeny tw-read §0.6 "$TW_READ; not $_t"
        exit 0 ;;
    Edit | Write | MultiEdit | NotebookEdit)
        tdd_role "$at" || exit 0
        co_of "$(abspath "$fp" "$cwd")"
        case /$fp/ in */.[Gg][Ii][Tt]/*) tdeny role-git-path §0.6 "a $at never writes a .git path (it would move the checkout root): $fp" ;; esac
        if [ -n "$TW" ]; then
            in_root && case $REL in test/runtests.jl | test/Project.toml) ;; test/?*) exit 0 ;; esac
            tdeny tw-write §0.6 "a $at writes only test/** of a checkout, never the seeded runners test/runtests.jl and test/Project.toml: not $fp"
        fi
        case $REL in test | test/*) tdeny impl-test-write §0.6 "an implementer never writes test/**: $fp; send the lead a written test-fix request" ;; esac
        exit 0 ;;
    *) exit 0 ;;
esac
# Bash: the lead and other callers only meet the commit guard; the fast path skips a command that cannot commit
tdd_role "$at" || case $cmd in *commit* | *\\* | *\'* | *\"*) ;; *) exit 0 ;; esac
[ ${#cmd} -le 65536 ] || tdeny too-long §0.6 "a command over 64 KiB cannot be checked in time"
! tdd_role "$at" || case $cmd in *"\$'"* | *'$"'*) # R2-B1: segments() cannot model them
    tdeny ansi-c-quote §0.6 "a $at may not use \$'...' or \$\"...\" quoting (bash and zsh expand its escapes into any path); write the plain word" ;;
esac
[ -z "$TW" ] || case $cmd in *'$'* | *'`'* | *'<<'*) # R3-B1: segments() drops heredoc bodies, which bash expands
    tdeny tw-heredoc §0.6 "a $at's command may not contain \$, a backquote or a heredoc (<<, <<<); write plain words: put a commit message in plain quotes (-m \"test: ...\"), no \$, backquotes or heredocs" ;;
esac
[ "$at" != implementer ] || impl_libs
segs=$(printf '%s\n' "$cmd" | segments)
set -f
while IFS= read -r seg; do
    # shellcheck disable=SC2086
    set -- $seg
    if [ "$at" = implementer ]; then # its write targets under test/ (bash_guard's model); check_cmd tracks cd
        _pv=""
        for _w; do case $_pv in *'>') outside "$_w" ;; esac; case $_w in *'>'?*) outside "${_w##*>}" ;; esac; _pv=$_w; done
        check_cmd "$@"
    fi
    if [ -n "$TW" ]; then # no expansions; redirections only to /dev/null
        _k=$# _pv=""
        while [ "$_k" -gt 0 ]; do
            _w=$1 _k=$((_k - 1))
            shift
            case $_pv in *'>') [ "$_w" = /dev/null ] || tdeny tw-redirect §0.6 "a test-writer redirects only to /dev/null"; _pv=""; continue ;; esac
            case $_w in
                *'$'* | *'`'* | *'{'* | *'}'* | '~'*) tdeny tw-expansion §0.6 "an expansion (\$, \`, {}, ~) cannot be checked against the allowlist: $_w" ;;
                *'>') _pv=$_w; continue ;;
                *'>/dev/null') continue ;;
                *'<'* | *'>'*) tdeny tw-redirect §0.6 "a test-writer redirects only to /dev/null: $_w" ;;
            esac
            set -- "$@" "$_w"
        done
    fi
    AN="" AE=""
    while [ $# -gt 0 ]; do # assignments (GIT_AUTHOR_* feed the guard) and simple wrappers
        case $1 in
            GIT_AUTHOR_NAME=*) AN=${1#*=} ;;
            GIT_AUTHOR_EMAIL=*) AE=${1#*=} ;;
            GIT_COMMITTER_*=* | GIT_AUTHOR_DATE=* | CI_*=*) ;;
            [A-Za-z_]*=* | env | command | exec | nohup | time | '!' | '{' | '}' | if | then | else | elif | do | while | until)
                [ -z "$TW" ] || tdeny tw-bash §0.6 "\`$1\` is not on the test-writer's Bash allowlist" ;;
            *) break ;;
        esac
        shift
    done
    [ $# -gt 0 ] || continue
    case ${1##*/} in
        cd | pushd)
            [ "$at" != implementer ] || continue
            _nd=$(newdir "${2:-}")
            if [ -n "$_nd" ]; then cwd=$_nd; else [ -z "$TW" ] || tdeny tw-cd §0.6 "a test-writer's cd names a literal directory"; CWD_OK=""; fi ;;
        git)
            shift
            [ -z "$TW" ] || tw_git "$@"
            gsub "$@"
            [ "$GS" != commit ] || guard_commit "$@" ;;
        *)
            _sg="" # echo/printf only mention git commit (Minor 6); a wrapper (xargs, sh) running it is unmodelled
            case ${1##*/} in echo | printf) _sg=x ;; esac
            [ "$_sg" = x ] || for _w; do case $_w in git | */git) _sg=1 ;; commit) [ -z "$_sg" ] || cdeny unmodelled "a git commit run through ${1##*/} is not modelled; run git commit directly" ;; esac; done
            [ -z "$TW" ] || tw_cmd "$@" ;;
    esac
done <<EOF
$segs
EOF
set +f
[ -z "$PENDING" ] || { mkdir -p "$PEND" && printf '@ %s %s\n%s' "${at:--}" "${aid:--}" "$PENDING" >"$PEND/$tu"; } 2>/dev/null ||
    tdeny pending §0.5 "cannot write $PEND/$tu, so this commit could not be checked after it runs (fails closed)"
exit 0
