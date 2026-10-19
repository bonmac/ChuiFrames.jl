#!/usr/bin/env julia
# lane.jl: worktree lanes, per repo, at <repo>/.worktrees/<lane>. Wrapper: scripts/lane.
#
#   scripts/lane new <name> [--repo DIR] [--base BRANCH] [--prefix feat|fix|chore|docs|test] [--owns GLOBS]
#   scripts/lane list [--repo DIR]
#   scripts/lane audit <name> [--repo DIR] [--owns GLOBS] [--reported FILE]
#   scripts/lane remove <name> [--repo DIR] [--allow-ignored]
#
# new     refuses past the cap ([lanes] max_open in the repo's .agents/agent-registry.toml,
#         default 4) and when .worktrees/ is not gitignored; branch <prefix>/<name> from base;
#         records the base in git config branch.<branch>.lane-base and the owned file globs
#         (--owns, comma or space separated, risk.toml glob rule; `changelog.d/<name>.md` is
#         always added) in branch.<branch>.lane-owns, and appends a `lane-new` line to the ledger.
#         Warns when JULIA_PROJECT, JULIA_LOAD_PATH or JULIA_DEPOT_PATH leak in from the parent.
# audit   (0.2.4) fails when the lane's changes since the merge base with its base (commits,
#         uncommitted and untracked files) touch a path outside its owned globs, when no globs
#         are recorded, or, with --reported FILE (one path per line, as the lane reported its
#         changed files), when the two lists differ. /change-review runs it before a lane lands.
# list    name, branch, base, ahead/behind, clean/dirty. Read-only.
# remove  refuses a dirty lane, one whose branch is not merged into its base, and one holding
#         ignored files (reports, Manifest.toml, scratch) unless --allow-ignored. Never forces.
#         Keeps the branch (delete it yourself once you are sure).
module Lane

    using TOML, Dates
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

    "Owned globs from a --owns value: comma or whitespace separated."
    split_globs(s) = String.(filter!(!isempty, split(s, r"[,\s]+")))

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
        owns = unique!([split_globs(get(opts, "--owns", "")); "changelog.d/$name.md"])
        git(repo, "config", "branch.$branch.lane-owns", join(owns, ' '))
        ledger_line(repo, "lane-new"; lane = name, branch, base, owns)
        println(io, "lane: created $wt on $branch (base $base); $(n + 1)/$cap lanes open; owns: ", join(owns, ' '))
        haskey(opts, "--owns") || println(io, "lane: no --owns given: `scripts/lane audit $name` will fail until the owned globs are recorded")
        foreach(w -> println(io, "lane: warning: ", w), env_warnings())
        return 0
    end

    "Append one JSON line to the repo's lane ledger (.lanes/ledger.jsonl); never fails the command."
    function ledger_line(repo, ev; kw...)
        esc(x) = "\"" * replace(string(x), "\\" => "\\\\", "\"" => "\\\"") * "\""
        val(v) = v isa AbstractVector ? "[" * join(esc.(v), ",") * "]" : esc(v)
        fields = ["\"ts\":" * esc(Dates_now()), "\"ev\":" * esc(ev), ("\"$k\":" * val(v) for (k, v) in kw)...]
        return try
            mkpath(joinpath(repo, ".lanes"))
            open(io -> println(io, "{", join(fields, ","), "}"), joinpath(repo, ".lanes", "ledger.jsonl"), "a")
        catch
        end
    end
    Dates_now() = Dates.format(Dates.now(Dates.UTC), "yyyy-mm-ddTHH:MM:SS") * "Z"

    """
        audit(changed, owns, reported) -> problems

    Pure core of `lane audit`: every changed path must match an owned glob, and, when the lane
    reported its changed files (`reported !== nothing`), the two lists must be equal.
    """
    function audit(changed, owns, reported = nothing)
        bad = String[]
        isempty(owns) && push!(bad, "no owned globs recorded (create the lane with --owns, or pass --owns to audit)")
        for f in changed
            isempty(owns) || any(g -> globmatch(g, f), owns) || push!(bad, "outside owns: $f")
        end
        if reported !== nothing
            foreach(f -> push!(bad, "changed but not reported: $f"), sort!(setdiff(changed, reported)))
            foreach(f -> push!(bad, "reported but not changed: $f"), sort!(setdiff(reported, changed)))
        end
        return bad
    end

    "Paths in a reported-files list: one per line; blank lines and # comments skipped; `- ` and backticks stripped."
    read_reported(path) = sort!(
        unique!(
            [
                strip(replace(l, r"^\s*[-*]\s+" => "", "`" => "")) for l in eachline(path)
                    if !isempty(strip(l)) && !startswith(strip(l), "#")
            ]
        )
    )

    function cmd_audit(repo, name, opts; io = stdout)
        name in lanes(repo) || return (println(stderr, "lane: no lane `$name` in $repo"); 2)
        l = info(repo, name)
        wt = joinpath(lanes_dir(repo), name)
        owns = haskey(opts, "--owns") ? split_globs(opts["--owns"]) :
            split_globs(something(git(repo, "config", "branch.$(l.branch).lane-owns"), ""))
        # the review: a lane-base rewritten to the lane's own branch (or to a missing ref) audits nothing
        l.base == l.branch && return (println(io, "lane audit $name: [FAIL] its base is its own branch ($(l.base)): branch.$(l.branch).lane-base was rewritten\nlane audit: FAILED (1)"); 1)
        git(wt, "rev-parse", "--verify", "--quiet", "$(l.base)^{commit}") === nothing &&
            return (println(io, "lane audit $name: [FAIL] its base `$(l.base)` is not a commit here\nlane audit: FAILED (1)"); 1)
        mb = merge_base(wt, l.base)
        mb === nothing && return (println(stderr, "lane: no merge base between $(l.base) and $(l.branch)"); 2)
        lines(x) = String.(filter!(!isempty, split(something(x, ""), '\n')))
        # the commits (merge base..HEAD), the index and the working tree, each on its own (a change committed
        # and then reverted in the working tree is still on the branch), plus untracked files; renames count
        # at both paths; quotePath=false keeps non-ASCII names as they are
        g(args...) = lines(git(wt, "-c", "core.quotePath=false", args...))
        changed = sort!(
            unique!(
                [
                    g("diff", "--name-only", "--no-renames", mb, "HEAD"); g("diff", "--name-only", "--no-renames", "--cached", mb);
                    g("diff", "--name-only", "--no-renames"); g("ls-files", "--others", "--exclude-standard")
                ]
            )
        )
        reported = haskey(opts, "--reported") ? read_reported(opts["--reported"]) : nothing
        bad = audit(changed, owns, reported)
        println(
            io, "lane audit $name: $(l.branch) vs $(l.base) (merge base $(first(mb, 10))), $(length(changed)) changed; owns: ",
            isempty(owns) ? "(none)" : join(owns, ' ')
        )
        foreach(f -> println(io, "    ", f), changed)
        foreach(b -> println(io, "  [FAIL] ", b), bad)
        reported === nothing && println(io, "  [info] no --reported list: the lane's own changed-file list was not compared")
        println(io, isempty(bad) ? "lane audit: OK" : "lane audit: FAILED ($(length(bad)))")
        return isempty(bad) ? 0 : 1
    end

    function cmd_list(repo; io = stdout)
        ls = lanes(repo)
        println(io, "lanes in $repo: $(length(ls))/$(max_open(repo))")
        for n in ls
            l = info(repo, n)
            println(
                io, "  ", rpad(l.name, 24), rpad(l.branch, 30), "base ", rpad(l.base, 12),
                "+", l.ahead, "/-", l.behind, l.dirty ? "  DIRTY" : "  clean"
            )
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
        usage = "usage: scripts/lane new <name> [--repo DIR] [--base B] [--prefix P] [--owns GLOBS] | list [--repo DIR] | audit <name> [--repo DIR] [--owns GLOBS] [--reported FILE] | remove <name> [--repo DIR] [--allow-ignored]"
        opts, pos = try
            parse_args(args, ("--allow-ignored",), ("--repo", "--base", "--prefix", "--owns", "--reported"))
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
        sub == "audit" && length(pos) == 2 && return cmd_audit(repo, pos[2], opts)
        sub == "remove" && length(pos) == 2 && return cmd_remove(repo, pos[2]; allow_ignored = get(opts, "--allow-ignored", false))
        println(stderr, usage)
        return 2
    end

end # module

abspath(PROGRAM_FILE) == @__FILE__() && exit(Lane.main(ARGS))
