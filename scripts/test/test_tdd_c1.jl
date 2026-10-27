# Critic C1 (factory 0.3.0, critic-030): the test-side roles are a class. Written red; the implementer
# does not edit it. Included by runtests.jl after test_tdd.jl (Tdd, lc/hr/th_* of test_tdd_history.jl,
# tj_* of test_tdd_cli.jl) and test_hooks_tdd.jl (tb_* of test_hooks_tdd.jl and test_hooks_tdd2.jl).
#
# Lead's ruling (the behaviour specified here):
# - test-writer, law-tester, property-tester and differential-tester may each author the phases
#   `red`, `test-fix`, `test-refactor` and `backfill`; H9 and the commit guard accept any of them for those
#   phases, each under its own role identity `<role> <<role>@factory.invalid>`. A phase-less commit by any of
#   these identities is H9, as for the test-writer; a lookalike identity (`law-tester <x@y>`) is not a role.
# - All four get the test-writer's boundary (§0.6: reads, writes under test/ minus the seeded runners, Bash
#   allowlist), keyed on agent_type. The commit guard's identity rules (§0.5): a role caller commits only as
#   itself (author-not-caller-role); any other caller, the lead included, never as a role
#   (role-identity-not-caller). The post hook checks a test-side role's phase (phase-not-role) and paths
#   (path-not-role) as the test-writer's.
# - Dispatch (§0.6): the lead alone dispatches a test-side role, with a tdd-brief header `role=<role>`
#   (`julia scripts/tdd.jl brief --role <role>`); each role reads its own brief `.lanes/briefs/<lane>/<role>-*`.
# - Bodies: the three tester bodies name their identity and `TDD: red`; test_writer.md no longer lists
#   law/property/differential items as "not yours" and points to the dedicated roles.
#
# Assumption: the post hook's violation `rule` names are those the test-writer gets today (phase-not-role,
# path-not-role); the Pre denial names the rule in parentheses, as tdeny prints it.

const C1_ROLES = ("law-tester", "property-tester", "differential-tester")
c1_id(r) = "$r <$r@factory.invalid>"
const C1_PATH = Dict("law-tester" => "test/laws/f_laws.jl", "property-tester" => "test/property/f_props.jl",
    "differential-tester" => "test/differential/f_diff.jl")

# ---- history rules (pure) ----
@testset "critic C1 history: test-side roles author test phases" begin
    H = (:LaneCommit, :history_rules)

    th_testset("critic reproducer passes with role identities", H...) do
        for r in C1_ROLES
            v = hr(lc(TW, "red", "test/f_tests.jl"), lc(c1_id(r), "red", C1_PATH[r]), lc(IMPL, "green", "src/f.jl"))
            isempty(v) || println("C1 $r: ", v)
            @test isempty(v)
        end
    end

    lanes(who, p) = Dict(
        "red" => (stub(), lc(who, "red", p), green()),
        "test-fix" => (stub(), red(), green(), lc(who, "test-fix", p), green()),
        "test-refactor" => (stub(), red(), green(), lc(who, "test-refactor", p)),
        "backfill" => (lc(who, "backfill", p),),
    )
    th_testset("each test-side role may author red, test-fix, test-refactor, backfill", H...) do
        for (ph, cs) in lanes(TW, "test/a_tests.jl")
            @test isempty(hr(cs...))   # control: the lane shape is valid for the test-writer
        end
        for r in C1_ROLES, (ph, cs) in lanes(c1_id(r), C1_PATH[r])
            v = hr(cs...)
            isempty(v) || println("C1 $r $ph: ", v)
            @test isempty(v)
        end
    end

    th_testset("test-side role authoring green, stub or refactor is H9", H...) do
        for r in (C1_ROLES..., "test-writer")
            R = c1_id(r)
            @test th_has(hr(stub(), red(), lc(R, "green", "src/A.jl")), "H9")
            @test th_has(hr(lc(R, "stub", "src/A.jl"), red(), green()), "H9")
            @test th_has(hr(stub(), red(), green(), lc(R, "refactor", "src/A.jl")), "H9")
        end
    end

    th_testset("lookalike identity authoring red is still H9", H...) do
        for who in ("law-tester <x@y>", "property-tester <x@y>", "Differential Tester <dt@example.com>",
                "law-tester <property-tester@factory.invalid>", OTHER)
            @test th_has(hr(stub(), lc(who, "red", "test/laws/f_laws.jl"), green()), "H9")
        end
    end

    th_testset("phase-less commit by a test-side role identity is H9", H...) do
        for r in C1_ROLES
            @test th_has(hr(lc(c1_id(r), nothing, "docs/x.md")), "H9")
            @test th_has(hr(good_lane()..., lc(c1_id(r), nothing, C1_PATH[r])), "H9")
        end
    end

    th_testset("H4 accepts test/** in a test-side role's phase", H...) do
        for r in C1_ROLES, ph in ("red", "test-fix", "test-refactor", "backfill")
            cs = lanes(c1_id(r), C1_PATH[r])[ph]
            v = hr(cs...)
            @test !th_has(v, "H4")
        end
    end
