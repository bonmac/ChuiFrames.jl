# Part 2 of the tdd_boundary tests (factory 0.3.0, plan Task 8): the commit guard (spec §0.5) and
# dispatch (spec §0.6). Included by test_hooks_tdd.jl, whose header records the representation
# choices and whose helpers (tb_*) these tests use. Each test that commits builds its own topology.

"Stage `files` (relative path => content) in `d`."
tb_stage!(d, files) = (tb_write!(d, files); foreach(f -> tb_git(d, "add", "--", f), keys(files)))
"Commit `files` in `d` directly with git (no hooks) as `who` (e.g. TB_TW)."
function tb_commit_as!(d, who, files, msg...)
    tb_stage!(d, files)
    m = match(r"^(.*) <(.*)>$", who)
    return sh(`git -C $d -c user.name=$(m[1]) -c user.email=$(m[2]) commit -q $(collect(Iterators.flatten(("-m", x) for x in msg)))`)
end
tb_cm(d; author = TB_TW, phase = "red", extra = "") = "git -C $d commit -q -m \"test: x\" -m \"TDD: $phase\" --author \"$author\"$extra"

@testset "tdd commit guard and dispatch (0.3.0)" begin
    # ---- commit guard, PreToolUse (spec §0.5) ----
    @testset "commit by test-writer with implementer author denied" begin
        t = tb_topo(); L = t.lane
        tb_stage!(L, Dict("test/t2.jl" => "x\n"))
        @test tb_no(t, tb_bash(tb_cm(L; author = TB_IMPL); cwd = L), "§0.5")
        @test tb_no(t, tb_bash("git -C $L -c user.name=implementer -c user.email=implementer@factory.invalid commit -q -m \"test: x\" -m \"TDD: red\""; cwd = L), "§0.5")
        @test tb_no(t, tb_bash("git -C $L commit -q -m \"test: x\" -m \"TDD: red\""; cwd = L), "§0.5")   # caller identity `test`: not its role
        @test tb_ok(t, tb_bash(tb_cm(L); cwd = L))
    end
    @testset "lead commit with env role author denied" begin
        t = tb_topo(); L = t.lane
        tb_stage!(L, Dict("docs/n.md" => "n\n"))
        @test tb_no(t, tb_bash("GIT_AUTHOR_NAME=test-writer GIT_AUTHOR_EMAIL=test-writer@factory.invalid git -C $L commit -q -m x"; agent = nothing, cwd = L), "§0.5")
        @test tb_no(t, tb_bash("cd $L && GIT_AUTHOR_NAME=implementer GIT_AUTHOR_EMAIL=implementer@factory.invalid git commit -q -m x"; agent = nothing, cwd = L), "§0.5")
        @test tb_ok(t, tb_bash("git -C $L commit -q -m \"docs: n\" --author \"$TB_LEAD\""; agent = nothing, cwd = L))
        @test tb_ok(t, tb_bash("git -C $L commit -q -m \"docs: n\""; agent = nothing, cwd = L))
    end
    @testset "lead commit after git config role identity denied" begin
        t = tb_topo(); L = t.lane
        tb_stage!(L, Dict("docs/n.md" => "n\n"))
        @test tb_ok(t, tb_bash("git -C $L commit -q -m \"docs: n\""; agent = nothing, cwd = L))   # before the config
        tb_git(L, "config", "user.name", "test-writer")
        tb_git(L, "config", "user.email", "test-writer@factory.invalid")
        @test tb_no(t, tb_bash("git -C $L commit -q -m \"docs: n\""; agent = nothing, cwd = L), "§0.5")
        @test tb_no(t, tb_bash("cd $L && git commit -q -m \"docs: n\""; agent = nothing, cwd = L), "§0.5")
    end
    @testset "amend keeps source author: implementer amending a test-writer commit denied" begin
        t = tb_topo()
        a = tb_fixture(t, "amend.sh", "Fx1")             # implementer HEAD; the amend added test/t.jl
        tb_git(a, "reset", "-q", "--soft", "HEAD@{1}")   # back to the moment before the amend: test/t.jl staged
        @test tb_no(t, tb_bash("git -C $a add test/t.jl && git -C $a commit -q --amend --no-edit"; agent = "implementer", cwd = a), "§0.5")
        @test tb_no(t, tb_bash("git -C $a commit -q --amend --no-edit"; agent = nothing, cwd = a), "§0.5")   # the lead: implementer identity
        c = tb_fixture(t, "C-HEAD.sh", "Fx2")            # test-writer HEAD (red)
        tb_git(c, "reset", "-q", "--hard", "HEAD~1")
        tb_stage!(c, Dict("src/P.jl" => "module P\nf(x) = 2x\nend\n"))   # only src staged: the author rule alone
        @test tb_no(t, tb_bash("git -C $c commit -q --amend --no-edit"; agent = "implementer", cwd = c), "§0.5")
        @test tb_no(t, tb_bash("git -C $c commit -q --amend --no-edit"; agent = nothing, cwd = c), "§0.5")
    end
    @testset "-C HEAD denied" begin
        t = tb_topo()
        c = tb_fixture(t, "C-HEAD.sh", "Fx1")
        tb_git(c, "reset", "-q", "--soft", "HEAD~1")     # test-writer HEAD, the implementer's test change staged
        @test tb_no(t, tb_bash("git -C $c commit -q -C HEAD"; agent = "implementer", cwd = c), "§0.5")
        @test tb_no(t, tb_bash("cd $c && git commit -q -C HEAD"; agent = nothing, cwd = c), "§0.5")
        @test tb_no(t, tb_bash("git -C $c commit -q --reuse-message=HEAD"; agent = "implementer", cwd = c), "§0.5")
    end
    @testset "amend --author role denied at Pre" begin
        t = tb_topo()
        a = tb_fixture(t, "amend-author.sh", "Fx1")
        tb_git(a, "reset", "-q", "--soft", "HEAD@{1}")   # implementer HEAD, test/t.jl staged
        @test tb_no(t, tb_bash("git -C $a commit -q --amend --no-edit --author \"$TB_TW\""; agent = "implementer", cwd = a), "§0.5")
        tb_git(a, "reset", "-q")                         # nothing staged: --author beats the source author
        @test tb_no(t, tb_bash("git -C $a commit -q --amend --no-edit --author \"$TB_TW\""; agent = "implementer", cwd = a), "§0.5")
        @test tb_ok(t, tb_bash("git -C $a commit -q --amend --no-edit"; agent = "implementer", cwd = a))   # control: source = implementer
        c = tb_fixture(t, "C-HEAD.sh", "Fx2")
        tb_git(c, "reset", "-q", "--hard", "HEAD~1")     # test-writer HEAD
        tb_stage!(c, Dict("test/t3.jl" => "x\n"))
        @test tb_no(t, tb_bash("git -C $c commit -q --amend --no-edit --author \"$TB_IMPL\""; cwd = c), "§0.5")
    end
    @testset "amend --reset-author and -C --reset-author take caller identity" begin
        t = tb_topo()
        g = tb_fixture(t, "C-reset-author.sh", "Fx1")
        tb_git(g, "reset", "-q", "--soft", "HEAD~1")     # HEAD = the implementer's green commit
        lead(c) = tb_bash(c; agent = nothing, cwd = g)
        @test tb_no(t, lead("git -C $g commit -q --amend --no-edit"), "§0.5")             # source author: implementer
        @test tb_ok(t, lead("git -C $g commit -q --amend --no-edit --reset-author"))     # caller: test
        @test tb_no(t, lead("git -C $g commit -q --allow-empty -C HEAD"), "§0.5")
        @test tb_ok(t, lead("git -C $g commit -q --allow-empty -C HEAD --reset-author"))
        # the implementer resetting to its caller identity (`test`) is not its role
        @test tb_no(t, tb_bash("git -C $g commit -q --amend --no-edit --reset-author"; agent = "implementer", cwd = g), "§0.5")
        @test tb_ok(t, tb_bash("git -C $g -c user.name=implementer -c user.email=implementer@factory.invalid commit -q --amend --no-edit --reset-author"; agent = "implementer", cwd = g))
    end
    @testset "test-writer -C/-c/--reuse-message/--reedit-message/--fixup/--squash denied" begin
        t = tb_topo()
        g = tb_fixture(t, "C-reset-author.sh", "Fx1")
        tb_git(g, "reset", "-q", "--soft", "HEAD~1")     # before the fixture's test-writer commit
        gr = tb_head(g)
        tb_stage!(g, Dict("test/t2.jl" => "x\n"))
        for o in ("-C $gr", "-c $gr", "--reuse-message=$gr", "--reedit-message=$gr", "--fixup=$gr", "--squash=$gr", "--reuse-message $gr")
            @test tb_no(t, tb_bash("git -C $g commit -q --author \"$TB_TW\" $o"; cwd = g), "§0.5")
        end
        @test tb_no(t, tb_bash("git -C $g -c user.name=test-writer -c user.email=test-writer@factory.invalid commit -q --allow-empty -C $gr --reset-author"; cwd = g), "§0.5")
        @test tb_ok(t, tb_bash(tb_cm(g); cwd = g))   # control
    end
    @testset "test-writer --amend on an implementer HEAD denied; on its own HEAD allowed" begin
        t = tb_topo()
        g = tb_fixture(t, "C-reset-author.sh", "Fx1")
        tb_git(g, "reset", "-q", "--soft", "HEAD~1")     # implementer HEAD
        tb_stage!(g, Dict("test/t2.jl" => "x\n"))
        @test tb_no(t, tb_bash("git -C $g commit -q --amend --no-edit"; cwd = g), "§0.5")
        @test tb_no(t, tb_bash("git -C $g commit -q --amend --no-edit --author \"$TB_TW\""; cwd = g), "§0.5")
        tb_commit_as!(g, TB_TW, Dict("test/t2.jl" => "x\n"), "test: t2", "TDD: red")
        tb_stage!(g, Dict("test/t3.jl" => "y\n"))
        @test tb_ok(t, tb_bash("git -C $g commit -q --amend --no-edit"; cwd = g))
    end
    @testset "run_in_background with git commit denied" begin
        t = tb_topo(); L = t.lane
        tb_stage!(L, Dict("test/t2.jl" => "x\n"))
        @test tb_no(t, tb_bash(tb_cm(L); cwd = L, bg = true), "§0.5")
        @test tb_no(t, tb_bash("git -C $L commit -q -m \"docs: x\""; agent = nothing, cwd = L, bg = true), "§0.5")
        @test tb_ok(t, tb_bash("ls"; agent = nothing, cwd = L, bg = true))
        @test tb_ok(t, tb_bash(tb_cm(L); cwd = L, bg = false))
    end
    @testset "git add test/x && git commit compound: commit checked" begin
        t = tb_topo(); L = t.lane
        tb_write!(L, Dict("test/t2.jl" => "x\n", "src/new.jl" => "x\n"))
        @test tb_no(t, tb_bash("cd $L && git add test/t2.jl && " * tb_cm(L; author = TB_IMPL); cwd = L), "§0.5")
        @test tb_no(t, tb_bash("git -C $L add test/t2.jl; " * tb_cm(L; author = TB_IMPL); cwd = L), "§0.5")
        @test tb_no(t, tb_bash("git -C $L status || " * tb_cm(L; author = TB_IMPL); cwd = L), "§0.5")
        @test tb_no(t, tb_bash("cd $L && git add src/new.jl && git commit -q -m x --author \"$TB_TW\""; agent = nothing, cwd = L), "§0.5")
        @test tb_ok(t, tb_bash("cd $L && git add test/t2.jl && " * tb_cm(L); cwd = L))
    end
    @testset "general-purpose caller with lead identity denied" begin
        t = tb_topo(); L = t.lane
        tb_stage!(L, Dict("docs/n.md" => "n\n"))
        gp(c) = tb_bash(c; agent = "general-purpose", cwd = L)
        @test tb_no(t, gp("git -C $L commit -q -m x --author \"$TB_LEAD\""), "§0.5")
        @test tb_no(t, gp("GIT_AUTHOR_NAME=lead GIT_AUTHOR_EMAIL=lead@factory.invalid git -C $L commit -q -m x"), "§0.5")
        @test tb_no(t, gp("git -C $L commit -q -m x --author \"$TB_TW\""), "§0.5")
        @test tb_ok(t, gp("git -C $L commit -q -m x"))   # its own (non-role) identity
    end
    @testset "role commit with TDD-Mode trailer denied" begin
        t = tb_topo(); L = t.lane
        tb_stage!(L, Dict("test/t2.jl" => "x\n"))
        @test tb_no(t, tb_bash(tb_cm(L; extra = " -m \"TDD-Mode: skip — docs only\""); cwd = L), "§0.5")
        @test tb_no(t, tb_bash(tb_cm(L; extra = " --trailer \"TDD-Mode: skip — x\""); cwd = L), "§0.5")
        @test tb_no(t, tb_bash(tb_cm(L; author = TB_IMPL, phase = "stub", extra = " -m \"TDD-Mode: required — x\""); agent = "implementer", cwd = L), "§0.5")
        @test tb_ok(t, tb_bash("git -C $L commit -q -m \"chore: mode\" -m \"TDD-Mode: skip — docs only\" --author \"$TB_LEAD\""; agent = nothing, cwd = L))
    end
    @testset "test-writer commit with staged src denied" begin
        t = tb_topo(); L = t.lane
        tb_stage!(L, Dict("test/t2.jl" => "x\n", "src/P.jl" => "module P\nf(x) = 3\nend\n"))
        @test tb_no(t, tb_bash(tb_cm(L); cwd = L), "§0.5")
        tb_git(L, "reset", "-q")
        tb_stage!(L, Dict("test/runtests.jl" => "using Test # x\n"))   # a seeded runner
        @test tb_no(t, tb_bash(tb_cm(L); cwd = L), "§0.5")
        tb_git(L, "reset", "-q")
        tb_stage!(L, Dict("test/t3.jl" => "x\n"))   # the implementer staging test/
        @test tb_no(t, tb_bash(tb_cm(L; author = TB_IMPL, phase = "green"); agent = "implementer", cwd = L), "§0.5")
        tb_git(L, "reset", "-q")
        tb_stage!(L, Dict("src/P.jl" => "module P\nf(x) = 4\nend\n"))
        @test tb_ok(t, tb_bash(tb_cm(L; author = TB_IMPL, phase = "green"); agent = "implementer", cwd = L))
    end

    # ---- PostToolUse / PostToolUseFailure and the ledger ----
    @testset "tdd-commit record carries the resulting sha" begin
        t = tb_topo(); L = t.lane
        tb_write!(L, Dict("test/t2.jl" => "x\n"))
        f1 = tb_flow(t, "cd $L && git add test/t2.jl && " * tb_cm(L))
        s1 = tb_head(L)
        @test f1.pre.rc == 0 && f1.ran
        @test any(r -> get(r, "sha", "") == s1 && get(r, "agent_type", "") == "test-writer" && tb_canon(get(r, "checkout", "")) == tb_canon(L), tb_recs(t, "tdd-commit"))
        tb_write!(L, Dict("test/t3.jl" => "y\n"))
        f2 = tb_flow(t, "git -C $L add test/t3.jl && git -C $L commit -q --amend --no-edit")
        s2 = tb_head(L)
        @test f2.pre.rc == 0 && f2.ran && s2 != s1
        @test any(r -> get(r, "sha", "") == s2 && get(r, "agent_type", "") == "test-writer", tb_recs(t, "tdd-commit"))
        @test !any(l -> occursin("late", l), tb_ledger_lines(t))
        @test !isdir(joinpath(t.S, ".lanes", "tdd-pending")) || isempty(readdir(joinpath(t.S, ".lanes", "tdd-pending")))
    end
    @testset "commit followed by a failing command is recorded" begin
        t = tb_topo(); L = t.lane
        tb_stage!(L, Dict("test/t2.jl" => "x\n"))
        f = tb_flow(t, tb_cm(L) * " && false")
        @test f.pre.rc == 0 && !f.ran && tb_head(L) != tb_head(t.pkg)   # the commit exists, the call failed
        @test any(r -> get(r, "sha", "") == tb_head(L) && get(r, "agent_type", "") == "test-writer", tb_recs(t, "tdd-commit"))
    end
    # "stale tdd-pending entry swept and recorded late" moved to test_hooks_tdd3.jl under the B2 ruling
    # ("B2 sweep records only in-window commits, as tdd-commit-late"): the sweep writes no tdd-commit.
    @testset "session root differs from checkout: record lands in the session ledger and audit finds it" begin
        t = tb_topo(); L = t.lane
        tb_stage!(L, Dict("test/t2.jl" => "x\n"))
        f = tb_flow(t, tb_cm(L))
        sha = tb_head(L)
        @test f.pre.rc == 0 && f.ran
        @test any(r -> get(r, "sha", "") == sha, tb_recs(t, "tdd-commit"))
        @test !isfile(joinpath(t.pkg, ".lanes", "ledger.jsonl")) && !isfile(joinpath(L, ".lanes", "ledger.jsonl"))
        out = read(pipeline(ignorestatus(`$JULIA $(joinpath(SCRIPTS, "tdd.jl")) audit --root $L --base main`); stderr = devnull), String)
        @test occursin("ledger $(joinpath(t.S, ".lanes", "ledger.jsonl"))", out)
        @test !any(l -> startswith(l, "E5"), split(out, '\n'))
    end
    @testset "post-commit violation recorded" begin
        t = tb_topo()
        a = tb_fixture(t, "amend.sh", "Fx1")
        tb_git(a, "reset", "-q", "HEAD@{1}")             # implementer HEAD; test/t.jl untracked, nothing staged
        c, tu = "git -C $a commit -q --amend --no-edit", tb_tu()
        @test tb_run(t, tb_bash(c; agent = "implementer", cwd = a, tu)).rc == 0   # Pre sees nothing wrong
        tb_git(a, "add", "test/t.jl")                    # staged after Pre: the Pre half is bypassed
        @test tb_exec(t, c, a)
        sha = tb_head(a)
        post = tb_run(t, tb_bash(c; agent = "implementer", cwd = a, tu, event = "PostToolUse",
            extra = Dict("tool_response" => Dict("stdout" => "", "stderr" => ""))); name = "tdd_commit_post.sh")
        v = tb_recs(t, "tdd-commit-violation")
        @test any(r -> get(r, "sha", "") == sha && get(r, "agent_type", "") == "implementer" && !isempty(get(r, "rule", "")), v)
        @test occursin("violation", post.err)
    end

    # ---- dispatch (spec §0.6, the lead only) ----
    tb_brief(role, co, head; lane = "lane1", mark = "marker-$(tb_tu())") = "<!-- tdd-brief role=$role lane=$lane checkout=$co head=$head -->\n## Task\n$mark\n"
    tb_disp(sub, prompt; agent = nothing, tool = "Agent") = tb_pay(tool, Dict{String, Any}("subagent_type" => sub, "prompt" => prompt, "description" => "d"); agent)
    saved(main, mark) = (d = joinpath(main, ".lanes", "briefs", "lane1", "dispatched"); isdir(d) && any(f -> isfile(joinpath(d, f)) && occursin(mark, read(joinpath(d, f), String)), readdir(d)))
    @testset "general-purpose dispatch of test-writer denied" begin
        t = tb_topo(); L = t.lane
        b = tb_brief("test-writer", L, tb_head(L))
        @test tb_no(t, tb_disp("test-writer", b; agent = "general-purpose"))
        @test tb_no(t, tb_disp("implementer", tb_brief("implementer", L, tb_head(L)); agent = "general-purpose", tool = "Task"))
        @test tb_no(t, tb_disp("test-writer", b; agent = "implementer"))
        @test tb_ok(t, tb_disp("test-writer", b))                          # the lead
        @test tb_ok(t, tb_disp("general-purpose", "no header"; agent = "general-purpose"))   # not a role: unaffected
    end
    @testset "dispatch with stale head= denied" begin
        t = tb_topo(); L = t.lane
        old = tb_head(L)
        tb_commit_as!(L, TB_TW, Dict("test/t2.jl" => "x\n"), "test: t2", "TDD: red")
        @test tb_no(t, tb_disp("test-writer", tb_brief("test-writer", L, old)))
        @test tb_no(t, tb_disp("test-writer", "## Task\nno header\n"))
        @test tb_no(t, tb_disp("test-writer", tb_brief("implementer", L, tb_head(L))))      # role mismatch
        @test tb_no(t, tb_disp("test-writer", tb_brief("test-writer", t.pkg, tb_head(t.pkg))))   # a main checkout, not a lane
        out = tb_repo(joinpath(realpath(mktempdir()), "Out.jl"), tb_pkg_files("O"))
        @test tb_no(t, tb_disp("test-writer", tb_brief("test-writer", out, tb_head(out))))   # outside the session root
        @test tb_ok(t, tb_disp("test-writer", tb_brief("test-writer", L, tb_head(L))))
    end
    @testset "dispatch on a dirty checkout denied" begin
        t = tb_topo(); L = t.lane
        write(joinpath(L, "test", "t.jl"), "changed\n")
        @test tb_no(t, tb_disp("test-writer", tb_brief("test-writer", L, tb_head(L))))
        tb_git(L, "checkout", "--", "test/t.jl")
        write(joinpath(L, "test", "new.jl"), "untracked\n")
        @test tb_no(t, tb_disp("implementer", tb_brief("implementer", L, tb_head(L))))
        rm(joinpath(L, "test", "new.jl"))
        @test tb_ok(t, tb_disp("implementer", tb_brief("implementer", L, tb_head(L))))
    end
    @testset "two repos with the same lane name: checkout= picks the right one" begin
        t = tb_topo(); L, L2 = t.lane, t.lane2
        @test tb_head(L) != tb_head(L2)   # precondition
        @test tb_no(t, tb_disp("test-writer", tb_brief("test-writer", L, tb_head(L2))))
        write(joinpath(L2, "test", "t.jl"), "dirty\n")
        m = "marker-two-repos"
        @test tb_ok(t, tb_disp("test-writer", tb_brief("test-writer", L, tb_head(L); mark = m)))
        @test saved(t.pkg, m) && !saved(t.pkg2, m)
        @test tb_no(t, tb_disp("test-writer", tb_brief("test-writer", L2, tb_head(L2))))   # Pkg2's lane1 is dirty
    end
    @testset "clean dispatch saved under the owning repo's main .lanes" begin
        t = tb_topo(); L = t.lane
        m1, m2 = "marker-clean-tw", "marker-clean-impl"
        @test tb_ok(t, tb_disp("test-writer", tb_brief("test-writer", L, tb_head(L); mark = m1)))
        @test tb_ok(t, tb_disp("implementer", tb_brief("implementer", L, tb_head(L); mark = m2); tool = "Task"))
        @test saved(t.pkg, m1) && saved(t.pkg, m2)
        @test !isdir(joinpath(L, ".lanes", "briefs")) && !isdir(joinpath(t.S, ".lanes", "briefs"))
        @test isempty(readchomp(`git -C $L status --porcelain`)) && isempty(readchomp(`git -C $(t.pkg) status --porcelain`))
    end
end

include("test_hooks_tdd3.jl")   # review round 1: B1-B3, M1, M2, minors 5-7, nit 2
