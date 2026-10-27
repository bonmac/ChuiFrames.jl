"""
    reachability(root, profile) -> Vector{String} of problems

`template`/`package`: every ci.jl job is called by some workflow. A narrower profile (the
coordinator keeps only Guards.yml): every workflow `.factory-version` recorded is present and
calls ci.jl, and some workflow calls `guards`.
"""
function reachability(root, profile)
    wf = joinpath(root, ".github/workflows")
    used = Set{String}()
    for f in (isdir(wf) ? readdir(wf) : String[]), m in eachmatch(r"scripts/ci\.jl ([a-z]+)", read(joinpath(wf, f), String))
        push!(used, m.captures[1])
    end
    problems = String[]
    if profile in ("template", "package")
        for j in sort!(collect(setdiff(keys(CI.JOBS), used)))
            push!(problems, "job $j is never called by a workflow")
        end
    else
        given = sort!([k for k in keys(get(CI.factory_record(root), "managed", Dict())) if startswith(k, ".github/workflows/")])
        isempty(given) && push!(problems, ".factory-version records no workflows")
        for k in given
            p = joinpath(root, k)
            if !isfile(p)
                push!(problems, "workflow $k from the factory is missing")
            elseif !(basename(k) in ("CompatHelper.yml", "TagBot.yml")) && !occursin(r"scripts/ci\.jl [a-z]+", read(p, String))
                push!(problems, "workflow $k calls no ci.jl job")
            end
        end
        "guards" in used || push!(problems, "no workflow calls the guards job")
    end
    return problems
end

"""
The profile a vendored checkout was synced with. Without a `.factory-version` (never synced, or
the record not committed), a checkout holding the factory (`factory/MANIFEST.toml`) is the
coordinator, else a package; 0.2.0 always fell back to `package` and so reported every
package job as never called in a coordinator checkout.
"""
checkout_profile(root) = get(
    CI.factory_record(root), "profile",
    isfile(joinpath(root, "factory", "MANIFEST.toml")) ? "coordinator" : "package"
)