end

# ---- hooks: boundary, commit guard, post hook ----
"A post-hook payload for call `tu` (command `c`, caller `agent`), run alone."
c1_post(t, c, tu; agent, cwd = t.lane) = tb_run(t, tb_bash(c; agent, cwd, tu, event = "PostToolUse",
    extra = Dict("tool_response" => Dict("stdout" => "", "stderr" => ""))); name = "tdd_commit_post.sh")
"A commit command with the phase as a --trailer."
c1_cm(d, who; phase = "red") = "git -C $d commit -q -m \"test: f\" --trailer \"TDD: $phase\" --author \"$who\""
"Denied with the rule `rule` named in the message?"
c1_rule(t, p, rule) = (r = tb_run(t, p); (r.rc == 2 && occursin("($rule)", r.err)) || (println("not denied ($rule), rc $(r.rc): $p\n  $(r.err)"); false))

@testset "critic C1 hooks: test-side roles get the test-writer boundary" begin
    t = tb_topo()
    L, P = t.lane, t.pkg
    for r in C1_ROLES
        @testset "$r reads: src denied, test/ allowed" begin
            @test tb_no(t, tb_read("$L/src/P.jl"; agent = r))
            @test tb_no(t, tb_read("$L/ext/PExt.jl"; agent = r))
            @test tb_no(t, tb_read("$L/test/lnk/P.jl"; agent = r))
            @test tb_no(t, tb_pay("Grep", Dict{String, Any}("pattern" => "f", "path" => "$L/src"); agent = r))
            @test tb_no(t, tb_read("$(t.S)/HANDOFF.md"; agent = r))
            @test any(x -> get(x, "agent_type", "") == r && get(x, "tool", "") == "Read", tb_recs(t, "tdd-boundary-denied"))
            @test tb_ok(t, tb_read("$L/test/t.jl"; agent = r))
        end
        @testset "$r writes: only test/** without the seeded runners" begin
            @test tb_no(t, tb_write("$L/src/P.jl"; agent = r))
            @test tb_no(t, tb_write("$L/docs/src/index.md"; tool = "Edit", agent = r))
            @test tb_no(t, tb_write("$L/test/runtests.jl"; agent = r))
            @test tb_no(t, tb_write("$L/test/Project.toml"; tool = "Edit", agent = r))
            @test tb_ok(t, tb_write("$L/$(C1_PATH[r])"; agent = r))
        end
        @testset "$r Bash: the test-writer allowlist" begin
            for c in ("cat src/P.jl", "julia -e 1", "sh -c 'cat src/P.jl'", "git log", "git show HEAD", "grep -r f src")
                @test tb_no(t, tb_bash(c; agent = r, cwd = L))
            end
            for c in ("git status", "cd $L && julia scripts/tdd.jl red", "ls test", "git diff -- test/")
                @test tb_ok(t, tb_bash(c; agent = r, cwd = L))
            end
        end
        @testset "$r reads its own brief only" begin
            tb_write!(P, Dict(".lanes/briefs/lane1/$r-1.md" => "b\n", ".lanes/briefs/lane1/implementer-1.md" => "i\n"))
            @test tb_ok(t, tb_read("$P/.lanes/briefs/lane1/$r-1.md"; agent = r))
            @test tb_no(t, tb_read("$P/.lanes/briefs/lane1/implementer-1.md"; agent = r))
        end
    end
