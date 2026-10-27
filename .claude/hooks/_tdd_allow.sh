# shellcheck shell=sh
# shellcheck disable=SC2034,SC2154 # cwd, d and tdeny come from tdd_boundary.sh
# _tdd_allow.sh (factory 0.3.0, spec §0.6): the test-writer's read and Bash allowlists and the implementer's
# Bash write check, and the checkout of a path (is_co, co_of, in_root), sourced by tdd_boundary.sh after _lib.sh
# (abspath, phys) and _bash_guard_lib.sh (git_dir). Functions only. Split from tdd_boundary.sh to keep each hook
# file under the 150-line cap.

is_co() { # DIR (physical): DIR/.git marks a checkout as a directory, or a gitdir: file whose worktree record points back (M2)
    [ -e "$1/.git" ] || return 1
    # R2-M1: only an entry named exactly .git (on a case-insensitive APFS, test/.GIT also answers to .git); the glob
    # reads the directory and matches names byte for byte, without a fork. The caller's noglob state is restored.
    case $- in *f*) _nf=1 && set +f ;; *) _nf="" ;; esac
    set -- "$1" "$1"/.gi[t]
    [ -z "$_nf" ] || set -f
    [ "$2" = "$1/.git" ] || return 1
    [ -d "$1/.git" ] && return 0
    [ -f "$1/.git" ] && read -r _g <"$1/.git" 2>/dev/null || return 1
    case $_g in "gitdir: /"*/.git/worktrees/?*) read -r _b <"${_g#gitdir: }/gitdir" 2>/dev/null || return 1 ;; *) return 1 ;; esac
    [ "$_b" = "$1/.git" ] || [ "$(CDPATH='' cd -P -- "${_b%/.git}" 2>/dev/null && pwd -P)" = "$1" ]
}
# co_of ABS: the checkout holding ABS (nearest ancestor that is_co, after phys) as CO, ABS relative to it as REL.
co_of() {
    phys "$1"
    CO=$RP
    while [ -n "$CO" ] && ! is_co "$CO"; do CO=${CO%/*}; done
    case $RP in "$CO"/*) REL=${RP#"$CO"/} ;; *) REL="" ;; esac
}
in_root() { case $CO in "$ROOT_P" | "$ROOT_P"/*) return 0 ;; esac; return 1; } # CO is at or under the session root

impl_libs() { # bash_guard's write-target model, with outside() redefined: a target under test/ is denied
    for _f in _bash_guard_cmd.sh _bash_guard_write.sh; do
        [ -f "$d/$_f" ] || tdeny missing-library §0.6 "$d/$_f is missing; the implementer's Bash check fails closed"
        # shellcheck disable=SC1090
        . "$d/$_f"
    done
    # shellcheck disable=SC2329 # both are called by check_cmd (_bash_guard_cmd.sh)
    read_only_check() { :; } # bash_guard.sh checks the read-only roots
    outside() {
        case $1 in '' | -* | '&'*) return 0 ;; *'{'* | *'}'*) tdeny impl-brace-write §0.6 "an implementer's Bash write target may not contain { or } (brace expansion can reach test/): $1" ;; esac
        co_of "$(abspath "$1" "$cwd")"
        case $REL in test | test/*) tdeny impl-test-write §0.6 "an implementer never writes test/** (here through Bash: $1); send the lead a written test-fix request" ;; esac
    }
}

TW_READ="a test-side role reads only test/, docs/, Project.toml, .lanes/evidence/red-* and green-*, its own .lanes/briefs/<lane>/<role>-* (in the coordinator also contracts/ and adr/)"
tw_read_ok() { # ABS: on a test-side role's read allowlist (its own briefs only, critic C1), in a checkout under the session root
    co_of "$1"
    in_root || return 1
    case $REL in
        test | test/* | docs | docs/* | Project.toml | .lanes/evidence/red-* | .lanes/evidence/green-* | .lanes/briefs/*/"$at"-*) return 0 ;;
        contracts | contracts/* | adr | adr/*) [ "$CO" = "$ROOT_P" ] ;;
        *) return 1 ;;
    esac
}
tw_path() { # WORD: a Bash path operand; a glob is expanded as the shell would, and each match checked
    _a=$(abspath "$1" "$cwd")
    case $_a in *[*?[]*)
        set +f
        for _x in $_a; do tw_read_ok "$_x" || tdeny tw-read-bash §0.6 "$TW_READ; not $_x"; done
        set -f
        return 0 ;;
    esac
    tw_read_ok "$_a" || tdeny tw-read-bash §0.6 "$TW_READ; not $1"
}
tw_tpath() { # WORD DIR: a git pathspec, relative to DIR, under test/ of a checkout
    case $1 in *:*) tdeny tw-git-path §0.6 "a <rev>:<path> or :magic argument reads beyond test/: $1" ;; esac
    co_of "$(abspath "$1" "$2")"
    in_root && case $REL in test | test/*) return 0 ;; esac
    tdeny tw-git-path §0.6 "a test-writer's git add/diff pathspecs are all under test/: not $1"
}
tw_git() { # ARGS (after git): status, add <test paths>, diff [--cached] -- <test paths>; commit is the guard's
    _gd=$(git_dir "$@") _rd=$cwd
    [ -z "$_gd" ] || _rd=$(abspath "$_gd" "$cwd")
    while [ $# -gt 0 ]; do
        case $1 in
            -C) shift $(($# > 1 ? 2 : 1)) ;;
            -c) case ${2:-} in user.name=* | user.email=* | commit.gpgsign=*) shift 2 ;; *) tdeny tw-git §0.6 "git -c ${2:-} is not allowed for a test-writer" ;; esac ;;
            --no-pager) shift ;;
            -*) tdeny tw-git §0.6 "git $1 is not allowed for a test-writer" ;;
            *) break ;;
        esac
    done
    _sub=${1:-}
    [ $# -eq 0 ] || shift
    case $_sub in
        commit) return 0 ;;
        status) for _w; do case $_w in --verbose | -v* | -[!-]*v*) tdeny tw-git §0.6 "git status -v prints diffs" ;; esac; done ;;
        add) for _w; do case $_w in -- | -v | --verbose | -N | --intent-to-add) ;; -*) tdeny tw-git §0.6 "git add $_w: stage named test/ paths" ;; *) tw_tpath "$_w" "$_rd" ;; esac; done ;;
        diff)
            _dd="" _n=0
            for _w; do
                if [ -n "$_dd" ]; then tw_tpath "$_w" "$_rd"; _n=$((_n + 1)); continue; fi
                case $_w in
                    --) _dd=1 ;;
                    --cached | --staged | --stat | --name-only | --name-status | --no-color | --color=* | -U* | --unified=* | --exit-code | -q | --quiet) ;;
                    *) tdeny tw-git §0.6 "a test-writer runs git diff [--cached] -- <test/ paths> only (not $_w)" ;;
                esac
            done
            [ "$_n" -gt 0 ] || tdeny tw-git §0.6 "a test-writer's git diff needs -- and test/ paths" ;;
        *) tdeny tw-git §0.6 "git $_sub is not on the test-writer's allowlist (status, add, commit, diff -- test/): git log and show carry the implementer's messages and code" ;;
    esac
}
tw_cmd() { # NAME ARGS: the test-writer's Bash allowlist, other than cd and git
    _n=${1##*/} _np=0 _pa="" _p="" _rec=""
    shift
    case $_n in
        true | false | echo | printf | pwd) return 0 ;;
        julia)
            while [ $# -gt 0 ]; do case $1 in +* | --startup-file=* | --project | --project=* | --color=* | --threads=* | -q | --quiet | --history-file=*) shift ;; *) break ;; esac; done
            co_of "$(abspath "${1:-}" "$cwd")"
            in_root && case "$REL ${2:-}" in 'scripts/tdd.jl red' | 'scripts/tdd.jl green' | 'scripts/tdd.jl api' | 'scripts/ci.jl test') return 0 ;; esac
            tdeny tw-julia §0.6 "a test-writer runs only julia scripts/tdd.jl red|green|api and julia scripts/ci.jl test (not julia -e, scripts/evidence.jl or tdd.jl mutate)" ;;
        ls | cat | head | tail | wc | grep | rg) ;;
        *) tdeny tw-bash §0.6 "\`$_n\` is not on the test-writer's Bash allowlist (cd, julia scripts/tdd.jl red|green|api, julia scripts/ci.jl test, git status|add|commit|diff -- test/, ls/cat/head/tail/wc/grep/rg on allowlisted paths)" ;;
    esac
    case $_n in grep | rg) _pa=1 ;; esac # the first operand is the pattern
    for _w; do
        if [ -n "$_p" ]; then [ "$_p" != f ] || tw_path "$_w"; _p=""; continue; fi
        case $_n:$_w in
            grep:-e | rg:-e | *:--regexp) _p=1 _pa="" ;;
            grep:-f | rg:-f | *:--file) _p=f _pa="" ;;
            grep:-[ABCmd] | rg:-[ABCmgtT] | head:-[nc] | tail:-[nc] | rg:--glob | rg:--type) _p=1 ;;
            grep:-R* | grep:-[!-]*R* | rg:-L* | rg:-[!-]*L* | *:--dereference-recursive | rg:--follow | rg:--pre* | *:--*-from* | *:--file=*)
                tdeny tw-bash §0.6 "$_n $_w can read beyond the allowlist (symlinks, commands, file lists)" ;;
            grep:-r* | grep:-[!-]*r* | grep:--recursive) _rec=1 ;;
            *:-*) ;;
            *) if [ -n "$_pa" ]; then _pa=""; else tw_path "$_w"; _np=$((_np + 1)); fi ;;
        esac
    done
    [ "$_np" -gt 0 ] || case $_n in
        ls | rg) tdeny tw-bash §0.6 "$_n needs explicit allowlisted paths" ;;
        grep) [ -z "$_rec" ] || tdeny tw-bash §0.6 "grep -r needs explicit allowlisted paths" ;;
    esac
}
