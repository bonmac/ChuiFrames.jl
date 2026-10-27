# Tests for the tdd_boundary hook and the commit guard (factory 0.3.0, plan Task 8; spec §0.3-§0.7,
# §4.6). Written before the hooks exist (step 1, red); the implementer does not edit them.
# Part 2 (commit guard, dispatch) is test_hooks_tdd2.jl, which uses the helpers defined here.
#
# Representation choices the implementer follows (decided from the plan and spec by the test writer):
#
# - Files: .claude/hooks/tdd_boundary.sh (sources _lib.sh, _bash_guard_lib.sh, _tdd_commit_guard.sh)
#   and .claude/hooks/tdd_commit_post.sh, each <= 150 lines. Tests run a COPY of the hooks dir made
#   when this file loads (TB_HOOKS, via hooks_with_roots(String[])), never HOOKS itself.
# - Running a hook: `sh <copy>/tdd_boundary.sh` (or tdd_commit_post.sh), cwd = the session root,
#   CLAUDE_PROJECT_DIR = the session root, the payload on stdin. HOME is a scratch home (it holds a
#   fake ~/.claude/projects transcript and a fake ~/.julia/packages depot), GIT_CONFIG_NOSYSTEM=1,
#   and FACTORY_ALLOW_T3/PUSH/OUTWARD, GIT_AUTHOR_*/GIT_COMMITTER_*, GIT_DIR, GIT_WORK_TREE and
#   GIT_INDEX_FILE are REMOVED from the env, so a caller's env never leaks in.
# - Allow = exit 0. Deny = exit 2 with stderr naming the rule and "§0.6" (paths, Bash allowlist,
#   dispatch) or "§0.5" (the commit guard, background commits). Every PreToolUse denial appends
#   `{"ev":"tdd-boundary-denied","agent_type":…,"tool":<tool_name>,"rule":…}` to the ledger.
# - Payload: {"session_id","hook_event_name","tool_name","tool_input","tool_use_id","cwd"} plus
#   optional "agent_type" and "agent_id". One script serves every matcher: it dispatches on
#   tool_name. The role is keyed on agent_type ONLY (Task 0: named teammates carry agent_type and no
#   agent_id): the test-writer's payloads here carry NO agent_id. The lead is the caller with no
#   agent_type at all; a payload with agent_id but no agent_type is the lead. Post payloads carry
#   hook_event_name "PostToolUse" (+ tool_response) or "PostToolUseFailure" (+ error).
# - The ledger is <session root>/.lanes/ledger.jsonl (_lib.sh's `ledger`; string fields). Events:
#   tdd-boundary-denied {agent_type, tool, rule}; tdd-commit {agent_id ("-" when absent),
#   agent_type, checkout, sha} with sha the FULL resulting sha and checkout the checkout's path with
#   symlinks resolved (pwd -P), plus late = "true" when written by the sweep (a JSON true is also
#   accepted); tdd-commit-violation {agent_id, agent_type, checkout, sha, rule}. Note that tdd.jl's
#   E5 prints a violation's `reason` field: writing both `rule` and `reason` keeps that message.
# - Pending: the Pre half of every allowed Bash call containing `git commit` creates
#   <session root>/.lanes/tdd-pending/<tool_use_id> (a file, or a directory of that name). What it
#   holds is the implementer's choice, but it must let a sweep run by ANOTHER caller record the
#   original caller's agent_type (and agent_id) with each checkout's HEAD before the call. The
#   post half consumes and deletes the entry of its own tool_use_id.
# - Stale (the sweep): the sweep test leaves a pending entry of an earlier tool_use_id whose
#   command did run but got no post event, sets the mtime of everything under tdd-pending/ one
#   hour back, and then makes a Pre call (the lead's `ls`) with a different tool_use_id. Either
#   criterion ("another tool_use_id" or "older than N seconds", N < 3600) satisfies it; an entry
#   of the current call is never swept. A swept entry is deleted.
# - "Printed to the caller": the post hook writes a violation on stderr (exit code not asserted).
# - Topology (a), built by tb_topo(): a session root S (a git repo standing in for the
#   coordinator) holds the nested package repo S/Pkg.jl (main checkout) with the lane worktree
#   S/Pkg.jl/.worktrees/lane1 (`git worktree add`), and a second package repo S/Pkg2.jl with a lane
#   worktree of the SAME name lane1. Scenario repos from fixtures/tdd/git/*.sh are built under S
#   (S/Fx*). Gitignored: S ignores Pkg.jl/, Pkg2.jl/, Fx*/, .lanes/; the packages ignore .lanes/ and
#   .worktrees/, so a lane's evidence and scratch files leave it clean.
# - Brief header: `<!-- tdd-brief role=<role> lane=<lane> checkout=<abs path> head=<full sha> -->`
#   as the prompt's first line. A clean dispatch saves the whole prompt as a file under
#   <main>/.lanes/briefs/<lane>/dispatched/, <main> being the main checkout of the repo owning
#   checkout= (S/Pkg.jl for S/Pkg.jl/.worktrees/lane1); the file name is the implementer's choice.
# - "post-commit violation recorded" stubs out the Pre half by staging the violating path AFTER the
#   (allowed) Pre call, then making the commit with git and running only tdd_commit_post.sh with
#   the same tool_use_id. "missing library" is a hooks copy without _lib.sh (and one without
#   _bash_guard_lib.sh).
using TOML

