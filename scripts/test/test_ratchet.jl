@testset "ratchet.jl" begin
    old = TOML.parse(
        """
        [coverage]\nfloor = 80.0\n[bench]\ntime_tolerance = 0.10
        [[size]]\nglob = "src/*.jl"\nmax_lines = 600\n"""
    )
    @test isempty(Ratchet.direction(old, old))
    up = deepcopy(old); up["coverage"]["floor"] = 85.0; up["size"][1]["max_lines"] = 500
    up["bench"]["time_tolerance"] = 0.05
    @test isempty(Ratchet.direction(old, up))                       # tightening is fine
    lo = deepcopy(old); lo["coverage"]["floor"] = 79.9
    @test occursin("coverage.floor lowered", only(Ratchet.direction(old, lo)))
    big = deepcopy(old); big["size"][1]["max_lines"] = 601
    @test occursin("raised", only(Ratchet.direction(old, big)))
    gone = deepcopy(old); gone["size"] = Any[]
    @test occursin("removed", only(Ratchet.direction(old, gone)))
    tol = deepcopy(old); tol["bench"]["time_tolerance"] = 0.2
    @test occursin("time_tolerance", only(Ratchet.direction(old, tol)))

    lcov = tempname()
    write(lcov, "SF:a.jl\nDA:1,1\nLF:10\nLH:8\nend_of_record\nSF:b.jl\nLF:10\nLH:2\nend_of_record\n")
    @test Ratchet.lcov_percent(lcov) == 50.0
    @test DoD.globmatch("src/*.jl", "src/sub/deep.jl")              # `*` crosses `/` (sh case)
    @test !DoD.globmatch("src/*.jl", "test/a.jl")

    @testset "CLI against the merge base" begin
        cfg = read(joinpath(ROOT, "ratchets.toml"), String)
        d = tmp_repo(Dict("ratchets.toml" => cfg, "src/A.jl" => "x\n"))
        sh(`git -C $d checkout -q -b feat/r`)
        # 0.2.4: each failing case asserts the exact FAIL lines, not only a non-zero exit
        fails(out) = [String(m.captures[1]) for m in eachmatch(r"  FAIL (.*)", out)]
        rc, out = capture(() -> Ratchet.main(["--root", d]))
        @test rc == 0 && isempty(fails(out)) && occursin("ratchet.jl: OK", out)
        write(joinpath(d, "ratchets.toml"), replace(cfg, "max_lines = 150" => "max_lines = 151"))
        rc, out = capture(() -> Ratchet.main(["--root", d]))
        @test rc == 1 && fails(out) == ["size `CLAUDE.md` raised 150 -> 151 (may only fall)", "size `.claude/hooks/*.sh` raised 150 -> 151 (may only fall)"]
        write(joinpath(d, "ratchets.toml"), cfg)
        write(joinpath(d, "src/A.jl"), "x\n"^601)
        rc, out = capture(() -> Ratchet.main(["--root", d]))
        @test rc == 1 && fails(out) == ["src/A.jl has 601 lines > 600 (`src/*.jl`)"]
        write(joinpath(d, "src/A.jl"), "x\n")
        write(joinpath(d, "ratchets.toml"), replace(cfg, "floor = 0.0" => "floor = 60.0"))
        rc, out = capture(() -> Ratchet.main(["--root", d, "--lcov", lcov]))     # 50% < 60%
        @test rc == 1 && fails(out) == ["coverage 50.0% is below the floor 60.0%"]
        rc, out = capture(() -> Ratchet.main(["--root", d]))                      # raising is fine
        @test rc == 0 && isempty(fails(out))
        write(joinpath(d, "ratchets.toml"), replace(cfg, "time_tolerance = 0.10" => "time_tolerance = 0.20"))
        rc, out = capture(() -> Ratchet.main(["--root", d]))
        @test rc == 1 && fails(out) == ["bench.time_tolerance raised 0.1 -> 0.2 (may only fall)"]
        # 0.2.7 (factory-027 item 4): origin/main does not resolve (no remote): the local main is the base
        rc, out = capture(() -> Ratchet.main(["--root", d, "--base", "origin/main"]))
        @test rc == 1 && fails(out) == ["bench.time_tolerance raised 0.1 -> 0.2 (may only fall)"]   # 0.2.6: skipped, OK
        @test occursin("ratchet.jl: note: `origin/main` does not resolve here", out)
        rc, out = capture(() -> Ratchet.main(["--root", d, "--base", "origin/nope"]))      # no merge base: said so, not "no ratchets.toml"
        @test occursin("NOT RUN: no merge base with `origin/nope`", out) && !occursin("no ratchets.toml at the merge base", out)
        write(joinpath(d, "ratchets.toml"), replace(cfg, r"\[\[size\]\]\nglob = \"CLAUDE.md\"\nmax_lines = 150\n" => ""))
        rc, out = capture(() -> Ratchet.main(["--root", d]))
        @test rc == 1 && fails(out) == ["size rule `CLAUDE.md` removed (may only tighten)"]
    end

    if IN_FACTORY
        # 0.2.1 shipped a 210-line bash_guard.sh under its own 150-line hook budget, so ratchet.jl
        # failed in every repo. Every profile's files must pass the seeded ratchets.toml.
        @testset "the factory's own files are within its seeded size budgets" begin
            cfg = TOML.parsefile(joinpath(ROOT, "ratchets.toml"))
            for profile in keys(TOML.parsefile(joinpath(FACTORY, "MANIFEST.toml"))["profiles"])
                srcs, _ = SyncFactory.sources(FACTORY, profile)
                d = mktempdir()
                for s in srcs
                    mkpath(dirname(joinpath(d, s.rel))); write(joinpath(d, s.rel), s.bytes)
                end
                bad = Ratchet.sizes(d, cfg, [s.rel for s in srcs])
                @test isempty(bad) || (println("$profile: ", bad); false)
            end
            gen = TOML.parsefile(joinpath(FACTORY, "MANIFEST.toml"))["generated"]["paths"]
            files = [relpath(joinpath(r, f), ROOT) for (r, _, fs) in walkdir(ROOT) for f in fs]
            @test isempty(Ratchet.sizes(ROOT, cfg, filter(f -> any(g -> DoD.globmatch(g, f), gen), files)))
        end
    end
end
