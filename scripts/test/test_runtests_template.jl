"The factory's stable-only block of a seeded test/runtests.jl (`src`), or nothing when it has none."
function stable_block(src)
    b = findfirst("# --- stable-only tags", src)
    e = findfirst("# --- end stable-only tags ---", src)
    return b === nothing || e === nothing ? nothing : src[first(b):last(e)]
end

@testset "seeded test/runtests.jl: stable-only tags by Julia version (0.2.7)" begin
    # factory-027 item 6: unset CI_STABLE meant stable, so a fresh clone's `]test` on the LTS ran the
    # stable-only :doctest items and failed. Evaluate the marked block of the seeded file on its own.
    # test/runtests.jl is SEEDED: in a package it is the package's own file and may not have the block
    # (a sync never overwrites it), so only the factory itself must have it.
    p = joinpath(ROOT, "test/runtests.jl")
    blk = stable_block(isfile(p) ? read(p, String) : "")
    if blk === nothing
        @test !IN_FACTORY
        @info "test/runtests.jl has no factory stable-only block (repo-owned); not checked"
    else
        m = Module(:SeededRuntests)
        Base.include_string(m, blk, "test/runtests.jl")
        # defined in this same top-level expression: call through invokelatest (world age)
        is_stable(args...) = Base.invokelatest(getglobal(m, :is_stable), args...)
        STABLE_MIN = getglobal(m, :STABLE_MIN)
        @test STABLE_MIN isa VersionNumber && STABLE_MIN > v"1.10"            # the LTS is never stable
        none = Dict{String, String}()
        @test is_stable(none, STABLE_MIN) && is_stable(none, v"1.14.0")        # default: stable at or above STABLE_MIN
        @test !is_stable(none, v"1.10.12") && !is_stable(none, v"1.12.6")      # default: the LTS and older are not
        @test is_stable(Dict("CI_STABLE" => "true"), v"1.10.12")               # override, both ways
        @test !is_stable(Dict("CI_STABLE" => "false"), v"1.14.0")
        @test !is_stable(Dict("CI_STABLE" => ""), v"1.10") && is_stable(Dict("CI_STABLE" => ""), v"1.13")   # empty = unset
        # strict, as ChuiCore.jl e80dce9: anything but exactly "true"/"false" is an ArgumentError
        for bad in ("1", "0", "yes", "TRUE", "False", " true", "true ")
            @test_throws ArgumentError is_stable(Dict("CI_STABLE" => bad), v"1.13")
        end
        err = try
            is_stable(Dict("CI_STABLE" => "yes"))
        catch e
            e
        end
        @test err isa ArgumentError && occursin("got \"yes\"", err.msg)
        @test occursin("ADR-0008 §3", blk)                                     # the constant cites its source
    end
    if IN_FACTORY   # CI.yml still decides per job: true on stable ('1'), false on lts and pre
        ci = read(joinpath(ROOT, ".github/workflows/CI.yml"), String)
        @test occursin("CI_STABLE: \${{ matrix.version == '1' }}", ci)
    end
end
