@testset "check_docs.jl" begin
    d = mktempdir()
    mkpath(joinpath(d, "scripts")); write(joinpath(d, "scripts/real.jl"), "")
    mkpath(joinpath(d, "docs")); write(joinpath(d, "docs/a.md"), "")
    text = """
    See [a](a.md), [web](https://x.org), [anchor](#top), [gone](missing.md).
    Run `julia scripts/real.jl --check` and `scripts/ghost.jl:12`, not `docs/<name>.md`.
    Plain `text` and `src/*.jl` are ignored.
    """
    bad = CheckDocs.stale(d, "docs/index.md", text)
    @test [b[2] for b in bad] == ["missing.md", "scripts/ghost.jl"]
    @test isempty(CheckDocs.stale(d, "docs/index.md", "`docs/agent/X.md`"; external = Set(["docs/agent/X.md"])))

    @testset "external globs, fenced blocks" begin
        ext = Set(["docs/agent/*", "test/*"])
        @test isempty(CheckDocs.stale(d, "x.md", "`docs/agent/BRIEF.md` and `test/contracts/` and `test/`"; external = ext))
        @test [b[2] for b in CheckDocs.stale(d, "x.md", "`docs/agentX.md`"; external = ext)] == ["docs/agentX.md"]
        fenced = "before `scripts/ghost1.jl`\n```sh\njulia scripts/ghost2.jl\n`scripts/ghost3.jl`\n```\n" *
            "~~~~\n`scripts/ghost4.jl`\n~~~\nstill fenced `scripts/ghost5.jl`\n~~~~\nafter `scripts/ghost6.jl`\n"
        @test [b[2] for b in CheckDocs.stale(d, "x.md", fenced; ignore_fenced = true)] == ["scripts/ghost1.jl", "scripts/ghost6.jl"]
        @test length(CheckDocs.stale(d, "x.md", fenced)) == 5      # off by default: backticked tokens inside fences count
        @test [b[1] for b in CheckDocs.stale(d, "x.md", fenced; ignore_fenced = true)] == [1, 11]   # line numbers kept
        indented = "  ```\n`scripts/in.jl`\n  ```\nafter `scripts/missing.jl`\n"            # an indented closing fence closes
        @test [b[2] for b in CheckDocs.stale(d, "x.md", indented; ignore_fenced = true)] == ["scripts/missing.jl"]
    end

    @testset ".agents/factory.toml [check_docs]: exclude, external, ignore_fenced" begin
        r = tmp_repo(
            Dict(
                "README.md" => "`scripts/gone.jl`\n", "research/notes.md" => "`scripts/ref.py`\n",
                "adr/0001-x.md" => "`src/Pkg.jl`\n", "adr/README.md" => "[x](0001-x.md) [y](0002-y.md)\n",
                "CLAUDE.md" => "`docs/agent/BRIEF.md`\n```\n`scripts/fenced.jl`\n```\n"
            )
        )
        rc, out = capture(() -> CheckDocs.main(["--root", r]))
        @test rc == 1 && occursin("6 stale", out)
        mkpath(joinpath(r, ".agents"))
        write(
            joinpath(r, ".agents/factory.toml"), """
            version = 1
            [check_docs]
            exclude = ["research/**", "adr/0*"]
            external = ["docs/agent/*"]
            ignore_fenced = true
            """
        )
        rc, out = capture(() -> CheckDocs.main(["--root", r]))
        # left: README's ghost (not excluded) and adr/README.md's dead link (the index is still checked)
        @test rc == 1 && occursin("2 stale", out) && occursin("README.md:1: missing `scripts/gone.jl`", out) &&
            occursin("0002-y.md", out) && occursin("2 excluded", out)
        @test !occursin("research/", out) && !occursin("fenced.jl", out) && !occursin("BRIEF", out)
        # --config reads another file (e.g. a profile's defaults) instead
        alt = joinpath(mktempdir(), "alt.toml")
        write(alt, "version = 1\n[check_docs]\nexclude = [\"*\"]\n")
        rc, out = capture(() -> CheckDocs.main(["--root", r, "--config", alt]))
        @test rc == 0 && occursin("OK (0 files", out)
        # a typo in the config is an error, not a silently disabled check
        write(joinpath(r, ".agents/factory.toml"), "version = 1\n[check_docs]\nexlude = []\n")
        @test capture(() -> CheckDocs.main(["--root", r]))[1] == 2
        for bad in ("exclude = \"research/*\"", "external = [1]", "ignore_fenced = \"yes\"")   # wrong types too
            write(joinpath(r, ".agents/factory.toml"), "version = 1\n[check_docs]\n$bad\n")
            @test capture(() -> CheckDocs.main(["--root", r]))[1] == 2
        end
    end

    @testset "a checkout holding the factory: factory/*.md name template paths" begin
        r = tmp_repo(
            Dict(
                "factory/MANIFEST.toml" => "version = 1\n", "factory/template/docs/adr/0000-t.md" => "x\n",
                "factory/README.md" => "`docs/adr/` and `docs/adr/0000-t.md` and [up](../adr/README.md)\n[link](../docs/adr/0000-t.md)\n",
                "README.md" => "`docs/adr/0000-t.md`\n", "adr/README.md" => "x\n",
                ".agents/factory.toml" => "version = 1\n[check_docs]\nexclude = [\"factory/template/**\"]\n"
            )
        )
        rc, out = capture(() -> CheckDocs.main(["--root", r]))
        # backticked template paths resolve in factory/README.md, not in the repo's own README.md;
        # a Markdown link is resolved relative to its file only (no second root)
        @test rc == 1 && occursin("2 stale", out) && occursin("  README.md:1: missing `docs/adr/0000-t.md`", out) &&
            occursin("factory/README.md:2: missing `../docs/adr/0000-t.md`", out) && !occursin("factory/README.md:1", out)
        rm(joinpath(r, "factory/MANIFEST.toml"))                       # not a factory: no second root
        @test occursin("4 stale", capture(() -> CheckDocs.main(["--root", r]))[2])
    end

    @testset "references to gitignored (machine-local) paths are not stale (0.2.5)" begin
        # a fresh clone lacks gitignored files; CI on bonmac/Chui failed on `.claude/hooks/read-only-roots.txt`
        r = tmp_repo(
            Dict(
                ".gitignore" => "/.claude/hooks/read-only-roots.txt\n/.lanes/\n/Manifest*.toml\n",
                "README.md" => "`.claude/hooks/read-only-roots.txt` `.lanes/evidence/` `scripts/gone.jl`\n" *
                    "[m](Manifest.toml) [g](scripts/ghost.jl)\n",
                "factory/MANIFEST.toml" => "version = 1\n", "factory/template/.gitignore" => "/scripts/local.txt\n",
                "factory/template/scripts/x.jl" => "",
                "factory/README.md" => "`scripts/local.txt` `.claude/hooks/read-only-roots.txt` `scripts/nope.jl`\n"
            )
        )
        @test !isfile(joinpath(r, ".claude/hooks/read-only-roots.txt"))       # as in a fresh clone
        rc, out = capture(() -> CheckDocs.main(["--root", r]))
        @test rc == 1 && occursin("3 stale", out) && occursin("README.md:1: missing `scripts/gone.jl`", out) &&
            occursin("README.md:2: missing `scripts/ghost.jl`", out) && occursin("factory/README.md:1: missing `scripts/nope.jl`", out)
        @test !occursin("read-only-roots", out) && !occursin("Manifest", out) && !occursin(".lanes", out)
        # the gitignore decides, not the file name: unignored, the same reference is stale again
        commit!(r, Dict(".gitignore" => "/.lanes/\n"))
        rc, out = capture(() -> CheckDocs.main(["--root", r]))
        @test rc == 1 && occursin("README.md:1: missing `.claude/hooks/read-only-roots.txt`", out)
        @test !CheckDocs.gitignored(mktempdir(), ".lanes")                    # not a git checkout: never ignored
        # only a tracked .gitignore counts: not a machine's excludes file, not a `!` match, not a tracked file
        excl = joinpath(mktempdir(), "excl"); write(excl, "scripts/gone.jl\n")
        sh(`git -C $r config core.excludesFile $excl`)
        commit!(r, Dict(".gitignore" => "*.cov\n!/keep.cov\n")); write(joinpath(r, "t.cov"), "x\n")
        sh(`git -C $r add -f -- t.cov`); sh(`git -C $r commit -q -m tracked-but-ignored`)
        rm(joinpath(r, "t.cov"))                                     # deleted, not yet committed
        @test CheckDocs.gitignored(r, "scripts/x.cov") && !CheckDocs.gitignored(r, "keep.cov")
        @test !CheckDocs.gitignored(r, "scripts/gone.jl") && !CheckDocs.gitignored(r, "t.cov")
        sh(`git -C $r rm -q --cached .gitignore`)                              # an untracked .gitignore: not CI's
        @test !CheckDocs.gitignored(r, "scripts/x.cov")
    end

    if IN_FACTORY
        # the template itself has no stale references (docs/agent/* are copied in by the lead).
        # Only here: in a vendored repo the repo-wide run is `ci.jl guards`'s own check_docs step,
        # under the repo's [check_docs] settings, so a doc edit never fails the unit tests.
        rc, out = capture(() -> CheckDocs.main(["--root", ROOT, "--external", "docs/agent/ECOSYSTEM.md,docs/agent/BRIEF.md,.factory-version"]))
        @test rc == 0 || (print(out); false)
        # the coordinator profile's seeded defaults parse and are what the lead expects
        cfg = CheckDocs.factory_config(joinpath(FACTORY, "profiles/coordinator"))
        @test issubset(["research/**", "reference/**", "prompts/**"], CheckDocs.config_list(cfg, "check_docs", "exclude"))
        @test cfg["check_docs"]["ignore_fenced"] === true
    end
end