const TB_HOOKS = hooks_with_roots(String[])   # copied now: the new hooks are part of it once they exist
const TB_GIT = joinpath(@__DIR__, "fixtures", "tdd", "git")
const TB_TW = "test-writer <test-writer@factory.invalid>"
const TB_IMPL = "implementer <implementer@factory.invalid>"
const TB_LEAD = "lead <lead@factory.invalid>"
const TB_UNSET = ("FACTORY_ALLOW_T3", "FACTORY_ALLOW_PUSH", "FACTORY_ALLOW_OUTWARD", "GIT_AUTHOR_NAME", "GIT_AUTHOR_EMAIL",
    "GIT_AUTHOR_DATE", "GIT_COMMITTER_NAME", "GIT_COMMITTER_EMAIL", "GIT_DIR", "GIT_WORK_TREE", "GIT_INDEX_FILE")
const TB_SEQ = Ref(0)
tb_tu() = (TB_SEQ[] += 1; "toolu_tb$(TB_SEQ[])")

# ---- JSON payloads (stdlib only) ----
tb_j(x::AbstractString) = "\"" * json(x) * "\""
tb_j(x::Bool) = x ? "true" : "false"
tb_j(::Nothing) = "null"
tb_j(x::Integer) = string(x)
tb_j(d::AbstractDict) = "{" * join(["$(tb_j(string(k))):$(tb_j(v))" for (k, v) in d], ",") * "}"
"A hook payload; `agent` is the agent_type (nothing: the lead)."
function tb_pay(tool, input; agent = nothing, agent_id = nothing, tu = tb_tu(), cwd = "", event = "PreToolUse", extra = Dict())
    d = Dict{String, Any}("session_id" => "s1", "hook_event_name" => event, "tool_name" => tool,
        "tool_input" => input, "tool_use_id" => tu, "cwd" => cwd)
    agent === nothing || (d["agent_type"] = agent)
    agent_id === nothing || (d["agent_id"] = agent_id)
    return tb_j(merge!(d, extra))
end
tb_read(p; agent = "test-writer", kw...) = tb_pay("Read", Dict{String, Any}("file_path" => p); agent, kw...)
tb_write(p; tool = "Write", agent = "test-writer", key = "file_path") = tb_pay(tool, Dict{String, Any}(key => p, "content" => "x\n"); agent)
tb_bash(c; agent = "test-writer", cwd = "", bg = nothing, kw...) =
    tb_pay("Bash", Dict{String, Any}("command" => c, (bg === nothing ? () : ("run_in_background" => bg,))...); agent, cwd, kw...)

