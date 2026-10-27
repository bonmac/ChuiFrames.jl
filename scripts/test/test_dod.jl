@testset "dod.jl" begin
    risk = TOML.parse(seed_fixture("risk.toml"))   # the package seed, whatever repo this is synced into (tw-032)
    # 0.3.0: a valid TDD lane (red by the test writer, green by the implementer), so `tdd` passes and
    # these cases test the other requirements; without `commits`, a src change fails `tdd` (review)
    okl = [
        DoD.LaneCommit("a"^40, "test-writer <test-writer@factory.invalid>", "red", nothing, ["test/a.jl"]),
        DoD.LaneCommit("b"^40, "implementer <implementer@factory.invalid>", "green", nothing, ["src/A.jl"]),
    ]
    ev(changed, labels = String[], text = "") = DoD.evaluate(risk, String.(changed), labels, text; commits = okl)
    failed(results) = [r[1] for r in results if r[2] == :fail]
    # 0.2.4: CLI tests assert WHICH requirement failed, so a broken fixture cannot pass for the wrong reason
    fails(out) = [m.captures[1] for m in eachmatch(r"\[FAIL\] (\S+)", out)]

    tier, res = ev(["docs/src/index.md"], ["T0"])
    @test tier == "T0" && isempty(failed(res))
    tier, res = ev([".github/workflows/CI.yml"], ["T0"])          # protected path beats the label
    @test tier == "T3" && "adr" in failed(res)
    @test any(r -> r[1] == "tier" && r[2] == :info, res)          # the raise is reported
    tier, res = ev(["src/A.jl", "CHANGELOG.md"], String[], "plan: docs/superpowers/plans/x.md")
    @test tier == "T1" && failed(res) == ["tests"]
    tier, res = ev(["src/A.jl", "test/a.jl", "CHANGELOG.md"], ["T1"], "docs/superpowers/plans/x.md")
    @test isempty(failed(res))
    tier, res = ev(["src/A.jl", "test/a.jl", "CHANGELOG.md"])
    @test failed(res) == ["ref"]
    tier, res = ev(["Project.toml", "CHANGELOG.md"], ["T1"], "docs/superpowers/plans/x.md")
    @test tier == "T2" && failed(res) == ["spec"]
    @test any(r -> r[1] == "tier" && r[2] == :info, res)          # label raised to T2 is reported
    spec = "docs/superpowers/specs/2026-10-19-x-design.md"
    tier, res = ev([".claude/hooks/x.sh", "CHANGELOG.md", "docs/adr/0003-hooks.md"], ["T3"], spec)
    @test tier == "T3" && isempty(failed(res))
    tier, res = ev([".claude/hooks/x.sh", "CHANGELOG.md"], ["T3"], spec * " per ADR-0001")
    @test isempty(failed(res))
    tier, res = ev([".claude/hooks/x.sh", "CHANGELOG.md", "docs/adr/0000-template.md"], ["T3"], spec)
    @test failed(res) == ["adr"]
    @test DoD.label_tier(["tier:T2", "docs"]) == "T2"
    # the ADR directory is a profile parameter (coordinator: adr/)
    t3(files; dir) = failed(last(DoD.evaluate(risk, [".claude/hooks/x.sh", "CHANGELOG.md", files...], ["T3"], spec; adr_dir = dir)))
    @test t3(["adr/0012-hooks.md"]; dir = "adr") == String[]
    @test t3(["adr/0012-hooks.md"]; dir = "docs/adr") == ["adr"]
    @test t3(["docs/adr/0012-hooks.md"]; dir = "adr") == ["adr"]
    @test t3(["adr/0000-template.md"]; dir = "adr/") == ["adr"]
    @test t3(["adr/sub/0012-x.md"]; dir = "adr") == ["adr"]
    @test t3(["adrx/0012-x.md"]; dir = "adr") == ["adr"]
    # deleting the CHANGELOG or a test is not evidence
    tier, res = DoD.evaluate(
        risk, ["src/A.jl", "test/a.jl", "CHANGELOG.md"], ["T1"], "docs/superpowers/plans/x.md";
        kept = ["src/A.jl"], commits = okl
    )
    @test failed(res) == ["tests", "changelog"]
    # default_tier = "T0" is honoured
    r0 = deepcopy(risk); r0["default_tier"] = "T0"
    @test first(DoD.evaluate(r0, ["docs/x.md"], String[], "")) == "T0"

    @testset "changelog fragments (0.2.4)" begin
        plan = "docs/superpowers/plans/x.md"
        frag(changed; kw...) = failed(last(DoD.evaluate(risk, String.(changed), ["T1"], plan; commits = okl, kw...)))
        @test frag(["src/A.jl", "test/a.jl", "changelog.d/lane-a.md"]) == String[]
        @test frag(["src/A.jl", "test/a.jl", "changelog.d/lane-a.md"]; added = ["test/a.jl"]) == ["changelog"]  # modified, not new
        @test frag(["src/A.jl", "test/a.jl", "changelog.d/sub/x.md"]) == ["changelog"]
        @test frag(["src/A.jl", "test/a.jl", "changelog.d/README.md"]) == ["changelog"]
        @test frag(["src/A.jl", "test/a.jl", "changelog.d/.gitkeep"]) == ["changelog"]
        @test frag(["src/A.jl", "test/a.jl", "changelog.d/x.txt"]) == ["changelog"]
        @test frag(["src/A.jl", "test/a.jl", "changelog.d/.mine.md"]) == ["changelog"]   # the review: fold never sees it
        @test frag(["src/A.jl", "test/a.jl", "changelog.d/x.md"]; kept = ["src/A.jl", "test/a.jl"], added = String[]) == ["changelog"]
        @test frag(["src/A.jl", "test/a.jl", "CHANGELOG.md"]) == String[]      # the CHANGELOG.md path still works
        d = tmp_repo(
            Dict(
                "risk.toml" => seed_fixture("risk.toml"), "src/A.jl" => "x\n",
                "changelog.d/old.md" => "- old\n"
            )
        )
        sh(`git -C $d checkout -q -b feat/f`)
        # 0.3.0: a valid TDD lane (red by the test writer, green by the implementer), so `tdd` passes
        tc!(files, author, msg) = (commit!(d, files, msg); sh(`git -C $d commit -q --amend --no-edit --author=$author`))
        tc!(Dict("test/a.jl" => "t\n"), "test-writer <test-writer@factory.invalid>", "test: A red\n\nTDD: red")
        tc!(
            Dict("src/A.jl" => "y\n", "changelog.d/old.md" => "- edited\n"), "implementer <implementer@factory.invalid>",
            "feat: A\n\nPlan: docs/superpowers/plans/2026-10-19-a.md\nTDD: green"
        )
        rc, out = capture(() -> DoD.main(["--root", d, "--base", "main"]))
        @test rc == 1 && fails(out) == ["changelog"]                           # editing an old fragment is not evidence
        commit!(d, Dict("changelog.d/empty.md" => "  \n"), "docs: empty fragment")   # the review: an empty one is no entry
        rc, out = capture(() -> DoD.main(["--root", d, "--base", "main"]))
        @test rc == 1 && fails(out) == ["changelog"]
        commit!(d, Dict("changelog.d/lane-f.md" => "- feat: A\n"), "docs: fragment")
        rc, out = capture(() -> DoD.main(["--root", d, "--base", "main"]))
        @test rc == 0 && occursin(r"\[PASS\] changelog +changelog fragment changelog\.d/lane-f\.md added", out)
    end

    # 0.3.0 (cl-headings): `changelog.jl fold` refuses a fragment holding a Markdown heading, so dod
    # must not accept one as evidence (ChuiFrames had 14 such fragments, the coordinator 5)
    @testset "a fragment with a heading fails changelog (0.3.0)" begin
        d = tmp_repo(Dict("risk.toml" => seed_fixture("risk.toml"), "docs/x.md" => "x\n"))
        sh(`git -C $d checkout -q -b feat/h`)
        commit!(
            d, Dict("docs/x.md" => "y\n", "changelog.d/lane-h.md" => "### Added\n\n- feat: X\n"),
            "docs: X\n\nPlan: docs/superpowers/plans/2026-10-27-h.md"
        )
        rc, out = capture(() -> DoD.main(["--root", d, "--base", "main"]))
        @test rc == 1 && fails(out) == ["changelog"] || (print(out); false)
        @test occursin(r"\[FAIL\] changelog +changelog\.d/lane-h\.md contains a Markdown heading.*changelog\.jl fold", out) ||
            (print(out); false)
        commit!(d, Dict("CHANGELOG.md" => "- X\n"), "docs: CHANGELOG")   # the fold still breaks: still a fail
        rc, out = capture(() -> DoD.main(["--root", d, "--base", "main"]))
        @test rc == 1 && fails(out) == ["changelog"] || (print(out); false)
        commit!(d, Dict("changelog.d/lane-h.md" => "- **Added:**\n  - feat: X (# not a heading)\n"), "docs: list items")
        rc, out = capture(() -> DoD.main(["--root", d, "--base", "main"]))
        @test rc == 0 || (print(out); false)
        # dod duplicates changelog.jl's heading regex (no shared helper there): keep the two in step
        cl = read(joinpath(ROOT, "scripts", "changelog.jl"), String)
        @test isdefined(DoD, :FRAGMENT_HEADING) && occursin(DoD.FRAGMENT_HEADING.pattern, cl)
        @test isdefined(DoD, :FRAGMENT_HEADING) &&
            all(l -> occursin(DoD.FRAGMENT_HEADING, l), ["# A", "### Added", "   ## x", "##"]) &&
            !any(l -> occursin(DoD.FRAGMENT_HEADING, l), ["- # x", "    # code", "#tag", "- feat"])
    end

    # 0.3.0 (tw-031): the fold reads every fragment in changelog.d/, so a fragment already on the base
    # that the lane edits to hold a heading breaks the fold just as an added one does
    @testset "changelog fails on a MODIFIED fragment that now holds a heading" begin
        d = tmp_repo(
            Dict(
                "risk.toml" => seed_fixture("risk.toml"), "docs/x.md" => "x\n",
                "changelog.d/old.md" => "- old\n"
            )
        )
        sh(`git -C $d checkout -q -b feat/m`)
        commit!(
            d, Dict(
                "docs/x.md" => "y\n", "changelog.d/lane-m.md" => "- feat: X\n",
                "changelog.d/old.md" => "## Changed\n\n- old, edited\n"
            ),
            "docs: X\n\nPlan: docs/superpowers/plans/2026-10-27-m.md"
        )
        rc, out = capture(() -> DoD.main(["--root", d, "--base", "main"]))
        @test rc == 1 && fails(out) == ["changelog"] || (print(out); false)
        @test occursin(r"\[FAIL\] changelog +changelog\.d/old\.md contains a Markdown heading.*changelog\.jl fold", out) ||
            (print(out); false)
    end

    @testset "changelog passes on a modified fragment with list items only" begin
        d = tmp_repo(
            Dict(
                "risk.toml" => seed_fixture("risk.toml"), "docs/x.md" => "x\n",
                "changelog.d/old.md" => "- old\n"
            )
        )
        sh(`git -C $d checkout -q -b feat/n`)
        commit!(
            d, Dict(
                "docs/x.md" => "y\n", "changelog.d/lane-n.md" => "- feat: X\n",
                "changelog.d/old.md" => "- **Changed:**\n  - old, edited (# not a heading)\n"
            ),
            "docs: X\n\nPlan: docs/superpowers/plans/2026-10-27-n.md"
        )
        rc, out = capture(() -> DoD.main(["--root", d, "--base", "main"]))
        @test rc == 0 || (print(out); false)
    end

    @testset "CLI on a real branch" begin
        d = tmp_repo(Dict("risk.toml" => seed_fixture("risk.toml"), "src/A.jl" => "x\n"))
        sh(`git -C $d checkout -q -b feat/x`)
        # 0.3.0: a valid TDD lane, so `tdd` passes: the red is empty (no test/ yet, so `tests` still fails),
        # the green changes A, and the tests come as a backfill (no order rule; the test writer's phase)
        TW, IMPL = "test-writer <test-writer@factory.invalid>", "implementer <implementer@factory.invalid>"
        red = "test: A red\n\nTDD: red"
        sh(`git -C $d commit -q --allow-empty --author=$TW -m $red`)
        commit!(d, Dict("src/A.jl" => "y\n"), "feat: change A\n\nTDD: green")
        sh(`git -C $d commit -q --amend --no-edit --author=$IMPL`)
        rc, out = capture(() -> DoD.main(["--root", d, "--base", "main"]))
        @test rc == 1 && occursin("NOT DONE", out) && fails(out) == ["ref", "tests", "changelog"]
        commit!(
            d, Dict("test/a.jl" => "t\n", "CHANGELOG.md" => "- A\n"),
            "test: cover A\n\nPlan: docs/superpowers/plans/2026-10-19-a.md\nTDD: backfill"
        )
        sh(`git -C $d commit -q --amend --no-edit --author=$TW`)
        rc, out = capture(() -> DoD.main(["--root", d, "--base", "main"]))
        @test rc == 0 && occursin("dod.jl: DONE", out) && isempty(fails(out))
        @test capture(() -> DoD.main(["--root", d, "--base", "nope"]))[1] == 2
        # 0.2.7 (factory-027 item 4): no remote here, so origin/main does not resolve: the local main stands in
        rc, out = capture(() -> DoD.main(["--root", d, "--base", "origin/main"]))
        @test rc == 0 && occursin("dod.jl: DONE", out) || (print(out); false)   # 0.2.6: rc 2, "no merge base"
        @test occursin("dod.jl: note: `origin/main` does not resolve here", out)   # review S1: the fallback is visible
        @test capture(() -> DoD.main(["--root", d, "--base", "origin/nope"]))[1] == 2
        # moving a protected file out of its path still counts as touching it (T3)
        mkpath(joinpath(d, ".claude/hooks")); commit!(d, Dict(".claude/hooks/g.sh" => "x\n"), "add hook")
        sh(`git -C $d checkout -q main`); sh(`git -C $d merge -q --ff-only feat/x`)
        sh(`git -C $d checkout -q -b feat/mv`)
        mkpath(joinpath(d, "tools")); sh(`git -C $d mv .claude/hooks/g.sh tools/g.sh`); sh(`git -C $d commit -q -m mv`)
        rc, out = capture(() -> DoD.main(["--root", d, "--base", "main", "--labels", "T1"]))
        @test rc == 1 && occursin("tier T3", out) && fails(out) == ["spec", "changelog", "adr"]
        # adr_dir comes from .factory-version (written by sync_factory.jl), or --adr-dir
        @test DoD.adr_dir(d) == "docs/adr"
        commit!(
            d, Dict("adr/0012-move.md" => "# ADR\n", "CHANGELOG.md" => "- mv\n"),
            "chore: move hook\n\nSpec: docs/superpowers/specs/2026-10-19-mv-design.md"
        )
        rc, out = capture(() -> DoD.main(["--root", d, "--base", "main", "--labels", "T3"]))
        @test rc == 1 && fails(out) == ["adr"]
        rc, out = capture(() -> DoD.main(["--root", d, "--base", "main", "--labels", "T3", "--adr-dir", "adr"]))
        @test rc == 0 || (print(out); false)
        write(joinpath(d, ".factory-version"), "profile = \"coordinator\"\nadr_dir = \"adr\"\n")
        @test DoD.adr_dir(d) == "adr"
        rc, out = capture(() -> DoD.main(["--root", d, "--base", "main", "--labels", "T3"]))
        @test rc == 0 || (print(out); false)
        write(joinpath(d, ".factory-version"), "not = [toml")                 # --adr-dir works even then
        rc, out = capture(() -> DoD.main(["--root", d, "--base", "main", "--labels", "T3", "--adr-dir", "adr"]))
        @test rc == 0 || (print(out); false)
    end

    # ---- requirement `tdd` (factory 0.3.0, plan Task 7; spec §0.5, §4.2, §4.4, §6) ----
    # Representation choices (the test writer's, from the spec and the Task 5 header):
    # - dod.jl's `module DoD` includes _tdd_history.jl (top-level definitions, no module of its own),
    #   so a test reaches `DoD.LaneCommit` and `DoD.history_rules`. While either is missing each named
    #   testset fails on `@test` instead of erroring the suite.
    # - `LaneCommit(sha, author, phase, mode, paths)` positional; `mode` is (mode, reason) or nothing.
    # - `evaluate(risk, changed, labels, text; commits, stub_ok)`: pure. `commits` is a Vector of
    #   LaneCommit (oldest first), `stub_ok(sha)::Bool` is passed through to `history_rules`.
    # - The evaluate tests use a minimal risk whose T1 requires only ["tdd"], so they test the
    #   requirement alone; the seeded risk.toml is checked by its own testset.
    # - Result row ("tdd", :pass, "no src/ext change" | "tdd history OK (N commits, mode M)") or
    #   ("tdd", :fail, <first history_rules string>), which starts with its rule id ("H2 ...").
    @testset "tdd requirement (0.3.0)" begin
        dt_ready() = isdefined(DoD, :LaneCommit) && isdefined(DoD, :history_rules)
        dt_testset(f, name) = @testset "$name" begin
            dt_ready() ? f() : @test dt_ready()   # RED: dod.jl does not include _tdd_history.jl yet
        end
        DT_TW = "test-writer <test-writer@factory.invalid>"
        DT_IMPL = "implementer <implementer@factory.invalid>"
        DT_LEAD = "lead <lead@factory.invalid>"
        DT_GP = "general-purpose <general-purpose@factory.invalid>"
        DT_USER = "Machine User <user@example.com>"           # the machine's own git identity
        seq = Ref(0)
        dc(author, phase, paths...; mode = nothing) =
            DoD.LaneCommit(string(seq[] += 1; base = 16, pad = 40), author, phase, mode, String[paths...])
        rk = Dict{String, Any}(
            "default_tier" => "T1", "protected" => Any[],
            "tiers" => Dict{String, Any}(t => Dict{String, Any}("requires" => (t == "T1" ? ["tdd"] : String[])) for t in DoD.TIERS)
        )
        "The `tdd` row of evaluate, or nothing when there is none."
        function tddrow(commits; changed = unique(reduce(vcat, [c.paths for c in commits]; init = String[])), stub_ok = _ -> true, risk = rk)
            _, res = DoD.evaluate(risk, String.(changed), ["T1"], ""; commits, stub_ok)
            i = findfirst(r -> r[1] == "tdd", res)
            return i === nothing ? nothing : res[i]
        end
        passed(r) = r !== nothing && r[2] == :pass
        failed_rule(r, ids...) = r !== nothing && r[2] == :fail && any(id -> occursin(Regex("^" * id * "(?![0-9])"), r[3]), ids)
        okmode(r, n, m) = passed(r) && occursin("tdd history OK ($n commits, mode $m)", r[3])

        dt_testset("tdd passes with no src change") do
            r = tddrow([dc(DT_USER, nothing, "docs/x.md"), dc(DT_USER, nothing, "README.md")])
            @test passed(r) && r[3] == "no src/ext change" || (@show r; false)
            r = tddrow(DoD.LaneCommit[]; changed = ["docs/x.md"])
            @test passed(r) && r[3] == "no src/ext change" || (@show r; false)
        end

        dt_testset("tdd passes on stub-red-green-refactor") do
            lane = [
                dc(DT_IMPL, "stub", "src/A.jl"), dc(DT_TW, "red", "test/a_tests.jl"),
                dc(DT_IMPL, "green", "src/A.jl", "changelog.d/a.md"), dc(DT_IMPL, "refactor", "src/A.jl"),
            ]
            asked = String[]
            r = tddrow(lane; stub_ok = s -> (push!(asked, s); true))
            @test okmode(r, 4, "required") || (@show r; false)
            @test asked == [lane[1].sha]                     # stub_ok is consulted for the stub only
            r = tddrow(lane; stub_ok = _ -> false)           # evaluate threads stub_ok through: H5
            @test failed_rule(r, "H5") || (@show r; false)
        end

        dt_testset("tdd fails on refactor-only required lane") do
            r = tddrow([dc(DT_IMPL, "refactor", "src/A.jl")])
            @test failed_rule(r, "H2", "H6") || (@show r; false)
        end

        dt_testset("tdd fails on green editing a test") do
            r = tddrow([dc(DT_TW, "red", "test/a_tests.jl"), dc(DT_IMPL, "green", "src/A.jl", "test/a_tests.jl")])
            @test failed_rule(r, "H3", "H4") || (@show r; false)
        end

        dt_testset("tdd reads mode from the lead-authored trailer") do
            ref = dc(DT_IMPL, "refactor", "src/A.jl")
            r = tddrow([dc(DT_LEAD, nothing; mode = ("refactor", "rename internals")), ref])
            @test okmode(r, 2, "refactor") || (@show r; false)
            r = tddrow([ref])                                # no trailer: mode required, H2/H6 fail
            @test r !== nothing && r[2] == :fail
        end

        spike = () -> dc(DT_USER, nothing, "src/A.jl")       # a spike has no phases
        dt_testset("skip by a role-authored mode commit fails") do
            for role in (DT_IMPL, DT_TW)
                r = tddrow([dc(role, nothing; mode = ("skip", "spike")), spike()])
                @test r !== nothing && r[2] == :fail && occursin(r"^H\d", r[3]) || (@show r; false)
            end
        end

        dt_testset("skip by a general-purpose-authored mode commit fails") do
            for who in (DT_GP, DT_USER)
                r = tddrow([dc(who, nothing; mode = ("skip", "spike")), spike()])
                @test r !== nothing && r[2] == :fail && occursin(r"^H\d", r[3]) || (@show r; false)
            end
        end

        dt_testset("skip by lead <lead@factory.invalid> with reason passes") do
            r = tddrow([dc(DT_LEAD, nothing; mode = ("skip", "prototype of the join API")), spike()])
            @test okmode(r, 2, "skip") || (@show r; false)
            r = tddrow([dc(DT_LEAD, nothing; mode = ("skip", "")), spike()])   # no reason: H8
            @test failed_rule(r, "H8") || (@show r; false)
        end

        dt_testset("unknown requirement still fails") do
            r1 = deepcopy(rk); r1["tiers"]["T1"]["requires"] = ["tdd", "bogus"]
            _, res = DoD.evaluate(r1, ["docs/x.md"], ["T1"], ""; commits = DoD.LaneCommit[], stub_ok = _ -> true)
            @test ("bogus", :fail) in [(r[1], r[2]) for r in res]
            @test any(r -> r[1] == "bogus" && occursin("unknown requirement", r[3]), res)
            @test !any(r -> r[1] == "tdd" && occursin("unknown requirement", r[3]), res)
        end

        @testset "risk.toml requires tdd and protects the tdd scripts" begin
            # tw-032: the package seed (fixtures/seed/, equal to factory/template's seed) requires tdd;
            # the host repo's own risk.toml need not (a coordinator has no tdd tier, migration list)
            tdd_scripts = ("scripts/tdd.jl", "scripts/_tdd_classify.jl", "scripts/_tdd_history.jl", "scripts/_tdd_backfill.jl")
            seeded = TOML.parse(seed_fixture("risk.toml"))
            for t in ("T1", "T2", "T3")
                @test "tdd" in seeded["tiers"][t]["requires"] || (println("tier $t lacks tdd"); false)
            end
            @test !("tdd" in seeded["tiers"]["T0"]["requires"])
            for f in tdd_scripts
                @test DoD.path_tier(seeded, f) == "T3" || (println("$f is not T3"); false)
            end
            @test occursin(r"^#.*\btdd\b"m, seed_fixture("risk.toml"))   # the `requires` comment
            # every profile protects the tdd scripts: the host's own risk.toml, whichever it is
            host = TOML.parsefile(joinpath(ROOT, "risk.toml"))
            for f in tdd_scripts
                @test DoD.path_tier(host, f) == "T3" || (println("host: $f is not T3"); false)
            end
            if IN_FACTORY   # the fixtures are the template's seeds, byte for byte; the coordinator's has no tdd tier
                @test seed_fixture("risk.toml") == read(joinpath(ROOT, "risk.toml"), String)
                @test seed_fixture("runtests.jl") == read(joinpath(ROOT, "test", "runtests.jl"), String)
                coord = TOML.parsefile(joinpath(FACTORY, "profiles", "coordinator", "risk.toml"))
                @test !any(t -> "tdd" in t["requires"], values(coord["tiers"]))
                for f in tdd_scripts
                    @test DoD.path_tier(coord, f) == "T3" || (println("coordinator: $f is not T3"); false)
                end
            end
        end

        dt_testset("dod main checks tdd on a real branch") do
            d = tmp_repo(Dict("risk.toml" => seed_fixture("risk.toml"), "src/A.jl" => "x\n"))
            sh(`git -C $d checkout -q -b feat/t`)
            cm(files, author, msg) = (
                for (p, c) in files
                    mkpath(dirname(joinpath(d, p))); write(joinpath(d, p), c)
                end;
                sh(`git -C $d add -- .`); sh(`git -C $d commit -q --author=$author -m $msg`)
            )
            plan = "Plan: docs/superpowers/plans/2026-10-26-a.md"
            cm(Dict("test/a_tests.jl" => "t\n"), DT_TW, "test: A red\n\n$plan\nTDD: red")
            cm(Dict("src/A.jl" => "y\n", "changelog.d/a.md" => "- A\n"), DT_IMPL, "feat: A\n\nTDD: green")
            rc, out = capture(() -> DoD.main(["--root", d, "--base", "main", "--labels", "T1"]))
            @test rc == 0 && fails(out) == String[] || (print(out); false)
            @test occursin(r"\[PASS\] tdd +tdd history OK \(2 commits, mode required\)", out) || (print(out); false)
            cm(Dict("src/A.jl" => "z\n", "test/a_tests.jl" => "u\n"), DT_IMPL, "feat: more\n\nTDD: green")
            rc, out = capture(() -> DoD.main(["--root", d, "--base", "main", "--labels", "T1"]))
            @test rc == 1 && fails(out) == ["tdd"] || (print(out); false)
        end
    end
end
