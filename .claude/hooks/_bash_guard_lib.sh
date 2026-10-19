# shellcheck shell=sh
# shellcheck disable=SC2034,SC2154 # RO_GIT is read, and `cwd` is set, by bash_guard.sh
# _bash_guard_lib.sh: command splitting and path helpers only bash_guard.sh needs (split out in
# factory 0.2.2: ratchets.toml caps hooks at 150 lines). Sourced after _lib.sh; costs no fork.

# segments (stdin -> stdout): one simple command per line, in one awk (no sed/tr forks). Its
# output feeds the denylist AND the per-command checks (factory 0.2.3).
# - Text inside '...', "..." and $'...' (and a backslashed character) is ONE argument: its blanks
#   and ; & | ( ) < > become _, and quote characters and backslashes are dropped, so 'rm', "rm",
#   \rm and r\m all read rm, while a quoted message is never a command or a redirect.
# - A "$(...)" or `...` inside double quotes still runs, so it is split like unquoted text; an
#   unquoted `...` splits too. A `#` that starts a word ends the line (its apostrophes are not quotes).
# - Backslash-newline joins lines. A heredoc (<<WORD or <<-WORD, unquoted, not <<< and not inside
#   $((...)) or ((...))) drops its body; a body never terminated is checked as commands after all.
# - Then 2>&1-style duplications go, &>, >& and >| become >, and ; & | ( ) split.
segments() {
    awk -v SQ="'" 'BEGIN { sp = " \t;&|()<>" }
    function out() { gsub(/[0-9]*>&([0-9]+|-)/, "", b); gsub(/&>|>&|>\|/, ">", b); gsub(/[;&|()]/, "\n", b); print b; b = "" }
    function scan(s,   i, n, c, d, w) { n = length(s)
      for (i = 1; i <= n; i++) { c = substr(s, i, 1); d = substr(s, i + 1, 1)
        if (q == "") { # unquoted: top level, or inside a "$(...)" / "`...`" (t[k] = depth or `)
          if (c == "(") { if (ar || d == "(") ar++ } else if (c == ")" && ar) ar-- # ar: arithmetic depth
          if (c == "\\") { if (i == n) return; b = b (index(sp "\"#`$" SQ, d) ? "_" : d); i++ }
          else if (c == "#" && (i == 1 || index(" \t;&|(", substr(s, i - 1, 1)))) i = n
          else if (c == "<" && d == "<" && !ar) {
            if (substr(s, i + 2, 1) == "<") { b = b "<<<"; i += 2; continue }
            i += 2; dash = substr(s, i, 1) == "-"; if (dash) i++
            while (i <= n && index(" \t", substr(s, i, 1))) i++
            for (w = ""; i <= n && !index(sp, substr(s, i, 1)); i++) if (!index("\"\\" SQ, substr(s, i, 1))) w = w substr(s, i, 1)
            if (w != "") hd = w; b = b " "; i-- }
          else if (c == "$" && d == SQ) { q = "A"; i++ } # $'...' and $"..." are quotes (0.2.4: the $ is dropped)
          else if (c == "$" && d == "\"") { }
          else if (c == "\"" || c == SQ) q = c
          else if (k && t[k] == "`" && c == "`") { k--; q = "\""; b = b ";" }
          else if (c == "`") { bt = !bt; b = b (bt ? "$;" : ";") } # $: an expansion
          else if (k && t[k] != "`" && (c == "(" || c == ")")) {
            t[k] += (c == "(" ? 1 : -1); b = b c; if (t[k] == 0) { k--; q = "\"" } }
          else b = b c }
        else if (c == "\\" && q != SQ) { b = b "__"; i++ }
        else if ((c == SQ && q != "\"") || (c == "\"" && q == "\"")) q = ""
        else if (q == "\"" && (c == "`" || (c == "$" && d == "("))) {
          q = ""; k++; if (c == "`") { t[k] = "`"; b = b ";" } else { t[k] = 1; b = b "$("; i++; if (substr(s, i + 1, 1) == "(") ar = 1 } }
        else b = b (index(sp, c) ? "_" : c) }
      if (q != "") b = b "_"; else { if (k) b = b ";"; else out(); if (hd != "") { body = hd; hd = "" } } }
    body != "" { l = $0; if (dash) sub(/^\t+/, "", l); if (l == body) { body = ""; nb = 0 } else hb[++nb] = $0; next }
    { scan($0) }
    END { if (body != "") { body = ""; for (j = 1; j <= nb; j++) scan(hb[j]) } if (b != "") out() }'
}

# outside() is in _bash_guard_write.sh (0.2.4).