# ---- running hooks and commands ----
tb_env(t) = ["CLAUDE_PROJECT_DIR" => t.S, "HOME" => t.home, "GIT_CONFIG_NOSYSTEM" => "1", (k => nothing for k in TB_UNSET)...]
"Run hook `name` with `payload`; (rc, out, err). A missing hook is `sh`'s exit 127: neither allow nor deny."
function tb_run(t, payload; name = "tdd_boundary.sh", hooks = TB_HOOKS)
    out, err = IOBuffer(), IOBuffer()
    cmd = Cmd(addenv(`sh $(joinpath(hooks, name))`, tb_env(t)...); dir = t.S)
    p = run(pipeline(ignorestatus(cmd); stdin = IOBuffer(payload), stdout = out, stderr = err))
    return (rc = p.exitcode, out = String(take!(out)), err = String(take!(err)))
end
tb_ok(t, p; kw...) = (r = tb_run(t, p; kw...); r.rc == 0 || (println("not allowed (rc $(r.rc)): $p\n  $(r.err)"); false))
tb_no(t, p, sect = "§0.6"; kw...) = (r = tb_run(t, p; kw...); (r.rc == 2 && occursin(sect, r.err)) || (println("not denied with $sect (rc $(r.rc)): $p"); false))
"Run `c` as the harness would (sh -c in `cwd`, the hooks' env); true on exit 0."
tb_exec(t, c, cwd) = success(Cmd(addenv(`sh -c $c`, tb_env(t)...); dir = cwd))
tb_git(d, args...) = sh(`git -C $d $args`)
tb_head(d) = readchomp(`git -C $d rev-parse HEAD`)
"One allowed-or-denied Bash call end to end: Pre, then (if allowed) the command, then the post hook."
function tb_flow(t, c; agent = "test-writer", cwd = t.lane)
    tu = tb_tu()
    pre = tb_run(t, tb_bash(c; agent, cwd, tu))
    pre.rc == 0 || return (; pre, ran = false, post = nothing)
    ran = tb_exec(t, c, cwd)
    extra = ran ? Dict("tool_response" => Dict("stdout" => "", "stderr" => "", "interrupted" => false)) : Dict("error" => "Exit code 1")
    post = tb_run(t, tb_bash(c; agent, cwd, tu, event = ran ? "PostToolUse" : "PostToolUseFailure", extra); name = "tdd_commit_post.sh")
    return (; pre, ran, post)
end

# ---- the ledger ----
tb_ledger_lines(t) = (f = joinpath(t.S, ".lanes", "ledger.jsonl"); isfile(f) ? filter(!isempty, readlines(f)) : String[])
tb_fields(l) = Dict{String, String}(m.captures[1] => m.captures[2] for m in eachmatch(r"\"([A-Za-z_]+)\"\s*:\s*\"((?:[^\"\\]|\\.)*)\"", l))
tb_recs(t, ev) = [tb_fields(l) for l in tb_ledger_lines(t) if get(tb_fields(l), "ev", "") == ev]
tb_late(t, sha) = any(l -> occursin("\"$sha\"", l) && occursin(r"\"late\"\s*:\s*\"?true\"?", l), tb_ledger_lines(t))
tb_canon(p) = (q = rstrip(p, '/'); ispath(q) ? realpath(q) : q)

# ---- topology (a) ----
"A git repo at `d` (created) with one commit on main; `links` maps relative path => symlink target."
function tb_repo(d, files; links = Dict{String, String}())
    mkpath(d)
    tb_git(d, "init", "-q", "-b", "main")
    for (k, v) in ("user.name" => "test", "user.email" => "t@example.com", "commit.gpgsign" => "false")
        tb_git(d, "config", k, v)
    end
    for (rel, c) in files
        mkpath(dirname(joinpath(d, rel)))
        write(joinpath(d, rel), c)
    end
    for (rel, target) in links
        symlink(target, joinpath(d, rel))
    end
    tb_git(d, "add", "-A")
    tb_git(d, "commit", "-q", "-m", "init")
    return d
