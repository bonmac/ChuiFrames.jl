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

"The factory's item-selection block of a seeded test/runtests.jl (`src`), or nothing when it has none."
function item_block(src)
    b = findfirst("# --- item selection ---", src)
    e = findfirst("# --- end item selection ---", src)
    return b === nothing || e === nothing ? nothing : src[first(b):last(e)]
end

"""
`select_item`/`record_match` from the seeded test/runtests.jl's item-selection block, evaluated in a
fresh module (after its stable-only block, if any), as a NamedTuple of invokelatest wrappers; or
nothing when the file has no such block.
"""
function seeded_item_fns()
    p = joinpath(ROOT, "test/runtests.jl")
    src = isfile(p) ? read(p, String) : ""
    blk = item_block(src)
    blk === nothing && return nothing
    m = Module(:SeededItemSelection)
    sb = stable_block(src)
    sb === nothing || Base.include_string(m, sb, "test/runtests.jl")
    Base.include_string(m, blk, "test/runtests.jl")
    return (
        select = (args...; kw...) -> Base.invokelatest(getglobal(m, :select_item), args...; kw...),
        record = (args...) -> Base.invokelatest(getglobal(m, :record_match), args...),
        block = blk,
    )
end

# Spec 2026-10-26-factory-test-writer-design.md §3.4: `item=<name>` in the test args selects by name,
# after `:contract` (never) and the stable-only exclusion, before the tags; TDD_MATCHED=<file> records
# each selected name. test/runtests.jl is SEEDED: only the factory itself must have the block.
@testset "seeded test/runtests.jl: item= selection and TDD_MATCHED (§3.4)" begin
    f = seeded_item_fns()
    f === nothing && @info "test/runtests.jl has no factory item-selection block (repo-owned); not checked"

    @testset "item= selects by name with spaces" begin
        if f === nothing
            @test !IN_FACTORY
        else
            @test f.select("adds two numbers", [:unit], ["item=adds two numbers"]; stable = true) === true
            # item= decides over the tags: a default-excluded tag is still selected by name
            @test f.select("adds two numbers", [:slow], ["item=adds two numbers"]; stable = true) === true
            @test f.select("adds two numbers", Symbol[], ["item=adds two numbers"]; stable = false) === true
            # one of several item= arguments
            @test f.select("b c", [:unit], ["item=a", "item=b c"]; stable = true) === true
        end
    end

    @testset "non-matching item is not selected" begin
        if f === nothing
            @test !IN_FACTORY
        else
            @test f.select("other item", [:unit], ["item=adds two numbers"]; stable = true) === false
            @test f.select("adds two", [:unit], ["item=adds two numbers"]; stable = true) === false   # exact name
            @test f.select("adds two numbers", [:unit], ["item=adds two"]; stable = true) === false
            # any item= present: no match is false even when a tag argument would select it
            @test f.select("other item", [:unit], ["unit", "item=adds two numbers"]; stable = true) === false
        end
    end

    @testset "no item= args defer to tags" begin
        if f === nothing
            @test !IN_FACTORY
        else
            @test f.select("adds two numbers", [:unit], String[]; stable = true) === nothing
            @test f.select("adds two numbers", [:unit], ["unit"]; stable = true) === nothing
            @test f.select("adds two numbers", [:slow], ["all"]; stable = true) === nothing
            @test f.select("adds two numbers", [:unit], String[]; stable = false) === nothing
        end
    end

    @testset "contract never selected by name" begin
        if f === nothing
            @test !IN_FACTORY
        else
            @test f.select("api contract", [:contract], ["item=api contract"]; stable = true) === false
            @test f.select("api contract", [:contract, :unit], ["item=api contract"]; stable = true) === false
            @test f.select("api contract", [:contract], String[]; stable = true) === false
            @test f.select("api contract", [:contract], ["all"]; stable = true) === false
        end
    end

    @testset "doctest by name skipped when not stable" begin
        if f === nothing
            @test !IN_FACTORY
        else
            @test f.select("docs print", [:doctest], ["item=docs print"]; stable = false) === false
            @test f.select("table shows", [:snapshot], ["item=table shows"]; stable = false) === false
            @test f.select("docs print", [:doctest], ["item=docs print"]; stable = true) === true
            @test f.select("table shows", [:snapshot], ["item=table shows"]; stable = true) === true
        end
    end

    @testset "TDD_MATCHED records selected names" begin
        if f === nothing
            @test !IN_FACTORY
        else
            d = mktempdir()
            p = joinpath(d, "matched.txt")
            env = Dict("TDD_MATCHED" => p)
            f.record("adds two numbers", env)                     # creates the file
            f.record("b c", env)                                  # appends
            @test isfile(p) && read(p, String) == "adds two numbers\nb c\n"
            q = joinpath(d, "existing.txt")
            write(q, "earlier\n")
            f.record("later one", Dict("TDD_MATCHED" => q))       # never truncates
            @test read(q, String) == "earlier\nlater one\n"
        end
    end

    @testset "TDD_MATCHED unset writes nothing" begin
        if f === nothing
            @test !IN_FACTORY
        else
            d = mktempdir()
            cd(d) do
                f.record("adds two numbers", Dict{String, String}())
            end
            @test isempty(readdir(d))
        end
    end

    # UNVERIFIED claim (§3.4): Pkg.test passes ENV through to the test process. A scratch package whose
    # test/runtests.jl is the seeded runner, Pkg.test run in a subprocess, offline, TestItemRunner from
    # the depot (checked offline on Julia 1.13.2, 2026-10-26).
    @testset "TDD_MATCHED reaches the Pkg.test child" begin
        if f === nothing
            @test !IN_FACTORY
        else
            d = realpath(mktempdir())
            mkpath(joinpath(d, "src"))
            mkpath(joinpath(d, "test"))
            write(
                joinpath(d, "Project.toml"), """
                name = "TddScratch"
                uuid = "6a1c0d2e-3b4f-4c5d-8e9f-0a1b2c3d4e5f"
                version = "0.1.0"

                [extras]
                Test = "8dfed614-e22c-5e08-85e1-65c5234f0b40"
                TestItemRunner = "f8b46487-2199-4994-9208-9a1283c18c0a"

                [targets]
                test = ["Test", "TestItemRunner"]
                """
            )
            write(joinpath(d, "src", "TddScratch.jl"), "module TddScratch\nend\n")
            cp(joinpath(ROOT, "test/runtests.jl"), joinpath(d, "test", "runtests.jl"))
            write(
                joinpath(d, "test", "items.jl"), """
                @testitem "has spaces here" tags = [:unit] begin
                    @test true
                end
                @testitem "not this one" tags = [:unit] begin
                    @test true
                end
                """
            )
            matched = joinpath(d, "matched.txt")
            log = joinpath(d, "pkgtest.log")
            cmd = `$JULIA --project=$d -e 'using Pkg; Pkg.test(test_args = ["item=has spaces here"])'`
            cmd = addenv(Cmd(cmd; dir = d), "TDD_MATCHED" => matched, "JULIA_PKG_OFFLINE" => "true", "CI_STABLE" => "true")
            ok = success(pipeline(cmd; stdout = log, stderr = log))
            ok || @info "Pkg.test child failed" read(log, String)
            @test ok
            got = isfile(matched) ? split(read(matched, String), '\n'; keepempty = false) : String[]
            @test "has spaces here" in got
            @test !("not this one" in got)
        end
    end
end
