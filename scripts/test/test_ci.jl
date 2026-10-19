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
checkout_profile(root) = get(CI.factory_record(root), "profile",
                             isfile(joinpath(root, "factory", "MANIFEST.toml")) ? "coordinator" : "package")

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
    rc, out = capture(() -> CI.run_job("contracts", ROOT, String[]))
    @test rc == 0 && occursin("skipped: no upstreams", out)
    rc, out = capture(() -> CI.run_job("test", ROOT, ["laws"]; dry = true))
    @test occursin("-- laws", out)
    @test capture(() -> CI.run_job("nope", ROOT, String[]))[1] == 2

    @testset "test job really runs Pkg.test on a package" begin
        d = mktempdir()
        write(joinpath(d, "Project.toml"), """
            name = "FactoryProbe"
            uuid = "4b3a7c1e-0d5e-4c55-9a0b-2b6f0f1e9a11"
            version = "0.1.0"
            [extras]
            Test = "8dfed614-e22c-5e08-85e1-65c5234f0b40"
            [targets]
            test = ["Test"]
            """)
        mkpath(joinpath(d, "src")); write(joinpath(d, "src/FactoryProbe.jl"), "module FactoryProbe\nf() = 1\nend\n")
        mkpath(joinpath(d, "test"))
        write(joinpath(d, "test/runtests.jl"), "using Test, FactoryProbe\n@test FactoryProbe.f() == 1\n@test ARGS == [\"unit\"]\n")
        rc, out = capture(() -> CI.run_job("test", d, ["unit"]))
        @test rc == 0 || (print(out); false)
    end
end