end
tb_pkg_files(name) = Dict(
    ".gitignore" => ".lanes/\n.worktrees/\n", "Project.toml" => "name = \"$name\"\n",
    "src/$name.jl" => "module $name\nf(x) = x\nend\n", "ext/$(name)Ext.jl" => "module $(name)Ext end\n",
    "test/runtests.jl" => "using Test\n", "test/Project.toml" => "[deps]\n",
    "test/t.jl" => "@testitem \"f\" begin\n    @test true\nend\n", "docs/src/index.md" => "# $name\n",
    "changelog.d/x.md" => "- x\n",
)
function tb_write!(d, files)
    for (rel, c) in files
        mkpath(dirname(joinpath(d, rel)))
        write(joinpath(d, rel), c)
    end
end
"Session root S (coordinator stand-in) with S/Pkg.jl + lane worktree lane1, S/Pkg2.jl + lane1, a scratch HOME."
function tb_topo()
    S = tb_repo(joinpath(realpath(mktempdir()), "coord"), Dict(".gitignore" => "Pkg.jl/\nPkg2.jl/\nFx*/\n.lanes/\n",
        "docs/superpowers/specs/s.md" => "# spec\n", "contracts/c.md" => "c\n", "adr/0001-x.md" => "adr\n", "HANDOFF.md" => "h\n"))
    pkg = tb_repo(joinpath(S, "Pkg.jl"), tb_pkg_files("P"); links = Dict("test/lnk" => "../src"))
    pkg2 = tb_repo(joinpath(S, "Pkg2.jl"), tb_pkg_files("Q"))
    tb_git(pkg, "worktree", "add", "-q", "-b", "lane1", ".worktrees/lane1")
    tb_git(pkg2, "worktree", "add", "-q", "-b", "lane1", ".worktrees/lane1")
    lane, lane2 = joinpath(pkg, ".worktrees", "lane1"), joinpath(pkg2, ".worktrees", "lane1")
    tb_write!(lane, Dict(".lanes/evidence/red-abc1234.txt" => "red\n", ".lanes/evidence/green-abc1234.txt" => "green\n",
        ".lanes/evidence/mutate-f-0a1b2c3d-abc1234.txt" => "m\n", ".lanes/evidence/mutexp-f-0a1b2c3d-abc1234.txt" => "m\n",
        ".lanes/scratch/mutate/src/P.jl" => "module P end\n", ".lanes/reports/r.md" => "report\n"))
    home = realpath(mktempdir())
    tb_write!(home, Dict(".claude/projects/-coord/abc.jsonl" => "{}\n", ".julia/packages/P/xyz/src/P.jl" => "module P end\n"))
    return (; S, pkg, lane, pkg2, lane2, home)
end
"Build fixture `name` (fixtures/tdd/git/<name>.sh) at S/<dir>, give it a non-role user, return its path."
function tb_fixture(t, name, dir)
    d = joinpath(t.S, dir)
    sh(Cmd(addenv(`sh $(joinpath(TB_GIT, name)) $d`, tb_env(t)...)))
    tb_git(d, "config", "user.name", "test")
    tb_git(d, "config", "user.email", "t@example.com")
    return d
end

