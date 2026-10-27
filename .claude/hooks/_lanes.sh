# shellcheck shell=sh
# _lanes.sh (0.2.8): how the lane ledger counts open lanes. Sourced after _lib.sh by
# dispatch_limit.sh, lane_ledger.sh and precompact.sh; never run. Split from _lib.sh to keep both
# under the 150-line hook budget (ratchets.toml).

# lane_key: the lane an Agent/Task call opens or closes. PreToolUse and PostToolUse of one call
# give the same key: tool_input.name (a teammate), else tu:<tool_use_id>, else desc:<description>.
lane_key() {
    _k=$(field '.tool_input.name')
    [ -z "$_k" ] || { printf '%s' "$_k"; return 0; }
    _k=$(field '.tool_use_id')
    [ -z "$_k" ] || { printf 'tu:%s' "$_k"; return 0; }
    printf 'desc:%s' "$(field '.tool_input.description')"
}

# LANE_TTL_SECS: a dispatch that never ran (no `spawned` or `unknown-result` record: a permission
# denial, another hook's denial, a validation error) stops counting after FACTORY_LANE_TTL_HOURS
# (default 24; 0 = never). A lane with such a record stays counted however long it lives
# (sub-leads run for days; critic M4): close it with TaskStop or `scripts/lane release`. A
# foreground call has no record until it returns, so one running past the TTL stops counting
# (reviewer m3, a blind spot). Not a whole number: 24.
_ttl=${FACTORY_LANE_TTL_HOURS:-24}
case $_ttl in '' | *[!0-9]*) _ttl=24 ;; esac
# shellcheck disable=SC2034 # used by the hooks that source this file
LANE_TTL_SECS=$((_ttl * 3600))