end

@testset "critic C1 commit guard and post hook: test-side roles" begin
    for r in C1_ROLES
        R = c1_id(r)
        @testset "$r commits as itself with TDD: red" begin
            t = tb_topo(); L = t.lane
            tb_write!(L, Dict(C1_PATH[r] => "x\n"))
            f = tb_flow(t, "cd $L && git add $(C1_PATH[r]) && " * c1_cm(L, R); agent = r)
            sha = tb_head(L)
            @test f.pre.rc == 0 && f.ran
            @test f.post !== nothing && f.post.rc == 0
            @test any(x -> get(x, "sha", "") == sha && get(x, "agent_type", "") == r, tb_recs(t, "tdd-commit"))
            @test !any(x -> get(x, "sha", "") == sha, tb_recs(t, "tdd-commit-violation"))
        end
        @testset "$r committing as the test-writer denied (author-not-caller-role)" begin
            t = tb_topo(); L = t.lane
            tb_stage!(L, Dict(C1_PATH[r] => "x\n"))
            @test c1_rule(t, tb_bash(c1_cm(L, TB_TW); agent = r, cwd = L), "author-not-caller-role")
            @test c1_rule(t, tb_bash(c1_cm(L, c1_id(r == "law-tester" ? "property-tester" : "law-tester")); agent = r, cwd = L), "author-not-caller-role")
            @test c1_rule(t, tb_bash("git -C $L commit -q -m \"test: f\" --trailer \"TDD: red\""; agent = r, cwd = L), "author-not-caller-role")   # caller identity `test`
            @test tb_ok(t, tb_bash(c1_cm(L, TB_TW); cwd = L))   # control: the test-writer itself
        end
        @testset "lead committing with the $r identity denied (role-identity-not-caller)" begin
            t = tb_topo(); L = t.lane
            tb_stage!(L, Dict("docs/n.md" => "n\n"))
            @test c1_rule(t, tb_bash("git -C $L commit -q -m \"docs: n\" --author \"$R\""; agent = nothing, cwd = L), "role-identity-not-caller")
            @test c1_rule(t, tb_bash("GIT_AUTHOR_NAME=$r GIT_AUTHOR_EMAIL=$r@factory.invalid git -C $L commit -q -m x"; agent = nothing, cwd = L), "role-identity-not-caller")
            @test c1_rule(t, tb_bash("git -C $L commit -q -m x --author \"$R\""; agent = "general-purpose", cwd = L), "role-identity-not-caller")
            @test tb_ok(t, tb_bash("git -C $L commit -q -m \"docs: n\" --author \"$TB_LEAD\""; agent = nothing, cwd = L))   # control
        end
        @testset "$r commit with staged src or a seeded runner denied (staged-path)" begin
            t = tb_topo(); L = t.lane
            tb_stage!(L, Dict(C1_PATH[r] => "x\n", "src/P.jl" => "module P\nf(x) = 3\nend\n"))
            @test c1_rule(t, tb_bash(c1_cm(L, R); agent = r, cwd = L), "staged-path")
            tb_git(L, "reset", "-q")
            tb_stage!(L, Dict("test/runtests.jl" => "using Test # x\n"))
            @test c1_rule(t, tb_bash(c1_cm(L, R); agent = r, cwd = L), "staged-path")
        end
        @testset "$r post hook: TDD: green and a src path are violations" begin
            t = tb_topo(); L = t.lane
            c, tu = c1_cm(L, R), tb_tu()
            @test tb_run(t, tb_bash(c; agent = r, cwd = L, tu)).rc == 0   # Pre: nothing staged, nothing wrong
            tb_commit_as!(L, R, Dict(C1_PATH[r] => "y\n"), "test: f", "TDD: green")
            sha = tb_head(L)
            post = c1_post(t, c, tu; agent = r)
            @test post.rc == 2 && occursin("violation", post.err)
            @test any(x -> get(x, "sha", "") == sha && get(x, "agent_type", "") == r && get(x, "rule", "") == "phase-not-role",
                tb_recs(t, "tdd-commit-violation"))

            c2, tu2 = c1_cm(L, R), tb_tu()
            @test tb_run(t, tb_bash(c2; agent = r, cwd = L, tu = tu2)).rc == 0
            tb_commit_as!(L, R, Dict("src/P.jl" => "module P\nf(x) = 5\nend\n"), "test: f", "TDD: red")   # staged after Pre
            sha2 = tb_head(L)
            post2 = c1_post(t, c2, tu2; agent = r)
            @test post2.rc == 2
            @test any(x -> get(x, "sha", "") == sha2 && get(x, "agent_type", "") == r && get(x, "rule", "") == "path-not-role",
                tb_recs(t, "tdd-commit-violation"))
        end
    end
