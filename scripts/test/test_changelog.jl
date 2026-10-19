@testset "changelog.jl (0.2.4)" begin
    cl = "# Changelog\n\nIntro.\n\n## Unreleased\n\n- old entry\n\n## 0.1.0 (2026-01-01)\n\n- first\n"
    @test Changelog.fold_text(cl, ["- a\n", "- b\n  more\n"]) ==
        "# Changelog\n\nIntro.\n\n## Unreleased\n\n- old entry\n- a\n- b\n  more\n\n## 0.1.0 (2026-01-01)\n\n- first\n"
    @test Changelog.fold_text("# C\n\n## 0.1.0\n\n- x\n", ["- a"]) == "# C\n\n## Unreleased\n\n- a\n\n## 0.1.0\n\n- x\n"
    @test Changelog.fold_text("# C\n\nIntro.\n", ["- a"]) == "# C\n\nIntro.\n\n## Unreleased\n\n- a\n"
    @test Changelog.fold_text("# C\n\n## Unreleased\n", ["- a"]) == "# C\n\n## Unreleased\n\n- a\n"
    @test Changelog.fold_text("# C\n\n## [Unreleased]\n\n- x\n", ["- a"]) == "# C\n\n## [Unreleased]\n\n- x\n- a\n"   # the review
    pr(t) = (q = mktempdir(); mkpath(joinpath(q, "changelog.d")); write(joinpath(q, "changelog.d/f.md"), t); Changelog.problems(q, ["changelog.d/f.md"]))
    @test !isempty(pr("   ## indented heading\n")) && isempty(pr("- #12 fixed the parser\n#12 is an issue number\n"))

    d = tmp_repo(Dict("CHANGELOG.md" => cl, "changelog.d/.gitkeep" => "", "changelog.d/README.md" => "# how\n"))
    cmd(args...) = capture(() -> Changelog.main([args..., "--root", d]))
    @test cmd("fold") == (0, "changelog.jl: no fragments to fold\n")
    write(joinpath(d, "changelog.d/lane-b.md"), "- feat: B\n")
    write(joinpath(d, "changelog.d/lane-a.md"), "- fix: A\n")
    rc, out = cmd("list")
    @test rc == 0 && occursin("changelog.d/lane-a.md\nchangelog.d/lane-b.md\n", out)
    rc, out = cmd("fold", "--dry-run")
    @test rc == 0 && occursin("- old entry\n- fix: A\n- feat: B\n", out) && isfile(joinpath(d, "changelog.d/lane-a.md"))
    write(joinpath(d, "changelog.d/lane-c.md"), "## heading\n")              # a bad fragment: nothing is written
    rc, out = cmd("fold")
    @test rc == 1 && occursin("lane-c.md contains a Markdown heading", out) && read(joinpath(d, "CHANGELOG.md"), String) == cl
    write(joinpath(d, "changelog.d/lane-c.md"), "  \n")
    @test cmd("fold")[1] == 1
    rm(joinpath(d, "changelog.d/lane-c.md"))
    rc, out = cmd("fold")
    @test rc == 0 && occursin("folded 2 fragment(s)", out)
    @test occursin("## Unreleased\n\n- old entry\n- fix: A\n- feat: B\n\n## 0.1.0", read(joinpath(d, "CHANGELOG.md"), String))
    @test sort(readdir(joinpath(d, "changelog.d"))) == [".gitkeep", "README.md"]   # fragments deleted, the rest kept
    @test cmd("nope")[1] == 2
    @test capture(() -> Changelog.main(["fold", "--root", mktempdir()]))[1] == 2  # no CHANGELOG.md
    if IN_FACTORY
        @test isfile(joinpath(ROOT, "changelog.d/.gitkeep"))
        @test "changelog.d/.gitkeep" in TOML.parsefile(joinpath(FACTORY, "MANIFEST.toml"))["seeded"]["paths"]
    end
end