# OPEN_LANES_JQ (run with --arg s SESSION --argjson ttl "$LANE_TTL_SECS"): the `dispatch` events of
# this session (each teammate is its own session, so the cap is per agent, not per team) that no
# later event closes. A later event closes a dispatch if it is:
# - a `close` with the same key, or a ref equal to its name, key or spawned agent_id; a close from
#   `scripts/lane release` has session "*" and matches in every session;
# - a `close` whose ref names no dispatch or agent of this session (a TaskStop given an internal
#   task id) and whose desc equals its description (critic M2: never for a ref that names a lane);
# - a SubagentStop (`stop`) whose agent_id is its spawned agent_id.
# SubagentStart/Stop alone count nothing: in-process teammates do not balance them (0.2.7 counted
# start - stop, and the cap never fired). One count per key; a ts that does not parse counts as
# fresh. Cost: O(dispatches x events) per call, ~0.8 s for 150 dispatches in 3,000 events (critic m5).
# shellcheck disable=SC2034 # used by the hooks that source this file
OPEN_LANES_JQ='now as $now
  | [.[] | select(.session == $s or (.session == "*" and .ev == "close"))] as $all
  | [range(0; $all | length) as $i | $all[$i] + {_i: $i}] as $e
  | ([$e[] | select(.ev == "dispatch") | .name, .key]
     + [$e[] | select(.ev == "spawned") | .agent_id] | map(select(. != null and . != "-"))) as $known
  | [$e[] | select(.ev == "dispatch") | . as $d
     | [$e[] | select((.ev == "spawned" or .ev == "unknown-result") and ._i > $d._i and .key == $d.key)] as $ran
     | [$ran[] | .agent_id | select(. != null and . != "-")] as $aids
     | select(([$e[] | select(._i > $d._i)
         | select(
             (.ev == "close" and (
                 .key == $d.key
                 or ((.ref // "-") as $r | $r != "-" and (
                     $r == $d.name or $r == $d.key or any($aids[]; . == $r)
                     or ((any($known[]; . == $r) | not) and (.desc // "-") != "-" and .desc == $d.desc)))))
             or (.ev == "stop" and (.agent_id as $a | any($aids[]; . == $a))))
         ] | length) == 0)
     | select($ttl == 0 or ($ran | length) > 0 or (try ($d.ts | fromdateiso8601) catch $now) > $now - $ttl)
     | $d.key] | unique as $ids
  | {ids: $ids, count: ($ids | length)}'

# tdd_dispatch SUB AGENT_TYPE (factory 0.3.0, spec §0.6; review 1 M1): tdd_boundary's check of a TDD role's
# dispatch (tdd_role, _lib.sh: a test-side role or the implementer; critic C1), run by tdd_boundary.sh AND dispatch_limit.sh (parallel hooks of one Agent|Task call, no
# order), so a dispatch tdd_boundary denies is never recorded as an open lane. Only the lead (no agent_type)
# dispatches a role, on a clean lane worktree whose HEAD is the brief's head=, with lane= its lane. Returns 0
# (allowed, or not a role dispatch) or 1 with TD_RULE and TD_MSG. Sets TD_PR (the prompt), TD_LN, TD_MAIN.
td_no() { TD_RULE=$1 TD_MSG=$2; return 1; }
# shellcheck disable=SC2034 # TD_* are read by tdd_boundary.sh and dispatch_limit.sh
tdd_dispatch() {
    TD_RULE="" TD_MSG="" TD_PR="" TD_LN="" TD_MAIN=""
    tdd_role "$1" || return 0
    [ -z "$2" ] || { td_no dispatch-not-lead "only the lead (no agent_type) dispatches a $1; this caller is $2"; return; }
    TD_PR=$(field '.tool_input.prompt | strings')
    _ro="" _co="" _he="" _hd=${TD_PR%%"
"*}
    case $_hd in '<!-- tdd-brief '*' -->') ;; *) td_no brief-header "a $1 prompt starts with <!-- tdd-brief role=$1 lane=<lane> checkout=<abs path> head=<sha> --> (julia scripts/tdd.jl brief prints it)"; return ;; esac
    set -f
    for _w in $_hd; do case $_w in role=*) _ro=${_w#*=} ;; lane=*) TD_LN=${_w#*=} ;; checkout=*) _co=${_w#*=} ;; head=*) _he=${_w#*=} ;; esac; done
    set +f
    [ "$_ro" = "$1" ] || { td_no brief-role "the brief says role=$_ro but the dispatch is a $1"; return; }
    case $TD_LN in '' | .* | *[!A-Za-z0-9._-]*) td_no brief-lane "lane=$TD_LN is not a lane name"; return ;; esac
    case ${_co%/} in */.worktrees/"$TD_LN" | */.claude/worktrees/"$TD_LN") ;; */.worktrees/* | */.claude/worktrees/*)
        td_no brief-lane "lane=$TD_LN is not the lane of checkout=$_co"; return ;; esac
    case $_co in /*) phys "$_co" ;; *) td_no brief-checkout "checkout= must be an absolute path: $_co"; return ;; esac
    case $RP in "$ROOT_P"/?*) ;; *) td_no brief-checkout "checkout=$_co is not under the session root $ROOT"; return ;; esac
    _gl="" _bk=""
    [ ! -f "$RP/.git" ] || read -r _gl <"$RP/.git"
    case $_gl in "gitdir: /"*/.git/worktrees/?*) read -r _bk <"${_gl#gitdir: }/gitdir" 2>/dev/null ;; esac
    case $_bk in "$RP/.git" | "$_co/.git") ;; *) td_no brief-checkout "checkout=$_co is not a lane worktree (git worktree add), so it has no main checkout to save the brief in"; return ;; esac
    TD_MAIN=${_gl#gitdir: } && TD_MAIN=${TD_MAIN%/.git/worktrees/*}
    [ -n "$_he" ] && [ "$(git -C "$RP" rev-parse HEAD 2>/dev/null)" = "$_he" ] ||
        { td_no brief-head "head=$_he is not the HEAD of $_co: write the brief again (julia scripts/tdd.jl brief)"; return; }
    [ -z "$(git -C "$RP" status --porcelain 2>/dev/null)" ] || { td_no brief-dirty "$_co has uncommitted changes: commit or clean them before dispatching a $1"; return; }
    # review 2 (iii): the prompt-save step's precondition is checked here too, so dispatch_limit records no lane that
    # tdd_boundary then denies at the save (only a write that fails after this check, e.g. a full disk, still can)
    _sd="$TD_MAIN/.lanes/briefs/$TD_LN/dispatched"
    { mkdir -p "$_sd" && [ -w "$_sd" ]; } 2>/dev/null || td_no brief-save "cannot save the prompt under $_sd (fails closed)"
}
