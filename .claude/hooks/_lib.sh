# shellcheck shell=sh
# _lib.sh: shared helpers for the factory hooks. Sourced, never run.
# POSIX sh + jq, because a hook runs on every tool call: sh+jq starts in ~5 ms,
# `julia` in ~150 ms warm (measured 2026-10-19, see factory/README.md).
# Guards (bash_guard, write_guard, dispatch_limit) fail CLOSED when jq is missing;
# advisory hooks (ledger, idle, precompact) fail OPEN.

HOOKS_DIR=$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd)
ROOT=${CLAUDE_PROJECT_DIR:-$(pwd)}
ROOT=${ROOT%/}
ROOT_P=$(CDPATH='' cd -- "$ROOT" 2>/dev/null && pwd -P || printf '%s' "$ROOT")
PAYLOAD=$(cat)

have_jq() { command -v jq >/dev/null 2>&1; }
need_jq() { have_jq || deny "jq not found on PATH; this guard fails closed. Install jq."; }
field() { printf '%s' "$PAYLOAD" | jq -r "($1) // empty" 2>/dev/null; }
session() { _s=$(field .session_id); printf '%s' "${_s:--}"; }
deny() { printf '[factory] %s%s\n' "$*" "$(root_hint)" >&2; exit 2; }

# root_hint: when the session root is a factory template (factory/template, next to
# MANIFEST.toml), its hooks treat the TEMPLATE as the repo root. Say so in every denial.
root_hint() {
    if [ -f "$ROOT/../MANIFEST.toml" ] && [ "${ROOT##*/}" = template ]; then
        printf ' Note: this session runs with project root %s, a factory template, so the template'"'"'s own hooks apply. Dispatch lanes from the repo root (see factory/README.md).' "$ROOT"
    fi
}

if [ -f "$HOOKS_DIR/limits.env" ]; then . "$HOOKS_DIR/limits.env"; fi
LEDGER_FILE="$ROOT/${LEDGER:-.lanes/ledger.jsonl}"

# ledger EVENT [KEY VALUE]...: append one JSON line; never fails the hook.
ledger() {
    have_jq || return 0
    mkdir -p "$(dirname "$LEDGER_FILE")" 2>/dev/null || return 0
    ev=$1; shift
    args=""
    while [ $# -ge 2 ]; do
        _v=$(printf '%s' "$2" | tr -c 'A-Za-z0-9_./:@-' '_')
        args="$args --arg $1 ${_v:--}"
        shift 2
    done
    # shellcheck disable=SC2086
    jq -cn --arg ts "$(date -u +%Y-%m-%dT%H:%M:%SZ)" --arg ev "$ev" \
        --arg session "$(session)" $args '$ARGS.named' >>"$LEDGER_FILE" 2>/dev/null || true
}

# OPEN_LANES_JQ: agents whose last start/stop event in this session ($s) is a start.
# Events without an agent_id count as starts minus stops (never below zero).
# shellcheck disable=SC2034 # used by the hooks that source this file
OPEN_LANES_JQ='[.[] | select(.session == $s and (.ev == "start" or .ev == "stop"))] as $e
  | ([$e[] | select(.agent_id != "-" and .agent_id != null)] | group_by(.agent_id)
     | map(select(last.ev == "start") | .[0].agent_id)) as $ids
  | ([$e[] | select(.agent_id == "-" or .agent_id == null)]
     | ([.[] | select(.ev == "start")] | length) - ([.[] | select(.ev == "stop")] | length)
     | if . < 0 then 0 else . end) as $anon
  | {ids: $ids, count: (($ids | length) + $anon)}'

# normpath ABS: collapse //, /./ and /../ textually (symlinks are not resolved).
normpath() {
    _out=""
    _oldifs=$IFS
    case $- in *f*) _noglob=1 ;; *) _noglob="" ;; esac # restore the caller's noglob state
    IFS=/
    set -f
    for _seg in $1; do
        case $_seg in
            '' | .) ;;
            ..) _out=${_out%/*} ;;
            *) _out="$_out/$_seg" ;;
        esac
    done
    [ -n "$_noglob" ] || set +f
    IFS=$_oldifs
    printf '%s\n' "${_out:-/}"
}

# abspath PATH [BASE]: expand ~, make relative paths absolute against BASE, normalise.
# shellcheck disable=SC2088 # matching a literal "~/" prefix is the point
abspath() {
    case $1 in
        "~") _p=$HOME ;;
        "~/"*) _p="$HOME/${1#"~/"}" ;;
        '$HOME' | '${HOME}') _p=$HOME ;;
        '$HOME/'*) _p="$HOME/${1#'$HOME/'}" ;;
        '${HOME}/'*) _p="$HOME/${1#'${HOME}/'}" ;;
        /*) _p=$1 ;;
        *) _p="${2:-$ROOT}/$1" ;;
    esac
    normpath "$_p"
}

# allowed ABS: true if ABS is inside the repo root or a scratch location.
allowed() {
    case $1 in
        "$ROOT" | "$ROOT"/* | "$ROOT_P" | "$ROOT_P"/*) return 0 ;;
        /dev/null | /dev/stdout | /dev/stderr | /dev/tty | /dev/fd/*) return 0 ;;
        /tmp | /tmp/* | /private/tmp | /private/tmp/* | /var/folders/* | /private/var/folders/*) return 0 ;;
    esac
    if [ -n "${TMPDIR:-}" ]; then
        case $1 in "${TMPDIR%/}" | "${TMPDIR%/}"/*) return 0 ;; esac
    fi
    return 1
}

# Read-only roots (.claude/hooks/read-only-roots.txt, generated from .agents/factory.toml):
# directories where only read-only commands may run. RO_ROOTS holds one case-insensitive
# glob per line (APFS, the macOS default, is case-insensitive: ~/Ref is ~/ref), built
# once here so a match costs no fork. gen.jl rejects roots containing glob characters.
RO_ROOTS=""
if [ -f "$HOOKS_DIR/read-only-roots.txt" ]; then
    _abs=""
    while IFS= read -r _r || [ -n "$_r" ]; do
        case $_r in '' | '#'*) continue ;; esac
        _abs="$_abs$(abspath "$_r" /)
"
    done <"$HOOKS_DIR/read-only-roots.txt"
    if [ -n "$_abs" ]; then
        RO_ROOTS=$(printf '%s' "$_abs" | awk '{ o = ""; for (i = 1; i <= length($0); i++) { c = substr($0, i, 1)
            l = tolower(c); u = toupper(c); o = o (l != u ? "[" l u "]" : c) } print o }')
    fi
fi

# in_read_only ABS: true if ABS is inside a read-only root; sets RO_HIT to that root's glob.
# shellcheck disable=SC2034 # RO_HIT is read by bash_guard.sh
in_read_only() {
    [ -n "$RO_ROOTS" ] || return 1
    _oifs=$IFS
    IFS='
'
    for _r in $RO_ROOTS; do
        # shellcheck disable=SC2254 # the pattern IS a glob
        case $1 in $_r | $_r/*) IFS=$_oifs; RO_HIT=$(printf '%s' "$_r" | sed -E 's/\[(.)(.)\]/\1/g'); return 0 ;; esac
    done
    IFS=$_oifs
    return 1
}
