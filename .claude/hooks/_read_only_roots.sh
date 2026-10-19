# shellcheck shell=sh
# shellcheck disable=SC2034,SC2154 # RO_HIT is read by read_only_check; git_sub is in _bash_guard_lib.sh
# _read_only_roots.sh: the read-only roots of .agents/factory.toml [bash_guard], for bash_guard.sh
# only (split out in factory 0.2.2: ratchets.toml caps hooks at 150 lines). Sourced after _lib.sh;
# costs no fork, and the other hooks no longer parse the roots on every call.

# Read-only roots (.claude/hooks/read-only-roots.txt, generated from .agents/factory.toml):
# only read-only commands may run there. RO_ROOTS: one case-insensitive glob per line (APFS
# is case-insensitive), built once so a match costs no fork. gen.jl rejects glob characters.
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
# The roots file is gitignored (0.2.3: it may name private paths, from .agents/factory.local.toml).
# READ_ONLY_ROOTS_REQUIRED=1 (limits.env, from require_read_only_roots) with no roots means it was
# never generated on this machine: bash_guard fails closed (RO_MISSING) except for gen.jl itself.
RO_MISSING=""
[ "${READ_ONLY_ROOTS_REQUIRED:-0}" != 1 ] || [ -n "$RO_ROOTS" ] || RO_MISSING=1

# in_read_only ABS: true if ABS is inside a read-only root; sets RO_HIT to that root's glob.
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

# Inside a read-only root: the only commands allowed to run, and git's only subcommands.
RO_CMDS=' cat head tail less grep rg find ls wc stat file cd pushd popd pwd '
RO_ROOT_GIT=' log show diff status blame ls-files '

# read_only_check NAME DIR ARGS...: deny NAME unless it is read-only, when DIR is in a read-only root.
read_only_check() {
    _n=$1 _dir=$2
    shift 2
    in_read_only "$_dir" || return 0
    _why="$RO_HIT is a read-only reference root (.agents/factory.toml [bash_guard] read_only_roots): only read-only commands may run there (cat, head, tail, less, grep, rg, find, ls, wc, stat, file, and git log/show/diff/status/blame/ls-files). Read its files with absolute paths from the repo root instead"
    case $RO_CMDS in *" $_n "*) ;; *) [ "$_n" = git ] || deny "\`$_n\` would run in $_dir. $_why." ;; esac
    case $_n in
        git)
            _s=$(git_sub "$@")
            case $RO_ROOT_GIT in *" $_s "*) ;; *) deny "\`git $_s\` would run in $_dir. $_why." ;; esac
            ;;
        find)
            for _t in "$@"; do
                case $_t in -exec | -execdir | -ok | -okdir | -delete | -fprint* | -fls) deny "\`find $_t\` would run in $_dir. $_why." ;; esac
            done
            ;;
    esac
    return 0
}