end

# ---- dispatch and the brief ----
c1_brief(role, co, head; lane = "lane1", mark = "marker-$(tb_tu())") = "<!-- tdd-brief role=$role lane=$lane checkout=$co head=$head -->\n## Task\n$mark\n"
c1_disp(sub, prompt; agent = nothing, tool = "Agent") = tb_pay(tool, Dict{String, Any}("subagent_type" => sub, "prompt" => prompt, "description" => "d"); agent)
c1_saved(main, mark) = (d = joinpath(main, ".lanes", "briefs", "lane1", "dispatched"); isdir(d) && any(f -> isfile(joinpath(d, f)) && occursin(mark, read(joinpath(d, f), String)), readdir(d)))

@testset "critic C1 dispatch: test-side roles are the lead's, with a tdd-brief" begin
    for r in C1_ROLES
        @testset "$r dispatch needs the lead and a current tdd-brief" begin
            t = tb_topo(); L = t.lane
            @test tb_no(t, c1_disp(r, "## Task\nno header\n"))                                          # the lead, no header
            @test tb_no(t, c1_disp(r, c1_brief(r, L, tb_head(L)); agent = "general-purpose"))            # a sub-lead
            @test tb_no(t, c1_disp(r, c1_brief(r, L, tb_head(L)); agent = "test-writer", tool = "Task"))
            @test tb_no(t, c1_disp(r, c1_brief("test-writer", L, tb_head(L))))                          # role mismatch
            @test tb_no(t, c1_disp("test-writer", c1_brief(r, L, tb_head(L))))
            m = "marker-c1-$r"
            @test tb_ok(t, c1_disp(r, c1_brief(r, L, tb_head(L); mark = m)))
            @test c1_saved(t.pkg, m)
        end
    end
    tj_testset("tdd.jl brief accepts the test-side roles") do
        for r in C1_ROLES
            name = "c1-brief-$r"
            d = tj_lane(name)
            tj_stub!(d)
            code, out = tj_call(tj_mod().brief, d; role = r)
            hdr = "<!-- tdd-brief role=$r lane=$name checkout=$(abspath(d)) head=$(tj_head(d)) -->"
            @test first(split(out, '\n')) == hdr
            saved = joinpath(tj_repo(), ".lanes", "briefs", name, "$r-1.md")
            @test isfile(saved) && first(split(read(saved, String), '\n')) == hdr
            @test code == 0 || (VERSION < v"1.11" && code != 2)
        end
    end
end

# ---- bodies ----
@testset "critic C1 bodies: test-side roles in a test-first lane" begin
    body(n) = (p = joinpath(ROOT, ".agents", "bodies", n); isfile(p) ? read(p, String) : "")
    for (r, f) in zip(C1_ROLES, ("law_tester.md", "property_tester.md", "differential_tester.md"))
        b = body(f)
        @test occursin(c1_id(r), b)
        @test occursin("TDD: red", b) && occursin("test-first lane", b)
    end
    tw = body("test_writer.md")
    @test !isempty(tw)
    @test !occursin("not yours: `test/laws/**`", tw)
    @test !occursin(r"not yours[^\n]*`:laws`"i, tw)
    @test all(r -> occursin(r, tw), C1_ROLES)   # points to the dedicated roles
end
