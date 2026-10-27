#!/bin/sh
# shellcheck disable=SC1091
# tdd_commit_post.sh (factory 0.3.0, spec §0.5): PostToolUse(Bash) and PostToolUseFailure(Bash), the
# authoritative half of the commit guard. A call that commits and then fails fires only PostToolUseFailure,
# so both events run it. For the call's .lanes/tdd-pending/<tool_use_id> entry (written by tdd_boundary.sh
# before every allowed `git commit`), each commit of the call is checked: author against the caller, the
# `TDD:` phase against its role (none: rule no-phase), a role's `TDD-Mode:` trailer, and the changed paths
# against the role; phase and mode as git's %(trailers) reads them, as H1/H9 and tdd.jl do (critic C2). A commit
# of the call (review 1 B2, B3) is on `git log --first-parent <before>..HEAD` (an amend yields the amended
# commit; a merge's second parent is main's history, never re-checked) with its COMMITTER time within
# [entry mtime - 5 s, entry mtime + 600 s] (600 s: the Bash tool's maximum). Each is appended to the owning
# ledger as tdd-commit {agent_id, agent_type, checkout, sha}; a broken rule also as tdd-commit-violation
# {..., rule, reason} and printed (exit 2: PostToolUse cannot undo a commit; audit E5 fails the lane). First,
# entries of other calls older than TDD_STALE_MIN minutes (a cancelled call fires neither event) are swept:
# each in-window commit gets only tdd-commit-late {agent_id, agent_type, checkout, sha}, which E5 does not
# accept (no tdd-commit, no violation, nothing printed), and the entry is deleted. `... sweep` only sweeps.
# The owning ledger (0.3.1 F2) is the one TDD ledger of a checkout: `owning_ledger` (_lib.sh), the main checkout of
# the repo owning it, whatever the session root (a subagent's is the coordinator, a teammate's the package); tdd.jl
# audit reads it by default. All three records go through `ledger()` with LEDGER_FILE set per checkout (own_ledger);
# a checkout git cannot read falls back to the session ledger.
# Advisory: it fails open (exit 1) without jq or a library; E5 then fails the unrecorded commits.
case $0 in */*) d=${0%/*} ;; *) d=. ;; esac
for _l in _lib.sh _bash_guard_lib.sh _tdd_commit_guard.sh; do
    [ -f "$d/$_l" ] || { printf '[factory] %s is missing: tdd_commit_post cannot record commits (audit E5 will fail them).\n' "$d/$_l" >&2; exit 1; }
done
. "$d/_lib.sh"
. "$d/_bash_guard_lib.sh"
. "$d/_tdd_commit_guard.sh"
for _f in "$PEND"/*; do [ -e "$_f" ] || exit 0; break; done # the common path: no commit pending, no fork
have_jq || { printf '[factory] jq not found: tdd_commit_post cannot record commits (audit E5 will fail them).\n' >&2; exit 1; }
tu=$(field '.tool_use_id | strings')
case $tu in *[!A-Za-z0-9_-]*) tu="" ;; esac
VIOL="" NOPH=""
SESSION_LEDGER=$LEDGER_FILE
# own_ledger CHECKOUT: point ledger() at CHECKOUT's owning ledger (the session ledger if git cannot say)
own_ledger() { LEDGER_FILE=$(owning_ledger "$1") || LEDGER_FILE=$SESSION_LEDGER; }

# check_commit CHECKOUT SHA AGENT_TYPE AGENT_ID: record one commit, and any rule it breaks (in LEDGER_FILE, which
# record has pointed at CHECKOUT's owning ledger)
check_commit() {
    _id=$(git -C "$1" log -1 --format='%an <%ae>' "$2" 2>/dev/null)
    id_rule "$3" "$_id"
    _rule=$IDR
    if tdd_role "$3"; then # critic C2: git's own trailer parse (the last paragraph), as H1/H9 and tdd.jl read it
        _ph=$(git -C "$1" log -1 --format='%(trailers:key=TDD,valueonly)' "$2" 2>/dev/null) && _ph=${_ph%%"$NL"*}
        _md=$(git -C "$1" log -1 --format='%(trailers:key=TDD-Mode,valueonly)' "$2" 2>/dev/null)
        case "$3:$_ph" in
            *:) _rule=${_rule:-no-phase} && NOPH=1 ;;
            implementer:stub | implementer:green | implementer:refactor) ;;
            implementer:*) _rule=${_rule:-phase-not-role} ;;
            *:red | *:test-fix | *:test-refactor | *:backfill) ;; # a test-side role (critic C1)
            *) _rule=${_rule:-phase-not-role} ;;
        esac
        [ -z "$_md" ] || _rule=${_rule:-mode-trailer}
        [ -z "$(git -C "$1" diff-tree --no-commit-id --name-only -r --root "$2" 2>/dev/null | role_paths "$3")" ] || _rule=${_rule:-path-not-role}
    fi
    ledger tdd-commit agent_id "$4" agent_type "$3" checkout "$1" sha "$2"
    [ -n "$_rule" ] || return 0
    ledger tdd-commit-violation agent_id "$4" agent_type "$3" checkout "$1" sha "$2" rule "$_rule" reason "$_rule"
    VIOL="$VIOL $_rule: $2 (author $_id, caller $3, in $1);"
}
# record FILE LATE: the call's commits (first parent since the entry's HEADs, committer time in the entry's
# window), then delete the entry (claimed by mv first, so a sweep and a post hook never record one entry twice).
# LATE (the sweep): tdd-commit-late only. A missing mtime records nothing (E5 then fails the commits).
record() {
    _c="$1.claim$$" _lt=$2
    mv "$1" "$_c" 2>/dev/null || return 0
    _m=$(stat -c %Y "$_c" 2>/dev/null || stat -f %m "$_c" 2>/dev/null)
    case $_m in '' | *[!0-9]*) rm -f "$_c"; return 0 ;; esac
    _at=- _aid=-
    while read -r _h _co; do
        case $_h in @) _at=${_co%% *} _aid=${_co#* }; continue ;; esac
        [ -d "$_co" ] || continue
        own_ledger "$_co"
        case $_h in none) _r=HEAD ;; *) _r="$_h..HEAD" ;; esac
        # shellcheck disable=SC2046 # "<sha> <committer time>" pairs, split on purpose
        set -- $(git -C "$_co" log --first-parent --max-count=100 --format='%H %ct' "$_r" 2>/dev/null)
        while [ $# -ge 2 ]; do
            if [ "$2" -ge $((_m - 5)) ] 2>/dev/null && [ "$2" -le $((_m + 600)) ]; then
                if [ -n "$_lt" ]; then
                    ledger tdd-commit-late agent_id "${_aid:--}" agent_type "${_at:--}" checkout "$_co" sha "$1"
                else check_commit "$_co" "$1" "${_at:--}" "${_aid:--}"; fi
            fi
            shift 2
        done
    done <"$_c"
    rm -f "$_c"
}

# shellcheck disable=SC2044 # entry names are tool_use_ids ([A-Za-z0-9_-], checked by tdd_boundary.sh)
for _f in $(find "$PEND" -mindepth 1 -maxdepth 1 -type f -mmin +"$TDD_STALE_MIN" 2>/dev/null); do
    [ "${_f##*/}" = "$tu" ] || record "$_f" true
done
[ "${1:-}" = sweep ] || [ -z "$tu" ] || [ ! -f "$PEND/$tu" ] || record "$PEND/$tu" ""
[ -z "$VIOL" ] && exit 0
printf '[factory] tdd commit violation (spec §0.5):%s PostToolUse cannot undo a commit: tdd.jl audit (E5) fails this lane until it is replaced by a commit that fits the role.\n' "$VIOL" >&2
[ -z "$NOPH" ] || printf '[factory] no-phase: git reads trailers only from the last paragraph, so -m "TDD: ..." in its own paragraph is no phase. While it is still HEAD, amend it in its own Bash call: git -C <checkout> commit -q --amend --no-edit --trailer "TDD: <phase>". Next time: git -C <checkout> commit -q --author "<role> <<role>@factory.invalid>" -m "<subject>" --trailer "TDD: <phase>" --trailer "Co-Authored-By: ...".\n' >&2
exit 2
