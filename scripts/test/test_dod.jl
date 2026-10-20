@testset "dod.jl" begin
    risk = TOML.parsefile(joinpath(ROOT, "risk.toml"))
    ev(changed, labels = String[], text = "") = DoD.evaluate(risk, String.(changed), labels, text)
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
        kept = ["src/A.jl"]
    )
    @test failed(res) == ["tests", "changelog"]
    # default_tier = "T0" is honoured
    r0 = deepcopy(risk); r0["default_tier"] = "T0"
    @test first(DoD.evaluate(r0, ["docs/x.md"], String[], "")) == "T0"

    @testset "changelog fragments (0.2.4)" begin
        plan = "docs/superpowers/plans/x.md"
        frag(changed; kw...) = failed(last(DoD.evaluate(risk, String.(changed), ["T1"], plan; kw...)))
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
                "risk.toml" => read(joinpath(ROOT, "risk.toml"), String), "src/A.jl" => "x\n",
                "changelog.d/old.md" => "- old\n"
            )
        )
        sh(`git -C $d checkout -q -b feat/f`)
        commit!(
            d, Dict("src/A.jl" => "y\n", "test/a.jl" => "t\n", "changelog.d/old.md" => "- edited\n"),
            "feat: A\n\nPlan: docs/superpowers/plans/2026-10-19-a.md"
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

    @testset "CLI on a real branch" begin
        d = tmp_repo(Dict("risk.toml" => read(joinpath(ROOT, "risk.toml"), String), "src/A.jl" => "x\n"))
        sh(`git -C $d checkout -q -b feat/x`)
        commit!(d, Dict("src/A.jl" => "y\n"), "feat: change A")
        rc, out = capture(() -> DoD.main(["--root", d, "--base", "main"]))
        @test rc == 1 && occursin("NOT DONE", out) && fails(out) == ["ref", "tests", "changelog"]
        commit!(
            d, Dict("test/a.jl" => "t\n", "CHANGELOG.md" => "- A\n"),
            "test: cover A\n\nPlan: docs/superpowers/plans/2026-10-19-a.md"
        )
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
end