@testset "tdd_boundary hook and commit guard (0.3.0)" begin
    t = tb_topo()
    L, P = t.lane, t.pkg

    # ---- reads (spec §0.6, test-writer allowlist) ----
    @testset "test-writer Read lane test/ allowed" begin
        for p in ("$L/test/t.jl", "$L/docs/src/index.md", "$L/Project.toml", "$(t.S)/docs/superpowers/specs/s.md",
                "$(t.S)/contracts/c.md", "$(t.S)/adr/0001-x.md")
            @test tb_ok(t, tb_read(p))
        end
        @test tb_ok(t, tb_pay("Grep", Dict{String, Any}("pattern" => "f", "path" => "$L/test"); agent = "test-writer"))
        @test tb_ok(t, tb_pay("Glob", Dict{String, Any}("pattern" => "*.jl", "path" => "$L/test"); agent = "test-writer"))
    end
    @testset "test-writer Read src denied" begin
        @test tb_no(t, tb_read("$L/src/P.jl"))
        @test tb_no(t, tb_read("$P/src/P.jl"))
        @test tb_no(t, tb_read("$L/ext/PExt.jl"))
        r = tb_recs(t, "tdd-boundary-denied")
        @test any(x -> get(x, "agent_type", "") == "test-writer" && get(x, "tool", "") == "Read" && !isempty(get(x, "rule", "")), r)
    end
    @testset "test-writer Read via test/ symlink to ../src denied" begin
        @test islink("$L/test/lnk") && isfile("$L/test/lnk/P.jl")   # precondition
        @test tb_no(t, tb_read("$L/test/lnk/P.jl"))
        @test tb_no(t, tb_pay("Grep", Dict{String, Any}("pattern" => "f", "path" => "$L/test/lnk"); agent = "test-writer"))
    end
    @testset "test-writer Read ~/.claude/projects transcript denied" begin
        @test tb_no(t, tb_read("$(t.home)/.claude/projects/-coord/abc.jsonl"))
        @test tb_no(t, tb_read("~/.claude/projects/-coord/abc.jsonl"))
    end
    @testset "test-writer Read ~/.julia/packages denied" begin
        @test tb_no(t, tb_read("$(t.home)/.julia/packages/P/xyz/src/P.jl"))
        @test tb_no(t, tb_pay("Grep", Dict{String, Any}("pattern" => "f", "path" => "$(t.home)/.julia/packages"); agent = "test-writer"))
    end
    @testset "test-writer Read .lanes/scratch/mutate denied" begin
        @test tb_no(t, tb_read("$L/.lanes/scratch/mutate/src/P.jl"))
        @test tb_no(t, tb_pay("Glob", Dict{String, Any}("pattern" => "**", "path" => "$L/.lanes/scratch"); agent = "test-writer"))
    end
    @testset "test-writer Read mutate-* evidence denied; red-* allowed" begin
        @test tb_no(t, tb_read("$L/.lanes/evidence/mutate-f-0a1b2c3d-abc1234.txt"))
        @test tb_no(t, tb_read("$L/.lanes/evidence/mutexp-f-0a1b2c3d-abc1234.txt"))
        @test tb_ok(t, tb_read("$L/.lanes/evidence/red-abc1234.txt"))
        @test tb_ok(t, tb_read("$L/.lanes/evidence/green-abc1234.txt"))
    end
    @testset "test-writer Grep without path denied" begin
        @test tb_no(t, tb_pay("Grep", Dict{String, Any}("pattern" => "f"); agent = "test-writer", cwd = L))
        @test tb_no(t, tb_pay("Glob", Dict{String, Any}("pattern" => "**/*.jl"); agent = "test-writer", cwd = L))
        @test tb_ok(t, tb_pay("Grep", Dict{String, Any}("pattern" => "f", "path" => "$L/test/t.jl"); agent = "test-writer"))
    end
    @testset "test-writer Read reports, changelog.d and HANDOFF denied" begin
        for p in ("$L/.lanes/reports/r.md", "$L/changelog.d/x.md", "$(t.S)/HANDOFF.md")
            @test tb_no(t, tb_read(p))
        end
    end
    @testset "role keyed on agent_type only; the lead's reads are unguarded" begin
        @test tb_ok(t, tb_read("$L/src/P.jl"; agent = nothing))                       # the lead
        @test tb_ok(t, tb_read("$L/src/P.jl"; agent = nothing, agent_id = "a123"))    # agent_id alone is not a role
        @test tb_no(t, tb_read("$L/src/P.jl"; agent = "test-writer", agent_id = "a123"))
        @test tb_ok(t, tb_read("$L/src/P.jl"; agent = "implementer"))
        @test tb_ok(t, tb_read("$L/src/P.jl"; agent = "general-purpose"))
    end

    # ---- writes ----
    @testset "test-writer Write src denied; Write test allowed" begin
        @test tb_no(t, tb_write("$L/src/P.jl"))
        @test tb_no(t, tb_write("$L/src/P.jl"; tool = "MultiEdit"))
        @test tb_no(t, tb_write("$L/docs/src/index.md"; tool = "Edit"))
        @test tb_ok(t, tb_write("$L/test/new_tests.jl"))
        @test tb_ok(t, tb_write("$L/test/t.jl"; tool = "Edit"))
        @test tb_no(t, tb_write("$L/test/lnk/P.jl"; tool = "Edit"))   # resolves to src/
    end
    @testset "test-writer Write test/runtests.jl denied" begin
        @test tb_no(t, tb_write("$L/test/runtests.jl"))
        @test tb_no(t, tb_write("$L/test/Project.toml"; tool = "Edit"))
    end
    @testset "test-writer NotebookEdit outside test denied" begin
        @test tb_no(t, tb_write("$L/docs/n.ipynb"; tool = "NotebookEdit", key = "notebook_path"))
        @test tb_ok(t, tb_write("$L/test/n.ipynb"; tool = "NotebookEdit", key = "notebook_path"))
    end
    @testset "implementer Write test denied" begin
        @test tb_no(t, tb_write("$L/test/t.jl"; agent = "implementer"))
        @test tb_no(t, tb_write("$L/test/u.jl"; tool = "Edit", agent = "implementer"))
        @test tb_no(t, tb_write("$(t.lane2)/test/t.jl"; agent = "implementer"))   # any checkout
        @test tb_ok(t, tb_write("$L/src/P.jl"; tool = "Edit", agent = "implementer"))
    end
    @testset "implementer Bash redirect into test/ denied" begin
        im(c) = tb_bash(c; agent = "implementer", cwd = L)
        for c in ("echo x > test/t.jl", "cd $L && echo x >> test/u.jl", "printf x | tee $L/test/t.jl", "cp src/P.jl test/t.jl",
                "cat > test/v.jl <<'EOF'\nx\nEOF")
            @test tb_no(t, im(c))
        end
        for c in ("echo x > src/gen.jl", "ls test", "cat test/t.jl", "julia --project -e 'using P'")
            @test tb_ok(t, im(c))
        end
    end

    # ---- Bash allowlist (test-writer) ----
    twb(c) = tb_bash(c; cwd = L)
    @testset "cd <lane> && julia tdd.jl red allowed" begin
        @test tb_ok(t, twb("cd $L && julia scripts/" * "tdd.jl red"))
        for c in ("julia $L/scripts/tdd.jl green", "julia scripts/tdd.jl api", "cd $L && julia scripts/ci.jl test",
                "git status", "git -C $L status", "git add test/t.jl", "ls test", "cat test/t.jl", "wc -l test/t.jl",
                "grep -n f test/t.jl", "head -5 docs/src/index.md")
            @test tb_ok(t, twb(c))
        end
    end
    @testset "julia -e denied; sh -c denied" begin
        for c in ("julia -e 'print(read(\"src/P.jl\", String))'", "cd $L && julia --project -e 1", "sh -c 'cat src/P.jl'",
                "bash -c 'cat src/P.jl'", "julia scripts/tdd.jl red && sh -c 'cat src/P.jl'")
            @test tb_no(t, twb(c))
        end
    end
    @testset "evidence.jl direct denied; tdd.jl mutate denied" begin
        for c in ("julia scripts/evidence.jl red -- cat src/P.jl", "cd $L && julia $L/scripts/evidence.jl x",
                "julia scripts/tdd.jl mutate --item f --src src/P.jl", "cd $L && julia scripts/tdd.jl mutate")
            @test tb_no(t, twb(c))
        end
    end
    @testset "git log denied; git show denied; git show HEAD:src/a.jl -- test/ denied" begin
        for c in ("git log", "git -C $L log -1", "git log -- test/", "git show", "git show HEAD -- test/",
                "git show HEAD:src/a.jl -- test/", "git blame test/t.jl", "git diff HEAD:src/P.jl -- test/",
                "git cat-file -p HEAD:src/P.jl", "git -C $L --no-pager log")
            @test tb_no(t, twb(c))
        end
    end
    @testset "git diff -- test/ allowed; git diff -- src/ denied" begin
        @test tb_ok(t, twb("git diff -- test/"))
        @test tb_ok(t, twb("git diff --cached -- test/t.jl"))
        @test tb_ok(t, twb("git -C $L diff -- test/"))
        for c in ("git diff -- src/", "git diff", "git diff -- test/ src/", "git diff --cached", "git diff -- .")
            @test tb_no(t, twb(c))
        end
    end
    @testset "test-writer cat/grep of src denied" begin
        for c in ("cat src/P.jl", "head $L/src/P.jl", "grep -r f src", "rg f", "cat test/lnk/P.jl", "ls $(t.home)/.julia/packages")
            @test tb_no(t, twb(c))
        end
    end

    # ---- registration and register rows ----
    @testset "tdd hooks exist, each <= 150 lines, sourcing the libraries" begin
        for f in ("tdd_boundary.sh", "_tdd_commit_guard.sh", "tdd_commit_post.sh")
            p = joinpath(HOOKS, f)
            @test isfile(p) && countlines(p) <= 150
        end
        b = joinpath(HOOKS, "tdd_boundary.sh")
        @test isfile(b) && all(l -> occursin(l, read(b, String)), ("_lib.sh", "_bash_guard_lib.sh", "_tdd_commit_guard.sh"))
        q = joinpath(HOOKS, "tdd_commit_post.sh")
        @test isfile(q) && all(l -> occursin(l, read(q, String)), ("_lib.sh", "_bash_guard_lib.sh"))
    end
    @testset "settings.json registers tdd_boundary (fail closed) and tdd_commit_post on both post events" begin
        s = joinpath(ROOT, ".claude", "settings.json")
        pre(m) = readlines(pipeline(`jq -r --arg m $m '.hooks.PreToolUse[]? | select(.matcher == $m) | .hooks[].command' $s`))
        for m in ("Read|Grep|Glob|Edit|Write|MultiEdit|NotebookEdit|Bash", "Agent|Task")
            @test any(c -> occursin("tdd_boundary.sh", c) && occursin("exit 2", c) && startswith(c, "sh -c '"), pre(m))
        end
        for ev in ("PostToolUse", "PostToolUseFailure")
            c = readlines(pipeline(`jq -r ".hooks.$ev[]? | select(.matcher | split(\"|\") | index(\"Bash\")) | .hooks[].command" $s`))
            @test any(x -> occursin("tdd_commit_post.sh", x), c)
        end
    end
    @testset "checks.toml has the tdd and tdd_boundary rows (spec §4.6) (tdd_boundary split in two)" begin
        # spec §4.6 gives tdd_boundary one prose prevented_by naming two hooks; the register invariant in
        # test_gen.jl ("check register covers every hook and guard script") needs one existing file per row,
        # so the row splits into tdd_boundary + tdd_commit_post, and their blind spots together are the spec's 10.
        rows = Dict(r["id"] => r for r in TOML.parsefile(joinpath(ROOT, ".agents", "checks.toml"))["checks"])
        @test haskey(rows, "tdd") && haskey(rows, "tdd_boundary") && haskey(rows, "tdd_commit_post")
        a, b = get(rows, "tdd", Dict()), get(rows, "tdd_boundary", Dict())
        c = get(rows, "tdd_commit_post", Dict())
        @test get(a, "prevented_by", "") == "scripts/tdd.jl" && get(a, "test", "") == "scripts/test/test_tdd.jl"
        # critic C7 (2026-10-27): merges and git aliases are named blind spots (tdd +2, tdd_boundary +1)
        c7tdd = ["merge commits are invisible to H1/H3/H4: lane_commits reads base..head with --no-merges, so code or test edits made in a merge resolution are seen only by the reviewer's git show --cc",
            "an alias commit (git ci) gets no commit guard, post check or record: tdd.jl audit's E5 fails it when a role identity authored it, but dod, which has no E rules, does not"]
        c7b = "a git alias for commit (e.g. git ci, from git config) bypasses the commit guard for every caller: the guard sees no commit subcommand"
        @test length(get(a, "blind_spots", [])) == 11 && last(get(a, "blind_spots", String[]), 2) == c7tdd && length(get(a, "runs_in", [])) == 2
        @test startswith(get(a, "rule", ""), "In a lane that changes src/ext: mode required has a RED")
        post = ["PostToolUse cannot undo a commit: a violating commit exists until audit E5 fails the lane",
            "a cancelled Bash call fires no post event: its commit gets only a tdd-commit-late record from a later call's sweep of .lanes/tdd-pending after 11 minutes, which does not satisfy E5: re-make or amend the commit through the hooks"]
        spec10 = ["the role comes from agent_type, documented for subagents only; teammates and a missing agent_type leave reads unguarded (TDD lanes are subagent-only)",
            "the Bash allowlist relies on bash_guard's parser; unparsed forms are denied, not modelled; a git alias for commit (git -c alias.ci=commit ci) is not seen as a commit, and E5 fails it: no tdd-commit record",
            "test code that reads src at run time is detected after the fact by review, never prevented; an uncommitted read leaves no trace",
            "run output names src files and lines, and show() can expose fields",
            "the lead's paraphrase in a brief passes; only review of the saved prompts catches it",
            post[1], post[2],
            "E5 needs the local ledger: a fresh clone or CI sees H9 only, and a forged ledger line passes",
            "fails closed on every Read/Grep/Glob/Bash call, the lead's included, when jq or a library is missing (availability cost)",
            "two instances of one model share priors; other harnesses (.codex) run no hooks"]
        # tdd_boundary: the PreToolUse hook
        @test get(b, "prevented_by", "") == ".claude/hooks/tdd_boundary.sh"
        @test startswith(get(b, "rule", ""), "A test-writer reads and writes only allowlisted paths")
        @test get(b, "runs_in", []) == ["hook PreToolUse(Read|Grep|Glob|Edit|Write|MultiEdit|NotebookEdit|Bash)",
            "hook PreToolUse(Agent|Task)"]
        @test get(b, "test", "") == "scripts/test/test_hooks_tdd.jl"
        @test length(get(b, "blind_spots", [])) == 9
        @test sort(get(b, "blind_spots", String[])) == sort(vcat(setdiff(spec10, post), c7b))
        # tdd_commit_post: the post hook
        @test get(c, "prevented_by", "") == ".claude/hooks/tdd_commit_post.sh"
        @test get(c, "runs_in", []) == ["hook PostToolUse(Bash) and PostToolUseFailure(Bash)"]
        @test get(c, "test", "") == "scripts/test/test_hooks_tdd.jl"
        @test occursin("tdd-commit", get(c, "rule", ""))
        @test get(c, "blind_spots", []) == post
        # together: exactly the spec's 10 plus critic C7's one
        @test sort(vcat(get(b, "blind_spots", String[]), get(c, "blind_spots", String[]))) == sort(vcat(spec10, c7b))
    end

    # ---- fail closed ----
    @testset "malformed payload fails closed" begin
        for p in ("not json", "{\"tool_name\":\"Read\",", "[]", "")
            @test tb_run(t, p).rc == 2
        end
        @test tb_run(t, "{\"tool_name\":\"Bash\",\"tool_input\":{\"command\":\"ls\"},\"cwd\":\"$L\"").rc == 2   # the lead too
        @test tb_ok(t, tb_bash("ls"; agent = nothing, cwd = L))                                            # control
    end
    @testset "missing library fails closed" begin
        for lib in ("_lib.sh", "_bash_guard_lib.sh")
            h = hooks_with_roots(String[]; src = TB_HOOKS)
            rm(joinpath(h, lib); force = true)
            @test tb_run(t, tb_bash("ls"; agent = nothing, cwd = L); hooks = h).rc == 2   # every caller, the lead included
            @test tb_run(t, tb_read("$L/test/t.jl"); hooks = h).rc == 2
        end
        @test tb_ok(t, tb_read("$L/test/t.jl"))   # control: the full copy allows it
    end
end

include("test_hooks_tdd2.jl")   # commit guard and dispatch
