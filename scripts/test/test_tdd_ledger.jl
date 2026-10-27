# Factory 0.3.1, finding 2 (MAJOR): one TDD ledger per lane, whatever the dispatch shape (RED tests).
#
# Observed: a named teammate's `tdd-commit` records landed in the package's .lanes/ledger.jsonl, an
# unnamed subagent's in the coordinator's (the session root). Intended (spec 2026-10-26 §0.5, as
# corrected by the lead for 0.3.1): the TDD ledger of a commit is the ledger of the MAIN checkout of
# the repo that owns the commit's checkout:
#
#     <dirname of `git -C <checkout> rev-parse --path-format=absolute --git-common-dir`>/.lanes/ledger.jsonl
#
# API pinned here (the implementer follows it):
# - Shell: `owning_ledger CHECKOUT` in .claude/hooks/_lib.sh prints that path (one line, exit 0).
#   tdd_commit_post.sh still writes its records through `ledger()` (no direct append), which must
#   write the owning ledger of the record's checkout.
# - Julia: `Tdd.owning_ledger(root)` in scripts/_tdd_evidence.jl returns that path as a String.
#   `Tdd.audit(root)` with no `ledger` uses it, so `tdd.jl audit --root <lane>` prints
#   "ledger <nested main>/.lanes/ledger.jsonl" even when an outer repo has a .lanes/ledger.jsonl.
# - Parity: the shell and Julia functions return the same string for the same checkout.
#
# Helpers are copied (prefix `ol_`) from test_hooks_tdd.jl so this file also runs alone
# (FACTORY_TEST_ONLY=test_tdd_ledger.jl). All repos are built with realpath'd scratch dirs.

if !isdefined(Main, :Tdd)
    include(joinpath(SCRIPTS, "tdd.jl"))
end
const OL_TDD = getfield(Main, :Tdd)
const OL_TW = "test-writer <test-writer@factory.invalid>"
const OL_UNSET = (
    "FACTORY_ALLOW_T3", "FACTORY_ALLOW_PUSH", "FACTORY_ALLOW_OUTWARD", "GIT_AUTHOR_NAME", "GIT_AUTHOR_EMAIL",
    "GIT_AUTHOR_DATE", "GIT_COMMITTER_NAME", "GIT_COMMITTER_EMAIL", "GIT_DIR", "GIT_WORK_TREE", "GIT_INDEX_FILE",
)
const OL_SEQ = Ref(0)
ol_tu() = (OL_SEQ[] += 1; "toolu_ol$(OL_SEQ[])")

"A copy of the hooks dir with no read-only roots, not required (as test_hooks.jl's hooks_with_roots)."
function ol_hooks()
    h = joinpath(mktempdir(), "hooks")
    cp(HOOKS, h)
    write(joinpath(h, "read-only-roots.txt"), "# test\n")
    env = joinpath(h, "limits.env")
    write(env, replace(read(env, String), r"READ_ONLY_ROOTS_REQUIRED=\d" => "READ_ONLY_ROOTS_REQUIRED=0"))
    return h
end
const OL_HOOKS = ol_hooks()

# ---- JSON payloads (stdlib only) ----
ol_j(x::AbstractString) = "\"" * escape_string(x) * "\""
ol_j(x::Bool) = x ? "true" : "false"
ol_j(d::AbstractDict) = "{" * join(["$(ol_j(string(k))):$(ol_j(v))" for (k, v) in d], ",") * "}"
function ol_bash(c; agent, agent_id = nothing, tu, cwd, event = "PreToolUse", extra = Dict())
    d = Dict{String, Any}(
        "session_id" => "s1", "hook_event_name" => event, "tool_name" => "Bash",
        "tool_input" => Dict{String, Any}("command" => c), "tool_use_id" => tu, "cwd" => cwd, "agent_type" => agent,
    )
    agent_id === nothing || (d["agent_id"] = agent_id)
    return ol_j(merge!(d, extra))
end

# ---- scratch repos ----
ol_git(d, args...) = sh(`git -C $d $args`)
ol_head(d) = readchomp(`git -C $d rev-parse HEAD`)
function ol_repo(d, files)
    mkpath(d)
    ol_git(d, "init", "-q", "-b", "main")
    for (k, v) in ("user.name" => "test", "user.email" => "t@example.com", "commit.gpgsign" => "false")
        ol_git(d, "config", k, v)
    end
    for (rel, c) in files
        mkpath(dirname(joinpath(d, rel)))
        write(joinpath(d, rel), c)
    end
    ol_git(d, "add", "-A")
    ol_git(d, "commit", "-q", "-m", "init")
    return d
