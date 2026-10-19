#!/usr/bin/env julia
# lane.jl: worktree lanes, per repo, at <repo>/.worktrees/<lane>. Wrapper: scripts/lane.
#
#   scripts/lane new <name> [--repo DIR] [--base BRANCH] [--prefix feat|fix|chore|docs|test]
#   scripts/lane list [--repo DIR]
#   scripts/lane remove <name> [--repo DIR] [--allow-ignored]
#
# new     refuses past the cap ([lanes] max_open in the repo's .agents/agent-registry.toml,
#         default 4) and when .worktrees/ is not gitignored; branch <prefix>/<name> from base;
#         records the base in git config branch.<branch>.lane-base.
# list    name, branch, base, ahead/behind, clean/dirty. Read-only.
# remove  refuses a dirty lane, one whose branch is not merged into its base, and one holding
#         ignored files (reports, Manifest.toml, scratch) unless --allow-ignored. Never forces.
#         Keeps the branch (delete it yourself once you are sure).
module Lane

using TOML
include(joinpath(@__DIR__, "_common.jl"))

const NAME = r"^[a-z0-9][a-z0-9-]{0,39}$"
const PREFIXES = ("feat", "fix", "chore", "docs", "test")

repo_root(dir) = something(git(dir, "rev-parse", "--show-toplevel"), "")
lanes_dir(repo) = joinpath(repo, ".worktrees")

function max_open(repo)
    p = joinpath(repo, ".agents", "agent-registry.toml")
    isfile(p) || return 4
    return get(get(TOML.parsefile(p), "lanes", Dict()), "max_open", 4)
end

function lanes(repo)
    d = lanes_dir(repo)
    isdir(d) || return String[]
    return sort!(filter(n -> isfile(joinpath(d, n, ".git")), readdir(d)))
end

function info(repo, name)
    wt = joinpath(lanes_dir(repo), name)
    br = something(git(wt, "branch", "--show-current"), "?")
    base = something(git(repo, "config", "branch.$br.lane-base"), "main")
    counts = git(wt, "rev-list", "--left-right", "--count", "$base...HEAD")
    behind, ahead = counts === nothing ? ("?", "?") : split(counts)
    dirty = !isempty(something(git(wt, "status", "--porcelain"), "x"))
    return (; name, branch = br, base, ahead, behind, dirty)
end

function cmd_new(repo, name, opts; io = stdout)
    occursin(NAME, name) || return (println(stderr, "lane: name must match $(NAME.pattern)"); 2)
    prefix = get(opts, "--prefix", "feat")
    prefix in PREFIXES || return (println(stderr, "lane: --prefix must be one of $(PREFIXES)"); 2)
    base = get(opts, "--base", something(git(repo, "branch", "--show-current"), "main"))
    cap = max_open(repo)
    n = length(lanes(repo))
    n >= cap && return (println(stderr, "lane: $n lanes open in $repo (cap $cap). Merge and remove one first."); 1)
    git(repo, "check-ignore", "-q", ".worktrees/$name") === nothing &&
        return (println(stderr, "lane: .worktrees/ is not gitignored in $repo; add `/.worktrees/` to .gitignore first."); 1)
    branch = "$prefix/$name"
    wt = joinpath(lanes_dir(repo), name)
    ispath(wt) && return (println(stderr, "lane: $wt already exists"); 1)
    git(repo, "worktree", "add", "-b", branch, wt, base) === nothing &&
        return (println(stderr, "lane: git worktree add failed (does branch $branch exist?)"); 1)
    git(repo, "config", "branch.$branch.lane-base", base)
    println(io, "lane: created $wt on $branch (base $base); $(n + 1)/$cap lanes open")
    return 0
end

function cmd_list(repo; io = stdout)
    ls = lanes(repo)
    println(io, "lanes in $repo: $(length(ls))/$(max_open(repo))")
    for n in ls
        l = info(repo, n)
        println(io, "  ", rpad(l.name, 24), rpad(l.branch, 30), "base ", rpad(l.base, 12),
                "+", l.ahead, "/-", l.behind, l.dirty ? "  DIRTY" : "  clean")
    end
    return 0
end

function cmd_remove(repo, name; io = stdout, allow_ignored = false)
    name in lanes(repo) || return (println(stderr, "lane: no lane `$name` in $repo"); 1)
    l = info(repo, name)
    l.dirty && return (println(stderr, "lane: `$name` has uncommitted changes; commit or discard them first."); 1)
    git(repo, "merge-base", "--is-ancestor", l.branch, l.base) === nothing &&
        return (println(stderr, "lane: $(l.branch) is not merged into $(l.base); merge it (after review) first."); 1)
    wt = joinpath(lanes_dir(repo), name)
    ignored = filter(!isempty, split(something(git(wt, "status", "--porcelain", "--ignored"), ""), '\n'))
    if !isempty(ignored) && !allow_ignored
        println(stderr, "lane: `$name` holds ignored files that removal would delete:")
        foreach(l -> println(stderr, "    ", l), first(ignored, 20))
        println(stderr, "lane: copy what you need (e.g. reports) out, then re-run with --allow-ignored.")
        return 1
    end
    git(repo, "worktree", "remove", wt) === nothing &&
        return (println(stderr, "lane: git worktree remove failed"); 1)
    println(io, "lane: removed .worktrees/$name (branch $(l.branch) kept)")
    return 0
end

function main(args)
    usage = "usage: scripts/lane new <name> [--repo DIR] [--base B] [--prefix P] | list [--repo DIR] | remove <name> [--repo DIR] [--allow-ignored]"
    opts, pos = try
        parse_args(args, ("--allow-ignored",), ("--repo", "--base", "--prefix"))
    catch e
        println(stderr, "lane: ", e isa ErrorException ? e.msg : e)
        return 2
    end
    isempty(pos) && (println(stderr, usage); return 2)
    repo = repo_root(abspath(get(opts, "--repo", pwd())))
    isempty(repo) && (println(stderr, "lane: not inside a git repository"); return 2)
    # A lane's own checkout resolves to the lane; manage lanes from the main checkout.
    common = git(repo, "rev-parse", "--path-format=absolute", "--git-common-dir")
    common === nothing || (repo = dirname(common))
    sub = pos[1]
    sub == "list" && length(pos) == 1 && return cmd_list(repo)
    sub == "new" && length(pos) == 2 && return cmd_new(repo, pos[2], opts)
    sub == "remove" && length(pos) == 2 && return cmd_remove(repo, pos[2]; allow_ignored = get(opts, "--allow-ignored", false))
    println(stderr, usage)
    return 2
end

end # module

abspath(PROGRAM_FILE) == @__FILE__() && exit(Lane.main(ARGS))
