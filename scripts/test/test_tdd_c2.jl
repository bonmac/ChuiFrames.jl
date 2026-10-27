# Critic C2 (critic-030): one trailer parser, and phase-less role commits (factory 0.3.0).
# Included by runtests.jl after test_hooks_tdd.jl (the tb_* hook helpers) and test_tdd.jl (which
# loads scripts/tdd.jl as Main.Tdd; this file loads it itself when run alone). Written before the
# fix (red); the implementer does not edit it.
#
# Lead's ruling, as specified here:
# - git's own trailer semantics are the single parser: the trailer block is what
#   `git log -1 --format=%(trailers:key=TDD,valueonly)` sees (the last paragraph, not the title, git's
#   all-trailers / 25% rule, keys matched case-insensitively, `TDD:red` without a space included).
#   tdd_commit_post.sh, _tdd_history.jl `trailers()` (so `lane_commits`, H1/H9) and tdd.jl `phase()`
#   all agree with it, for the phase (`TDD`) and for the mode (`TDD-Mode`).
# - A role-authored commit (test-writer / implementer caller and identity) with no phase as git parses
#   it is a post-hook violation: exit 2 while the commit is still HEAD, a `tdd-commit-violation` with
#   rule `no-phase` (interface choice of this file, in the style of `phase-not-role`/`mode-trailer`),
#   and the printed message says how to repair it: `git commit --amend` with `--trailer`.
# - The prescribed form puts `TDD:` and `Co-Authored-By:` in one final paragraph:
#   git commit --author "<role> <<role>@factory.invalid>" -m "<subject>" --trailer "TDD: red" --trailer "Co-Authored-By: …"
#   and each role body (test_writer.md, implementer.md) and the lane-lifecycle skill show that form.
# - A lead (non-role) commit without a phase stays clean in the post hook.

const C2_ROOT = dirname(rstrip(SCRIPTS, '/'))   # factory/template
const C2_CO = "Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
const C2_TW_PHASES = ("red", "test-fix", "test-refactor", "backfill")

"Main.Tdd (scripts/tdd.jl), loaded here when this file runs without test_tdd.jl."
function c2_tdd()
    isdefined(Main, :Tdd) || Base.include(Main, joinpath(SCRIPTS, "tdd.jl"))
    return getfield(Main, :Tdd)
end
"git's own reading of trailer `key` on `sha` (first value, stripped; \"\" when none)."
c2_git_tr(d, sha, key) = String(strip(first(split(readchomp(`git -C $d log -1 $("--format=%(trailers:key=$key,valueonly)") $sha`), '\n'))))
"Commit the staged index of `d` directly with git as `who` and the full message `msg`; the new sha."
function c2_commit!(d, who, msg)
    m = match(r"^(.*) <(.*)>$", who)
    sh(`git -C $d -c user.name=$(m[1]) -c user.email=$(m[2]) commit -q --allow-empty -m $msg`)
    return tb_head(d)
end
"""
One role commit seen by the post hook: stage `files`, run the Pre half on the prescribed (always
allowed) form so a pending entry exists, make the commit with message `msg` directly with git, then run
tdd_commit_post.sh with the same tool_use_id. Returns (; pre, post, sha, viol) with viol the
tdd-commit-violation records for the new sha.
"""
function c2_post(t, d, files, msg; agent = "test-writer", who = (agent == "implementer" ? TB_IMPL : TB_TW), ph = "red")
    tb_stage!(d, files)
    tu = tb_tu()
    form = "git -C $d commit -q -m \"c2\" --author \"$who\" --trailer \"TDD: $ph\""
    pre = tb_run(t, tb_bash(form; agent, cwd = d, tu))
    sha = c2_commit!(d, who, msg)
    post = tb_run(t, tb_bash(form; agent, cwd = d, tu, event = "PostToolUse",
        extra = Dict("tool_response" => Dict("stdout" => "", "stderr" => "", "interrupted" => false))); name = "tdd_commit_post.sh")
    viol = [r for r in tb_recs(t, "tdd-commit-violation") if get(r, "sha", "") == sha]
    return (; pre, post, sha, viol)
