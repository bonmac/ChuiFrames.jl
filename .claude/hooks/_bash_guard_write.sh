# shellcheck shell=sh
# shellcheck disable=SC2034,SC2154 # cwd and T3_DIR are shared with bash_guard.sh and _bash_guard_cmd.sh
# _bash_guard_write.sh: write targets (factory 0.2.4; ratchets.toml caps hooks at 150 lines):
# outside(), T3 protected paths (also used by write_guard.sh), in-place editors and git's path
# writers. Sourced after _lib.sh (and, for bash_guard, _bash_guard_lib.sh); no fork on the common path.

# T3 protected paths (risk.toml -> protected-paths.txt): every write target bash_guard models goes
# through outside() -> t3_check (the list is in .agents/checks.toml). Denied unless the SESSION env
# has FACTORY_ALLOW_T3=1. T3_DIR=1 (set per command by check_cmd) also denies a DIRECTORY target
# that holds a T3 path (`rm -r scripts`, `mv .claude x`, `find . -delete`, `tar -x -C .`).
T3_FROM="" T3_LIST="" T3_DIR=""

outside() { # outside TOKEN: deny if TOKEN names a path outside the root and scratch dirs, or a T3 path
    case $1 in
        '' | -* | '&'*) return 0 ;;
        '~-' | '~-/'*) deny "a write target starting with ~- (the previous directory) is not resolved by the guard: $1. Name the path." ;;
        '$TMPDIR' | '$TMPDIR'/*) _t="${TMPDIR%/}${1#'$TMPDIR'}" ;; # never a relative path; unset -> /
        '${TMPDIR}' | '${TMPDIR}'/*) _t="${TMPDIR%/}${1#'${TMPDIR}'}" ;;
        *) _t=$1 ;;
    esac
    _a=$(abspath "${_t:-/}" "$cwd")
    allowed "$_a" || deny "write outside the repo root blocked: $_a (root: $ROOT). Lanes write only inside their repo; use the scratchpad or \$TMPDIR for temp files."
    t3_check "$_a"
}

# t3_globs FILE: the T3 globs of protected-paths.txt FILE, lowercased, one per line (cached).
t3_globs() {
    [ "$T3_FROM" != "$1" ] || return 0
    T3_FROM=$1 T3_LIST=""
    while read -r _t _g; do
        [ "$_t" = T3 ] || continue
        case $_g in *[[:upper:]]*) _g=$(printf '%s' "$_g" | tr '[:upper:]' '[:lower:]') ;; esac
        T3_LIST="$T3_LIST$_g
"
    done <"$1"
}
# t3_list DIR: DIR's own protected-paths.txt, else the hooks' one; fails closed when neither exists.
t3_list() {
    _l="$1/.claude/hooks/protected-paths.txt"
    [ -f "$_l" ] || _l="$HOOKS_DIR/protected-paths.txt"
    [ -f "$_l" ] || deny "$HOOKS_DIR/protected-paths.txt is missing, so the guard cannot tell whether a write is to a T3 path; it fails closed for writes inside the repo. Run \`julia scripts/gen.jl\`."
    t3_globs "$_l"
}
# is_checkout DIR: DIR holds a real git checkout (.git/HEAD, or a .git file `gitdir: ...`), not a bare `.git` marker.
is_checkout() {
    [ -f "$1/.git/HEAD" ] && return 0
    [ -f "$1/.git" ] || return 1
    read -r _gl <"$1/.git" 2>/dev/null || return 1
    case $_gl in gitdir:*) return 0 ;; esac
    return 1
}

# t3_check ABS: deny when ABS (inside the repo root) is a T3 path of the nearest enclosing git
# checkout (a worktree lane, a nested package repo; its own list) OR of the repo root (its list).
# Paths compare lowercased (APFS is case-insensitive). A target with glob characters is expanded
# here (the shell would expand it); a brace list and anything below a `.git` directory are denied.
t3_check() {
    [ "${FACTORY_ALLOW_T3:-}" != 1 ] || return 0
    case $1 in "$ROOT" | "$ROOT"/*) _rt=$ROOT ;; "$ROOT_P" | "$ROOT_P"/*) _rt=$ROOT_P ;; *) return 0 ;; esac
    case $1 in *'{'*','*'}'*) deny "a brace list in a write target inside the repo is not checked: $1. Spell the paths out." ;; esac
    case $1 in *[*?[]*)
        set +f
        for _gx in $1; do
            set -f
            [ "$_gx" = "$1" ] || t3_check "$_gx"
        done
        set -f
        ;;
    esac
    case "/${1#"$_rt"}/" in */.git/*) deny "writes below a .git directory (or creating one) are blocked: $1. Use git itself, or ask the user." ;; esac
    _repo=$_rt
    if [ "$1" != "$_rt" ]; then
        _d=${1%/*}
        while [ "$_d" != "$_rt" ] && [ -n "$_d" ]; do
            if is_checkout "$_d"; then _repo=$_d; break; fi
            _d=${_d%/*}
        done
    fi
    if [ -n "$T3_DIR" ] && [ "$_repo" != "$1" ] && is_checkout "$1"; then
        deny "$1 is a git checkout with its own T3 paths; this command would change it as a whole. Work inside it, or ask the user."
    fi
    t3_list "$_repo"
    t3_match "${1#"$_repo"}"
    [ "$_repo" = "$_rt" ] && return 0
    t3_list "$_rt"
    t3_match "${1#"$_rt"}"
}
# t3_match /REL: deny when REL ("" = the checkout root) matches a glob of T3_LIST (or, with T3_DIR, holds one).
t3_match() {
    _rel=${1#/} _rl=${1#/}
    case $_rl in *[[:upper:]]*) _rl=$(printf '%s' "$_rl" | tr '[:upper:]' '[:lower:]') ;; esac
    _hit="" _t3ifs=$IFS
    IFS='
'
    for _g in $T3_LIST; do
        _how="is a T3 protected path"
        # shellcheck disable=SC2254 # the pattern IS a glob
        case $_rl in $_g) _hit=$_g; break ;; esac
        [ -n "$T3_DIR" ] || continue
        _how="holds T3 protected paths"
        _lit=${_g%%[*?[]*} # the glob's literal prefix
        [ -n "$_rl" ] || { _hit=$_g; break; } # the checkout root holds every T3 path
        case $_lit in "$_rl"/*) _hit=$_g; break ;; esac
        [ "$_lit" = "$_g" ] || case "$_rl/" in "$_lit"*) _hit=$_g; break ;; esac
    done
    IFS=$_t3ifs
    [ -z "$_hit" ] || deny "${_rel:-the repo root} $_how (\`$_hit\` in risk.toml). T3 needs an ADR and the user's approval; the user sets FACTORY_ALLOW_T3=1 for the session.${T3_HINT:-}"
}

# inplace NAME ARGS...: sed -i/-i.bak/--in-place and perl -i/-pi write every file argument.
inplace() {
    _n=$1 _i=""
    shift
    for tok in "$@"; do case $_n:$tok in sed:-i* | sed:--in-place* | perl:-i* | perl:-[pnla0]*i*) _i=1 ;; esac; done
    [ -n "$_i" ] || return 0
    _p="" _s=""
    for tok in "$@"; do
        if [ -n "$_p" ]; then _p=""; continue; fi
        case $_n:$tok in
            *:-e | *:-f | sed:--expression | sed:--file | perl:-E) _p=1; _s=1 ;;
            *:-e?* | *:-f?* | sed:--expression=* | sed:--file=*) _s=1 ;;
            *:-*) ;;
            *) if [ -n "$_s" ]; then outside "$tok"; else _s=1; fi ;; # the first is the script
        esac
    done
}

# git_writes ARGS...: the paths `git rm`, `git mv`, `git restore` and `git checkout ... -- PATHS` (or
# an operand naming an existing path) write, relative to the cwd after every -C (cumulative).
git_writes() {
    case " $* " in *" rm "* | *" mv "* | *" restore "* | *" checkout "*) ;; *) return 0 ;; esac
    _s=$(git_sub "$@")
    case $_s in rm | mv | restore | checkout) ;; *) return 0 ;; esac
    case "$_s $* " in "rm "*" --cached "*) return 0 ;; "restore "*" --staged "* | "restore "*" -S "*) # the index only
        case " $* " in *" --worktree "* | *" -W "*) ;; *) return 0 ;; esac ;; esac
    _oc=$cwd _seen="" _dd="" _p="" T3_DIR=1
    for tok in "$@"; do
        if [ -n "$_p" ]; then [ "$_p" != C ] || cwd=$(abspath "$tok" "$cwd"); _p=""; continue; fi
        if [ -z "$_seen" ]; then case $tok in -C) _p=C ;; -c | --git-dir | --work-tree | --namespace) _p=1 ;; "$_s") _seen=1 ;; esac; continue; fi
        case $tok in
            --) _dd=1; continue ;;
            -s | --source | -b | -B | --orphan | --pathspec-from-file) _p=1; continue ;;
            -*) continue ;;
        esac
        if [ "$_s" != checkout ] || [ -n "$_dd" ] || [ -e "$(abspath "$tok" "$cwd")" ]; then outside "$tok"; fi
    done
    cwd=$_oc
}