end
"""
OUTER repo S (the coordinator, a session root) holding the NESTED separate repo S/Pkg.jl (the package,
gitignored by S), with the lane worktree S/Pkg.jl/.worktrees/lane1. Both S and Pkg.jl already hold a
.lanes/ledger.jsonl, so neither "the file exists" nor "outermost" can pick the right one by accident.
"""
function ol_topo()
    S = ol_repo(joinpath(realpath(mktempdir()), "coord"), Dict(".gitignore" => "Pkg.jl/\n.lanes/\n", "HANDOFF.md" => "h\n"))
    pkg = ol_repo(
        joinpath(S, "Pkg.jl"), Dict(
            ".gitignore" => ".lanes/\n.worktrees/\n", "Project.toml" => "name = \"P\"\n",
            "src/P.jl" => "module P\nf(x) = x\nend\n", "test/runtests.jl" => "using Test\n",
            "test/t.jl" => "@testitem \"f\" begin\n    @test true\nend\n",
        )
    )
    ol_git(pkg, "worktree", "add", "-q", "-b", "lane1", ".worktrees/lane1")
    lane = joinpath(pkg, ".worktrees", "lane1")
    for d in (S, pkg)
        mkpath(joinpath(d, ".lanes"))
        write(joinpath(d, ".lanes", "ledger.jsonl"), "")
    end
    home = realpath(mktempdir())
    return (; S, pkg, lane, home, outer_ledger = joinpath(S, ".lanes", "ledger.jsonl"), pkg_ledger = joinpath(pkg, ".lanes", "ledger.jsonl"))
end
ol_env(t, root) = ["CLAUDE_PROJECT_DIR" => root, "HOME" => t.home, "GIT_CONFIG_NOSYSTEM" => "1", (k => nothing for k in OL_UNSET)...]

# ---- hooks ----
"Run hook `name` with `payload`, cwd and CLAUDE_PROJECT_DIR = `root`; (rc, err)."
function ol_run(t, root, payload; name)
    err = IOBuffer()
    cmd = Cmd(addenv(`sh $(joinpath(OL_HOOKS, name))`, ol_env(t, root)...); dir = root)
    p = run(pipeline(ignorestatus(cmd); stdin = IOBuffer(payload), stdout = devnull, stderr = err))
    return (rc = p.exitcode, err = String(take!(err)))
end
"One Bash call end to end in session root `root`: Pre (tdd_boundary.sh), the command, Post (tdd_commit_post.sh)."
function ol_flow(t, root, c; agent = "test-writer", agent_id = nothing)
    tu = ol_tu()
    pre = ol_run(t, root, ol_bash(c; agent, agent_id, tu, cwd = t.lane); name = "tdd_boundary.sh")
    pre.rc == 0 || return (; pre, ran = false, post = nothing)
    ran = success(Cmd(addenv(`sh -c $c`, ol_env(t, root)...); dir = t.lane))
    extra = Dict("tool_response" => Dict("stdout" => "", "stderr" => "", "interrupted" => false))
    post = ol_run(t, root, ol_bash(c; agent, agent_id, tu, cwd = t.lane, event = "PostToolUse", extra); name = "tdd_commit_post.sh")
    return (; pre, ran, post)
end
ol_fields(l) = Dict{String, String}(m.captures[1] => m.captures[2] for m in eachmatch(r"\"([A-Za-z_]+)\"\s*:\s*\"((?:[^\"\\]|\\.)*)\"", l))
"The `tdd-commit` records with this sha in ledger file `f`."
ol_commit_recs(f, sha) = isfile(f) ?
    [r for r in (ol_fields(l) for l in eachline(f) if !isempty(strip(l))) if get(r, "ev", "") == "tdd-commit" && get(r, "sha", "") == sha] : Dict{String, String}[]

"The shell `owning_ledger CHECKOUT` from a hooks copy's _lib.sh (session root `root`); (rc, out, err)."
function ol_sh_owning(t, root, checkout)
    out, err = IOBuffer(), IOBuffer()
    cmd = Cmd(addenv(`sh -c '. ./_lib.sh && owning_ledger "$1"' _ $checkout`, ol_env(t, root)...); dir = OL_HOOKS)
    p = run(pipeline(ignorestatus(cmd); stdin = devnull, stdout = out, stderr = err))
    return (rc = p.exitcode, out = chomp(String(take!(out))), err = String(take!(err)))