end
c2_rules(r) = [get(v, "rule", "") for v in r.viol]
"The `git commit` forms (inside backquotes) of a doc that carry a `--trailer \"TDD: …\"`."
c2_forms(path) = isfile(path) ? [m.match for m in eachmatch(r"git (?:-C \S+ )?commit[^`\n]*--trailer \"TDD: [^\"`]*\"[^`\n]*", read(path, String))] : String[]
"A doc's form made concrete: placeholders (`<…>` without `@`) filled, the checkout `L`, the phase `ph`."
function c2_concrete(form, L, ph)
    c = replace(form, r"--trailer \"TDD: [^\"]*\"" => "--trailer \"TDD: $ph\"")
    c = replace(c, "<role> <<role>@factory.invalid>" => "ROLE <ROLE@factory.invalid>")
    c = replace(c, r"<[^<>@\"]*>" => "x")
    c = replace(c, r"-C x(?= )" => "-C $L")
    occursin("-C $L", c) || (c = "cd $L && " * c)
    return c
end

@testset "critic C2: one trailer parser, phase-less role commits (0.3.0)" begin
    @testset "test-writer -m -m -m commit (TDD: in a non-final paragraph) is a post violation: no-phase, still HEAD" begin
        t = tb_topo(); L = t.lane
        r = c2_post(t, L, Dict("test/c2a.jl" => "x\n"), "test: x\n\nTDD: red\n\n$C2_CO")
        @test r.pre.rc == 0                                   # precondition: the Pre half allowed the call
        @test c2_git_tr(L, r.sha, "TDD") == ""                # git: no phase
        @test r.post.rc == 2
        @test "no-phase" in c2_rules(r)
        @test occursin("--amend", r.post.err) && occursin("--trailer", r.post.err)
        @test tb_head(L) == r.sha                             # nothing undone: the commit can be amended
    end
    @testset "heredoc-shaped message msg/TDD: green/Co-Authored-By by the implementer is a post violation" begin
        t = tb_topo(); L = t.lane
        r = c2_post(t, L, Dict("src/P.jl" => "module P\nf(x) = 2x\nend\n"), "feat: f\n\nTDD: green\n\n$C2_CO\n";
            agent = "implementer", ph = "green")
        @test r.pre.rc == 0
        @test r.post.rc == 2
        @test "no-phase" in c2_rules(r)
        @test occursin("--amend", r.post.err) && occursin("--trailer", r.post.err)
    end
    @testset "phase-less implementer changelog fragment commit is a post violation" begin
        t = tb_topo(); L = t.lane
        r = c2_post(t, L, Dict("changelog.d/y.md" => "- y\n"), "docs: changelog fragment"; agent = "implementer", ph = "green")
        @test r.pre.rc == 0
        @test r.post.rc == 2
        @test "no-phase" in c2_rules(r)
    end
    @testset "end to end: test-writer -m -m -m commit is refused or flagged with the --trailer fix" begin
        t = tb_topo(); L = t.lane
        tb_stage!(L, Dict("test/c2e.jl" => "x\n"))
        f = tb_flow(t, "git -C $L commit -q -m \"test: x\" -m \"TDD: red\" -m \"$C2_CO\" --author \"$TB_TW\"")
        denied = f.pre.rc == 2 && occursin("§0.5", f.pre.err)
        flagged = f.ran && f.post !== nothing && f.post.rc == 2
        @test denied || flagged
        @test occursin("--trailer", denied ? f.pre.err : (f.post === nothing ? "" : f.post.err))
    end
    @testset "controls: prescribed --trailer form clean; lead phase-less commit clean" begin
        t = tb_topo(); L = t.lane
        tb_stage!(L, Dict("test/c2b.jl" => "x\n"))
        f = tb_flow(t, "git -C $L commit -q --author \"$TB_TW\" -m \"test: x\" --trailer \"TDD: red\" --trailer \"$C2_CO\"")
        sha = tb_head(L)
        @test f.pre.rc == 0 && f.ran && f.post.rc == 0
        @test any(r -> get(r, "sha", "") == sha, tb_recs(t, "tdd-commit"))
        @test !any(r -> get(r, "sha", "") == sha, tb_recs(t, "tdd-commit-violation"))
        @test c2_git_tr(L, sha, "TDD") == "red"
        T = c2_tdd()
        @test T.phase(L, sha) == "red"
        c = only(filter(x -> x.sha == sha, T.lane_commits(L, "main")))
        @test c.phase == "red"
        tb_stage!(L, Dict("docs/c2.md" => "d\n"))
        g = tb_flow(t, "git -C $L commit -q -m \"docs: c2\" --author \"$TB_LEAD\""; agent = nothing)
        @test g.pre.rc == 0 && g.ran && g.post.rc == 0
        @test !any(r -> get(r, "sha", "") == tb_head(L), tb_recs(t, "tdd-commit-violation"))
    end

    @testset "parser agreement: post hook, lane_commits, tdd.jl phase and git's %(trailers)" begin
        T = c2_tdd()
        shapes = [   # (label, message) of a test-writer commit touching only test/
            ("trailer in the last paragraph", "test: x\n\nTDD: red"),
            ("trailer in a non-final paragraph", "test: x\n\nTDD: red\n\n$C2_CO"),
            ("lowercase tdd: red", "test: x\n\ntdd: red"),
            ("trailer block mixed with Co-Authored-By", "test: x\n\nTDD: red\n$C2_CO"),
            ("prose line and TDD: in the last paragraph", "test: x\n\nprose here\nTDD: red"),
            ("TDD:red without a space", "test: x\n\nTDD:red"),
            ("title-only TDD: red", "TDD: red"),
            ("TDD-Mode in a non-final paragraph", "test: x\n\nTDD-Mode: skip — y\n\nTDD: red"),
            ("TDD-Mode in the last paragraph", "test: x\n\nTDD: red\nTDD-Mode: skip — y"),
        ]
        t = tb_topo(); L = t.lane
        res = [(lab, c2_post(t, L, Dict("test/c2_$i.jl" => "x$i\n"), msg)) for (i, (lab, msg)) in enumerate(shapes)]
        cs = T.lane_commits(L, "main")
        for (lab, r) in res
            @testset "$lab" begin
                g, gm = c2_git_tr(L, r.sha, "TDD"), c2_git_tr(L, r.sha, "TDD-Mode")
                c = only(filter(x -> x.sha == r.sha, cs))
                @test something(c.phase, "") == g                        # lane_commits = git (phase)
                @test (c.mode !== nothing) == !isempty(gm)               # lane_commits = git (mode)
                @test T.phase(L, r.sha) == g                             # tdd.jl phase = git
                bad = !(g in C2_TW_PHASES) || !isempty(gm)
                @test (r.post.rc == 2) == bad                            # post hook = git
                @test !isempty(r.viol) == bad
                isempty(g) && isempty(gm) && @test "no-phase" in c2_rules(r)
                !isempty(gm) && @test "mode-trailer" in c2_rules(r)
            end
        end
    end

    @testset "critic reproducer: -m -m -m lane, history_rules and the post hook agree; --trailer lane clean" begin
        T = c2_tdd()
        P0 = "module P\nexport f\nf(x) = x + 1\nend\n"
        P1 = "module P\nexport f, g\nf(x) = x + 1\nfunction g end\nend\n"
        P2 = "module P\nexport f, g\nf(x) = x + 1\ng(x) = 2x\nend\n"
        TT = "@testitem \"g doubles\" begin\n    using P\n    @test P.g(2) == 4\nend\n"
        mk(d, who, files, args...) = (tb_write!(d, files); sh(`git -C $d add -A -- .`);
            m = match(r"^(.*) <(.*)>$", who); sh(`git -C $d -c user.name=$(m[1]) -c user.email=$(m[2]) commit -q $args`); tb_head(d))
        function lane(form)
            d = tmp_repo(Dict(".gitignore" => ".lanes/\n", "src/P.jl" => P0, "Project.toml" => "name = \"P\"\n"))
            sh(`git -C $d checkout -q -b lane`)
            msg(subj, ph) = form == :m ? ["-m", subj, "-m", "TDD: $ph", "-m", C2_CO] : ["-m", subj, "--trailer", "TDD: $ph", "--trailer", C2_CO]
            s = mk(d, TB_IMPL, Dict("src/P.jl" => P1), msg("feat: declare g", "stub")...)
            r = mk(d, TB_TW, Dict("test/g_tests.jl" => TT), msg("test: g doubles", "red")...)
            g = mk(d, TB_IMPL, Dict("src/P.jl" => P2), msg("feat: g doubles", "green")...)
            return d, (; s, r, g)
        end
        d, c = lane(:m)
        cs = T.lane_commits(d, "main")
        @test all(x -> x.phase === nothing, cs)                          # git: no phase on any of them
        v = T.history_rules(cs; stub_ok = _ -> true)
        @test any(s -> startswith(s, "H9"), v)                            # dod: H9 (phase-less role commit)
        # the same test-writer commit at commit time: the post hook must say so too (exit 2, no-phase)
        t = tb_topo(); L = t.lane
        r = c2_post(t, L, Dict("test/g_tests.jl" => TT), "test: g doubles\n\nTDD: red\n\n$C2_CO")
        @test r.post.rc == 2 && "no-phase" in c2_rules(r)
        d2, c2 = lane(:trailer)
        cs2 = T.lane_commits(d2, "main")
        @test [x.phase for x in cs2] == ["stub", "red", "green"]
        @test isempty(T.history_rules(cs2; stub_ok = _ -> true))
    end

    @testset "role bodies and the lane-lifecycle skill give the one --trailer commit form" begin
        tw = joinpath(C2_ROOT, ".agents", "bodies", "test_writer.md")
        im = joinpath(C2_ROOT, ".agents", "bodies", "implementer.md")
        sk = joinpath(C2_ROOT, ".claude", "skills", "lane-lifecycle", "SKILL.md")
        @test isfile(tw) && isfile(im) && isfile(sk)   # precondition
        for p in (tw, im, sk)
            fs = c2_forms(p)
            @test !isempty(fs)
            @test any(f -> occursin("--trailer \"Co-Authored-By:", f), fs)   # the same final paragraph
            @test !occursin(r"-m \"TDD:", read(p, String))                   # never the -m "TDD: …" form
        end
        for (p, agent, who, ph, files) in ((tw, "test-writer", TB_TW, "red", Dict("test/c2f.jl" => "x\n")),
                (im, "implementer", TB_IMPL, "green", Dict("src/P.jl" => "module P\nf(x) = 5\nend\n")))
            fs = c2_forms(p)
            isempty(fs) && continue
            t = tb_topo(); L = t.lane
            tb_stage!(L, files)
            cmd = replace(c2_concrete(first(fs), L, ph), "ROLE" => agent)
            occursin("--author", cmd) || (cmd *= " --author \"$who\"")
            f = tb_flow(t, cmd; agent)
            @test f.pre.rc == 0                                  # the body's form passes tdd_boundary for its role
            @test f.ran && f.post !== nothing && f.post.rc == 0
            @test c2_git_tr(L, tb_head(L), "TDD") == ph
            @test !any(r -> get(r, "sha", "") == tb_head(L), tb_recs(t, "tdd-commit-violation"))
        end
    end
end