# optw " -o --output " WORD...: outside() the argument of each listed option (-o F, -oF, --output=F).
optw() {
    _o=$1 _p=""
    shift
    for _v in "$@"; do
        if [ -n "$_p" ]; then _p=""; outside "$_v"; continue; fi
        case $_o in *" $_v "*) _p=1; continue ;; esac
        case $_v in
            --*=*) case $_o in *" ${_v%%=*} "*) outside "${_v#*=}" ;; esac ;;
            -[!-]?*) case $_o in *" ${_v%"${_v#-?}"} "*) outside "${_v#-?}" ;; esac ;;
        esac
    done
}

# scratch ABS: true if ABS is strictly below $TMPDIR, or at least three levels below this
# user's Claude Code scratch root /private/tmp/claude-<uid>/<project>/<session>/..., where
# `rm -rf` is allowed; never the repo root, never a glob in <project> or <session>.
scratch() {
    case $1 in "$ROOT" | "$ROOT"/* | "$ROOT_P" | "$ROOT_P"/*) return 1 ;; esac
    case $1 in
        /private/tmp/claude-*/*/*/?* | /tmp/claude-*/*/*/?*)
            _s=${1#/*tmp/claude-}
            case $_s in "$(id -u)"/*) ;; *) return 1 ;; esac
            _s=${_s#*/}
            _p=${_s%%/*} && _s=${_s#*/}
            case "$_p/${_s%%/*}" in *[*?[]*) return 1 ;; esac
            return 0
            ;;
    esac
    _td=${TMPDIR%/}
    [ -n "$_td" ] || return 1
    case $1 in "$_td"/?* | /private"$_td"/?*) return 0 ;; esac
    return 1
}

# rm_check ARGS...: `rm -rf` only on ABSOLUTE, LITERAL scratch targets (factory 0.2.3: no
# $TMPDIR form; the hook cannot know the command shell's TMPDIR: unset, read, printf -v, for,
# eval, source and the user's profile all change it). Never a relative target (the tracked cwd
# can be wrong), an expansion, a brace list, or a path ending in / or /. (a symlink's target).
rm_check() {
    _r="" _f="" _n=0 _ok=1
    for _t in "$@"; do
        case $_t in
            --recursive) _r=1 ;; --force) _f=1 ;; --*) ;;
            -*) case $_t in *[rR]*) _r=1 ;; esac; case $_t in *f*) _f=1 ;; esac ;;
            *)
                _n=$((_n + 1))
                case $_t in *'$'* | *'`'* | *'{'* | */ | */. | */..) _ok="" ;; /*) scratch "$(abspath "$_t")" || _ok="" ;; *) _ok="" ;; esac
                ;;
        esac
    done
    if [ -n "$_r" ] && [ -n "$_f" ] && { [ "$_n" -eq 0 ] || [ -z "$_ok" ]; }; then
        deny "rm -rf is blocked except on literal absolute paths below \$TMPDIR or your session scratchpad (/private/tmp/claude-<uid>/<project>/<session>/), not \$TMPDIR/... or a relative path. Remove named paths with \`rm -r <path>\`, or ask the lead."
    fi
    for _t in "$@"; do outside "$_t"; done
}

RO_GIT=' status log show diff rev-parse ls-files ls-tree grep blame describe cat-file merge-base for-each-ref shortlog reflog '

# git_dir ARGS...: the -C DIRs (cumulative, as git applies them), or the last --git-dir/--work-tree
# DIR (or =DIR), among git's global options (empty if none): the repository git acts on.
git_dir() {
    _gd=""
    while [ $# -gt 0 ]; do
        case $1 in
            -C) case ${2:-} in /* | '~'*) _gd=${2:-} ;; *) _gd=${_gd:+$_gd/}${2:-} ;; esac; shift $(($# > 1 ? 2 : 1)) ;; # cumulative
            --git-dir | --work-tree) _gd=${2:-}; shift $(($# > 1 ? 2 : 1)) ;;
            --git-dir=* | --work-tree=*) _gd=${1#*=}; shift ;;
            -c | --namespace) shift $(($# > 1 ? 2 : 1)) ;; -*) shift ;; *) break ;;
        esac
    done
    printf '%s' "$_gd"
}
# git_sub ARGS...: git's subcommand after its global options (-C dir, -c k=v, --no-pager, ...).
git_sub() {
    while [ $# -gt 0 ]; do
        case $1 in -C | -c | --git-dir | --work-tree | --namespace) shift $(($# > 1 ? 2 : 1)) ;; -*) shift ;; *) break ;; esac
    done
    printf '%s' "${1:-}"
}
# newdir TARGET: the directory `cd TARGET` moves to, or empty if it cannot be known statically.
newdir() {
    case $1 in
        '' | -) return 0 ;;
        '$HOME' | '${HOME}' | '$HOME/'* | '${HOME}/'*) ;;
        *'$'* | *'`'*) return 0 ;;
    esac
    abspath "$1" "$cwd"
}