@testset "ci.jl" begin
    wf = joinpath(ROOT, ".github/workflows")
    used = Set{String}()
    for f in readdir(wf), m in eachmatch(r"scripts/ci\.jl ([a-z]+)", read(joinpath(wf, f), String))
        push!(used, m.captures[1])
        @test haskey(CI.JOBS, m.captures[1]) || (println("$f calls unknown job $(m.captures[1])"); false)
    end
    # every job reachable from CI (template, package); a narrower profile checks what it was given
    probs = reachability(ROOT, IN_FACTORY ? "template" : checkout_profile(ROOT))
    @test isempty(probs) || (foreach(println, probs); false)
    @testset "reachability is profile-aware" begin
        n = mktempdir()                               # never synced: profile from the checkout's shape
        @test checkout_profile(n) == "package"
        mkpath(joinpath(n, "factory")); write(joinpath(n, "factory/MANIFEST.toml"), "version = 1\n")
        @test checkout_profile(n) == "coordinator"
        @test reachability(n, checkout_profile(n)) == [".factory-version records no workflows", "no workflow calls the guards job"]
        c = mktempdir()                               # a coordinator checkout: only Guards.yml
        mkpath(joinpath(c, ".github/workflows"))
        cp(joinpath(wf, "Guards.yml"), joinpath(c, ".github/workflows/Guards.yml"))
        write(joinpath(c, ".factory-version"), "profile = \"coordinator\"\n[managed]\n\".github/workflows/Guards.yml\" = \"x\"\n")
        @test isempty(reachability(c, "coordinator"))
        @test !isempty(reachability(c, "package"))   # the package profile still demands every job
        write(joinpath(c, ".factory-version"), "profile = \"coordinator\"\n[managed]\n\".github/workflows/Guards.yml\" = \"x\"\n\".github/workflows/CI.yml\" = \"x\"\n")
        @test any(contains("CI.yml"), reachability(c, "coordinator"))   # a given workflow went missing
        rm(joinpath(c, ".github/workflows/Guards.yml"))
        @test any(contains("guards"), reachability(c, "coordinator"))
    end
    # no workflow runs Julia code except through ci.jl (CompatHelper/TagBot are external tools)
    for f in readdir(wf)
        f in ("CompatHelper.yml", "TagBot.yml") && continue
        for l in eachline(joinpath(wf, f))
            m = match(r"^\s*(?:-\s*)?run:\s*(.*)$", l)
            m === nothing || m.captures[1] == "|" || @test occursin("scripts/ci.jl", m.captures[1])
        end
    end
    rc, out = capture(() -> CI.run_job("guards", ROOT, String[]; dry = true))
    @test rc == 0 && occursin("scripts/gen.jl --check", out)
    rc, out = capture(() -> CI.run_job("contracts", mktempdir(), String[]))   # not a package (hermetic: ROOT may be one)
    @test rc == 0 && occursin("skipped (not applicable)", out)
    rc, out = capture(() -> CI.run_job("test", ROOT, ["laws"]; dry = true))
    @test occursin("-- laws", out)
    @test capture(() -> CI.run_job("nope", ROOT, String[]))[1] == 2

    @testset "test job really runs Pkg.test on a package" begin
        d = mktempdir()
        write(
            joinpath(d, "Project.toml"), """
            name = "FactoryProbe"
            uuid = "4b3a7c1e-0d5e-4c55-9a0b-2b6f0f1e9a11"
            version = "0.1.0"
            [extras]
            Test = "8dfed614-e22c-5e08-85e1-65c5234f0b40"
            [targets]
            test = ["Test"]
            """
        )
        mkpath(joinpath(d, "src")); write(joinpath(d, "src/FactoryProbe.jl"), "module FactoryProbe\nf() = 1\nend\n")
        mkpath(joinpath(d, "test"))
        write(joinpath(d, "test/runtests.jl"), "using Test, FactoryProbe\n@test FactoryProbe.f() == 1\n@test ARGS == [\"unit\"]\n")
        rc, out = capture(() -> CI.run_job("test", d, ["unit"]))
        @test rc == 0 || (print(out); false)
    end

    @testset "--timeout kills the whole process tree, Pkg.test's child julia included (0.2.7)" begin
        # factory-027 item 5: `perl -e 'alarm N; exec @ARGV' julia scripts/ci.jl test` killed only ci.jl;
        # the child julia of Pkg.test (a hung property test) ran on for ~6 h
        @test CI.time_limit(nothing) === nothing && CI.time_limit("90") == 90.0
        withenv("CI_TIMEOUT" => "30") do
            @test CI.time_limit(nothing) == 30.0 && CI.time_limit("5") == 5.0      # the flag wins over the env
        end
        @test_throws ErrorException CI.time_limit("0")
        @test_throws ErrorException CI.time_limit("soon")
        @test capture(() -> CI.main(["test", "--timeout"]))[1] == 2
        @test capture(() -> CI.main(["test", "--timeout", "-1"]))[1] == 2
        d = realpath(mktempdir())
        write(
            joinpath(d, "Project.toml"), """
            name = "FactoryHang"
            uuid = "6c1d2e3f-4a5b-4c6d-9e7f-8a9b0c1d2e3f"
            version = "0.1.0"
            [extras]
            Test = "8dfed614-e22c-5e08-85e1-65c5234f0b40"
            [targets]
            test = ["Test"]
            """
        )
        mkpath(joinpath(d, "src")); write(joinpath(d, "src/FactoryHang.jl"), "module FactoryHang\nend\n")
        mkpath(joinpath(d, "test"))
        # the planted hang: the test process records its pid, starts a grandchild, and never returns
        write(
            joinpath(d, "test/runtests.jl"), """
            write(joinpath(@__DIR__, "child.pid"), string(getpid()))
            g = run(`sleep 600`; wait = false)
            write(joinpath(@__DIR__, "grandchild.pid"), string(getpid(g)))
            while true; sleep(1); end
            """
        )
        t0 = time()
        rc, out = capture(() -> CI.run_job("test", d, String[]; timeout = 60, grace = 3))
        @test rc == CI.TIMEOUT_EXIT && occursin("ci.jl test: TIMED OUT after 60", out) || (print(out); false)
        @test time() - t0 < 60 + 3 + 15                                            # bounded: limit + grace + slack
        alive(pid) = ccall(:kill, Cint, (Cint, Cint), pid, 0) == 0
        child, grand = (parse(Int, read(joinpath(d, "test", f), String)) for f in ("child.pid", "grandchild.pid"))
        @test !alive(child) && !alive(grand)                                       # the planted test really started, and is gone
        @test !success(`pgrep -f $d`)                                              # no process of this run is left
        # review B2: Ctrl-C during a bounded run. The command's group is detached, so SIGINT reaches only
        # ci.jl, which must take the group down (c0edfbe: ci.jl died and the hung test ran on)
        rm(joinpath(d, "test/child.pid")); rm(joinpath(d, "test/grandchild.pid"))
        drv = joinpath(mktempdir(), "drv.jl")
        write(drv, "include($(repr(joinpath(SCRIPTS, "ci.jl"))))\nexit(CI.run_job(\"test\", $(repr(d)), String[]; timeout = 300, grace = 2))\n")
        log = joinpath(dirname(drv), "drv.log")
        p = run(pipeline(Cmd(`$JULIA $drv`; ignorestatus = true); stdout = log, stderr = log); wait = false)
        t = time() + 120
        while !isfile(joinpath(d, "test/grandchild.pid")) && time() < t && process_running(p)
            sleep(0.5)
        end
        @test isfile(joinpath(d, "test/grandchild.pid")) || (print(read(log, String)); false)
        sleep(1)
        kill(p, Base.SIGINT)                                                       # what a terminal Ctrl-C delivers to ci.jl
        wait(p)
        @test p.exitcode == CI.INTERRUPT_EXIT && occursin("INTERRUPTED", read(log, String)) || (print(read(log, String)); false)
        child, grand = (parse(Int, read(joinpath(d, "test", f), String)) for f in ("child.pid", "grandchild.pid"))
        @test !alive(child) && !alive(grand)
        @test !success(`pgrep -f $d`)
        # a command that finishes in time is unaffected
        write(joinpath(d, "test/runtests.jl"), "using Test\n@test true\n")
        @test capture(() -> CI.run_job("test", d, String[]; timeout = 300))[1] == 0
    end

    @testset "docs, jet and contracts leave tracked files byte-identical (0.2.2)" begin
        # 0.2.1 ran Pkg.develop in docs/ and test/jet/ in place: Julia >= 1.11 wrote an absolute
        # [sources] path into the tracked Project.toml, added the package to [deps], dropped comments.
        uuid = "7d2c1f0e-3b4a-4e5f-8a9b-0c1d2e3f4a5b"
        tomlv = "TOML = \"fa267f1f-6049-4f14-aa54-33bafae1ed76\""
        d = tmp_repo(
            Dict(
                "Project.toml" => "name = \"FactoryEnvProbe\"\nuuid = \"$uuid\"\nversion = \"0.1.0\"\n",
                "src/FactoryEnvProbe.jl" => "module FactoryEnvProbe\nf() = 1\nend\n",
                ".gitignore" => "/Manifest*.toml\n/docs/Manifest*.toml\n/test/jet/Manifest*.toml\n/test/contracts/Manifest*.toml\n",
                # a relative [sources] path (Julia >= 1.11) must still resolve from the scratch copy
                "docs/Project.toml" => "# docs env: this comment must survive\n[deps]\nFactoryEnvProbe = \"$uuid\"\n$tomlv\n\n[sources]\nFactoryEnvProbe = {path = \"..\"}\n\n[compat]\nTOML = \"1\"\n",
                "docs/make.jl" => "using TOML, FactoryEnvProbe\nFactoryEnvProbe.f() == 1 || error(\"probe\")\n",
                "test/jet/Project.toml" => "# jet env: this comment must survive\n[deps]\n$tomlv\n\n[compat]\nTOML = \"1\"\n",
                "test/jet/runjet.jl" => "using TOML\nconst N = Symbol(TOML.parsefile(joinpath(@__DIR__, \"..\", \"..\", \"Project.toml\"))[\"name\"])\n@eval using \$N\n",
                "test/contracts/Project.toml" => "# contracts env\n[deps]\nTest = \"8dfed614-e22c-5e08-85e1-65c5234f0b40\"\n\n[compat]\nTest = \"1\"\n",
                "test/contracts/upstreams.toml" => "[upstreams]\nUp = \"https://example.invalid/Up.jl\"\n",
                "test/contracts/runtests.jl" => "using Test\n@test Base.active_project() != abspath(\"test/contracts/Project.toml\")\n",
            )
        )
        files = filter(f -> isfile(joinpath(d, f)), CI.tracked_files(d))
        before = Dict(f => read(joinpath(d, f)) for f in files)
        td = mktempdir()                                                # tempname() reads TMPDIR per call
        withenv("JULIA_PKG_OFFLINE" => "true", "JULIA_PKG_PRECOMPILE_AUTO" => "0", "TMPDIR" => td) do
            for job in ("docs", "jet", "contracts")
                rc, out = capture(() -> CI.run_job(job, d, String[]))
                @test (rc == 0 && occursin("ci.jl $job: OK", out)) || (print(out); false)
            end
            @test all(f -> read(joinpath(d, f)) == before[f], files)
            @test isempty(read(`git -C $d status --porcelain`, String))
            @test isempty(CI.SCRATCH)
            @test !any(e -> isfile(joinpath(td, e, "Project.toml")), readdir(td))   # scratch envs deleted
            write(joinpath(d, "test/contracts/runtests.jl"), "using Test\n@test 1 == 2\n")
            @test capture(() -> CI.run_job("contracts", d, String[]))[1] == 1  # a failing contract test fails the job
        end
        rc, out = capture(() -> CI.run_job("contracts", d, ["main"]; dry = true))     # no --in-place gate now
        @test rc == 0 && occursin("test/contracts", out) && occursin(" main", out) && !occursin("--project=.", out)
        rm(joinpath(d, "test/contracts/Project.toml"))
        rc, out = capture(() -> CI.run_job("contracts", d, String[]))       # 0.2.3: "skipped", exit 0
        @test rc == 1 && occursin("FAILED (missing): test/contracts/Project.toml", out)
    end

    @testset "a skip declares its kind; a missing seeded file is red (0.2.4)" begin
        seeded = Dict(
            "Project.toml" => "name = \"P\"\nuuid = \"4b3a7c1e-0d5e-4c55-9a0b-2b6f0f1e9a12\"\n",
            "test/jet/Project.toml" => "", "test/jet/runjet.jl" => "", "docs/Project.toml" => "", "docs/make.jl" => "",
            "test/contracts/Project.toml" => "", "test/contracts/runtests.jl" => "",
            "test/contracts/upstreams.toml" => "[upstreams]\nUp = \"https://example.invalid/Up.jl\"\n"
        )
        mk() = (
            d = mktempdir(); for (f, c) in seeded
                mkpath(dirname(joinpath(d, f))); write(joinpath(d, f), c)
            end; d
        )
        job_of(f) = startswith(f, "test/jet") ? "jet" : startswith(f, "docs") ? "docs" : "contracts"
        d = mk()
        for job in ("jet", "docs", "contracts")                              # all present: the job runs
            rc, out = capture(() -> CI.run_job(job, d, String[]; dry = true))
            @test rc == 0 && !occursin("skipped", out) && !occursin("NOT RUN", out)
        end
        for f in sort!(collect(keys(seeded))), _ in 1:1                      # delete each one: red, naming the file
            f == "Project.toml" && continue
            d = mk(); rm(joinpath(d, f))
            rc, out = capture(() -> CI.run_job(job_of(f), d, String[]; dry = true))
            @test (rc == 1 && occursin("FAILED (missing): $f", out)) || (println("$f: rc=$rc $out"); false)
        end
        d = mk(); write(joinpath(d, "test/contracts/upstreams.toml"), "[upstreams]\n")   # waiting: loud, exit 0
        rc, out = capture(() -> CI.run_job("contracts", d, String[]))
        @test rc == 0 && occursin("NOT RUN (waiting)", out) && occursin("not a pass", out)
        rc, out = withenv("GITHUB_ACTIONS" => "true") do
            capture(() -> CI.run_job("contracts", d, String[]))
        end
        @test rc == 0 && occursin("::warning title=ci.jl contracts did not run::", out)
        write(joinpath(d, "test/contracts/upstreams.toml"), "[upstream]\nUp = \"https://example.invalid/Up.jl\"\n")   # the review: a typo
        rc, out = capture(() -> CI.run_job("contracts", d, String[]))
        @test rc == 1 && occursin("unknown tables [\"upstream\"]", out)
        rc, out = capture(() -> CI.run_job("bench", d, String[]))           # no benchmark suite yet
        @test rc == 0 && occursin("NOT RUN (waiting)", out)
        mkpath(joinpath(d, "benchmark"))
        rc, out = capture(() -> CI.run_job("bench", d, String[]))           # the suite's file went missing
        @test rc == 1 && occursin("FAILED (missing)", out)
        e = mktempdir()                                                      # not a package: not applicable
        for job in ("jet", "docs", "contracts", "bench")
            rc, out = capture(() -> CI.run_job(job, e, String[]))
            @test rc == 0 && occursin("skipped (not applicable)", out)
        end
        write(joinpath(e, ".factory-version"), "profile = \"package\"\n")  # a synced package without Project.toml
        @test capture(() -> CI.run_job("jet", e, String[]))[1] == 1
        @test_throws ErrorException CI.Skip(:quiet, "x")
        write(joinpath(e, ".factory-version"), "not = [toml")                 # the review: unknown profile is not "not applicable"
        @test capture(() -> CI.run_job("jet", e, String[]))[1] == 1
        rc, out = withenv("JULIA_PROJECT" => "/elsewhere") do                # env hygiene: a leaky variable is named
            capture(() -> CI.run_job("jet", e, String[]))
        end
        @test occursin("ci.jl jet: warning: JULIA_PROJECT=/elsewhere", out)
    end

    if IN_FACTORY
        @testset "seeded environments: compat on everything, Manifests ignored (0.2.2)" begin
            ign = readlines(joinpath(ROOT, ".gitignore"))
            envs = String[]
            for (r, _, fs) in walkdir(ROOT), f in fs
                f == "Project.toml" && push!(envs, relpath(r, ROOT))
            end
            @test issubset(["test/jet", "test/contracts"], envs)
            for e in envs                                                  # ADR-0004 rule 3
                p = TOML.parsefile(joinpath(ROOT, e, "Project.toml"))
                c = get(p, "compat", Dict())
                @test haskey(c, "julia") || (println("$e: no julia compat"); false)
                for dep in keys(get(p, "deps", Dict()))
                    @test haskey(c, dep) || (println("$e: no compat for $dep"); false)
                end
                @test "/$e/Manifest*.toml" in ign || (println(".gitignore misses /$e/Manifest*.toml"); false)
            end
            @test "/docs/Manifest*.toml" in ign
            # 0.2.6: a version-specific Manifest (a 1.13-resolved Manifest.toml does not instantiate on 1.10) and
            # Supposition's counterexample DB (one written by 1.13 crashes 1.10; ADR-0007 §2 amendment) are never committed
            d = tmp_repo(Dict(".gitignore" => read(joinpath(ROOT, ".gitignore"), String)))
            for p in ("Manifest-v1.10.toml", "test/Manifest-v1.10.toml", "test/SuppositionDB/x/y.bin")
                @test success(`git -C $d check-ignore -q $p`) || (println(".gitignore does not ignore $p"); false)
            end
            # 0.2.6: TestItemRunner scans the whole package dir, so a @testmodule in a lane worktree shadowed the real
            # one (`Evaluated: 42 == -1`). The seeded JuliaTestItems.toml excludes every runtime dir sync never ships,
            # with TestItemRunner's keys and anchored-directory patterns (gitignore-style, read by >= 1.3.2)
            jti = TOML.parsefile(joinpath(ROOT, "JuliaTestItems.toml"))
            @test issubset(keys(jti), ("config-version", "include", "exclude")) && !haskey(jti, "include")
            for r in filter(r -> endswith(r, "/"), SyncFactory.RUNTIME)
                @test "/$r" in jti["exclude"] || (println("JuliaTestItems.toml does not exclude /$r"); false)
            end
            excluded(rel) = any(p -> startswith(p, '/') && endswith(p, '/') && startswith(rel, p[2:end]), jti["exclude"])
            @test excluded(".worktrees/x/test/helpers.jl") && excluded(".lanes/scratch/broken.jl") && !excluded("test/answer_tests.jl")
            # 0.3.0 (tw-033): in a package, discovery picked up the tdd fixture package's @testitems, which fail on
            # purpose (ChuiTypes `ci.jl test -- all`: 16 extra items, 2 fail, 13 error). Every fixture .jl is excluded.
            @test "/scripts/test/fixtures/" in jti["exclude"]
            fx = joinpath(ROOT, "scripts", "test", "fixtures")
            fixture_jl = [relpath(joinpath(r, f), ROOT) for (r, _, fs) in walkdir(fx) for f in fs if endswith(f, ".jl")]
            @test !isempty(fixture_jl)
            for rel in fixture_jl
                @test excluded(replace(rel, '\\' => '/')) || (println("JuliaTestItems.toml does not exclude $rel"); false)
            end
            for e in ("test", "test/contracts")                            # the version that reads it
                @test TOML.parsefile(joinpath(ROOT, e, "Project.toml"))["compat"]["TestItemRunner"] == "1.3.2"
            end
            m = TOML.parsefile(joinpath(FACTORY, "MANIFEST.toml"))
            @test "JuliaTestItems.toml" in m["seeded"]["paths"] && "JuliaTestItems.toml" in m["profiles"]["coordinator"]["exclude"]
        end
    end
end