end
"Julia `Tdd.owning_ledger(checkout)`, or nothing while it is not defined."
ol_jl_owning(checkout) = isdefined(OL_TDD, :owning_ledger) ? getfield(OL_TDD, :owning_ledger)(checkout) : nothing

@testset "TDD ledger: the owning repo's main checkout (0.3.1 finding 2)" begin
    @testset "unnamed subagent (session root = outer) records in the nested package's ledger" begin
        t = ol_topo()
        write(joinpath(t.lane, "test", "t2.jl"), "@testitem \"g\" begin\n    @test true\nend\n")
        c = "git -C $(t.lane) add test/t2.jl && git -C $(t.lane) commit -q -m \"test: g\" -m \"TDD: red\" --author \"$OL_TW\""
        f = ol_flow(t, t.S, c; agent_id = "a0123456789abcdef")
        sha = ol_head(t.lane)
        @test f.pre.rc == 0 && f.ran && sha != ol_head(t.pkg)   # precondition: the role commit happened
        @test length(ol_commit_recs(t.pkg_ledger, sha)) == 1
        @test isempty(ol_commit_recs(t.outer_ledger, sha))
        @test all(r -> get(r, "agent_type", "") == "test-writer", ol_commit_recs(t.pkg_ledger, sha))
    end
    @testset "named teammate (session root = nested main) records in the nested package's ledger" begin
        t = ol_topo()
        write(joinpath(t.lane, "test", "t2.jl"), "@testitem \"g\" begin\n    @test true\nend\n")
        c = "git -C $(t.lane) add test/t2.jl && git -C $(t.lane) commit -q -m \"test: g\" -m \"TDD: red\" --author \"$OL_TW\""
        f = ol_flow(t, t.pkg, c)   # a teammate's payload: agent_type, no agent_id
        sha = ol_head(t.lane)
        @test f.pre.rc == 0 && f.ran && sha != ol_head(t.pkg)
        @test length(ol_commit_recs(t.pkg_ledger, sha)) == 1
        @test isempty(ol_commit_recs(t.outer_ledger, sha))
    end
    @testset "both dispatch shapes write the same ledger" begin
        t = ol_topo()
        shas = String[]
        for (i, (root, aid)) in enumerate(((t.S, "a1"), (t.pkg, nothing)))
            write(joinpath(t.lane, "test", "t$i.jl"), "@testitem \"g$i\" begin\n    @test true\nend\n")
            c = "git -C $(t.lane) add test/t$i.jl && git -C $(t.lane) commit -q -m \"test: g$i\" -m \"TDD: red\" --author \"$OL_TW\""
            f = ol_flow(t, root, c; agent_id = aid)
            @test f.pre.rc == 0 && f.ran
            push!(shas, ol_head(t.lane))
        end
        @test allunique(shas)
        @test all(s -> length(ol_commit_recs(t.pkg_ledger, s)) == 1, shas)
        @test all(s -> isempty(ol_commit_recs(t.outer_ledger, s)), shas)
    end

    @testset "audit with no --ledger uses the nested main's ledger, not the outer one" begin
        t = ol_topo()
        @test isfile(t.outer_ledger) && isfile(t.pkg_ledger)   # precondition: both exist
        @test ol_jl_owning(t.lane) == t.pkg_ledger
        io = IOBuffer()
        OL_TDD.audit(t.lane; base = "main", io)
        out = String(take!(io))
        @test occursin("ledger $(t.pkg_ledger))", out)
        @test !occursin("ledger $(t.outer_ledger))", out)
        cli = read(pipeline(ignorestatus(`$JULIA $(joinpath(SCRIPTS, "tdd.jl")) audit --root $(t.lane) --base main`); stderr = devnull), String)
        @test occursin("ledger $(t.pkg_ledger))", cli)
    end

    @testset "owning_ledger: shell and Julia agree" begin
        t = ol_topo()
        cases = (
            "main checkout of the nested repo" => (t.pkg, t.pkg_ledger),
            "linked worktree of the nested repo" => (t.lane, t.pkg_ledger),
            "a subdirectory of the linked worktree" => (joinpath(t.lane, "test"), t.pkg_ledger),
            "the outer repo" => (t.S, t.outer_ledger),
        )
        for (what, (checkout, want)) in cases, root in (t.S, t.pkg)
            @testset "$what (session root $(root == t.S ? "outer" : "nested"))" begin
                s = ol_sh_owning(t, root, checkout)
                @test s.rc == 0
                @test s.out == want
                @test ol_jl_owning(checkout) == want
                @test s.out == ol_jl_owning(checkout)
            end
        end
    end
end
