# factory 0.3.1 finding 1: `julia scripts/ci.jl format` failed in a package synced with 0.3.0.
# (a) the template's own scripts were not Runic-formatted; (b) Runic hit a ParseError on the
# deliberately broken fixture scripts/test/fixtures/tdd/scratchpkg/test/parse_tests.jl. Runic 1.13
# has no exclude option, so the format job selects its files itself:
#
#   CI.format_files(root) -> Vector{String}
#
# the .jl files of `root` (paths relative to `root`, sorted, each an existing file), minus every
# file under `scripts/test/fixtures/`. The format job passes exactly these to Runic, never a bare ".".

"The format job's file selection, or `nothing` while CI.format_files does not exist (the RED state)."
format_selection(root) = isdefined(CI, :format_files) ? CI.format_files(root) : nothing

const FIXTURES_PREFIX = "scripts/test/fixtures/"

@testset "ci.jl format selects its files (0.3.1 finding 1)" begin
    @testset "CI.format_files exists" begin
        @test isdefined(CI, :format_files)
    end

    @testset "template: fixtures excluded, ordinary scripts selected" begin
        sel = format_selection(ROOT)
        @test sel isa Vector{String}
        if sel isa Vector{String}
            @test !isempty(sel)
            bad = filter(f -> startswith(f, FIXTURES_PREFIX), sel)
            @test isempty(bad) || (println("format_files selected fixtures: ", bad); false)
            @test !("scripts/test/fixtures/tdd/scratchpkg/test/parse_tests.jl" in sel)
            for f in ("scripts/ci.jl", "scripts/tdd.jl", "scripts/_common.jl", "scripts/test/runtests.jl", "scripts/test/test_ci.jl")
                @test f in sel || (println("format_files did not select $f"); false)
            end
            @test all(endswith(".jl"), sel)
            @test all(f -> !isabspath(f) && isfile(joinpath(ROOT, f)), sel)
            @test issorted(sel)
        end
    end

    @testset "a scratch repo: fixtures excluded at any depth, the rest kept" begin
        d = tmp_repo(
            Dict(
                "src/A.jl" => "x = 1\n",
                "scripts/ci.jl" => "y = 2\n",
                "scripts/test/test_x.jl" => "z = 3\n",
                "scripts/test/fixtures/broken.jl" => "function (\n",
                "scripts/test/fixtures/tdd/scratchpkg/test/parse_tests.jl" => "end end\n",
                "README.md" => "x\n",
            )
        )
        sel = format_selection(d)
        @test sel == ["scripts/ci.jl", "scripts/test/test_x.jl", "src/A.jl"]
    end

    @testset "the format job passes the selection, never a bare \".\"" begin
        cmds = CI.JOBS["format"].commands(ROOT, String[])
        @test cmds isa Vector
        runic = filter(a -> any(==(CI.RUNIC_RUN), a), cmds)
        @test length(runic) == 1
        if length(runic) == 1
            argv = only(runic)
            i = findfirst(==("--"), argv)
            args = i === nothing ? String[] : argv[(i + 1):end]
            @test "--check" in args
            @test !("." in args)        # "." makes Runic walk into scripts/test/fixtures/ again
            @test !any(a -> startswith(a, FIXTURES_PREFIX) || occursin("/fixtures/", a), args)
            @test "scripts/ci.jl" in args
            sel = format_selection(ROOT)
            sel isa Vector{String} && @test filter(a -> !startswith(a, "--"), args) == sel
        end
        rc, out = capture(() -> CI.run_job("format", ROOT, String[]; dry = true))
        @test rc == 0
        @test !occursin(r"--diff \.(\s|$)", out) && !occursin(r"--check \.(\s|$)", out)
        @test !occursin(FIXTURES_PREFIX, out)
    end

    @testset "every selected template script is Runic-clean" begin
        # Offline only: no Pkg.add inside the tests. Skip, loudly, when @runic has no Runic.
        has_runic = success(
            pipeline(
                `$JULIA --project=@runic -e 'exit(Base.find_package("Runic") === nothing ? 1 : 0)'`;
                stdout = devnull, stderr = devnull
            )
        )
        if !has_runic
            println("SKIPPED: Runic is not installed in the @runic environment; the Runic-clean check did not run (no network install inside tests)")
            @test_skip "Runic-clean template scripts"
        else
            # While CI.format_files is missing, check the same set it must return, so this item
            # reports the unformatted files rather than only the missing function.
            sel = something(
                format_selection(ROOT),
                sort!(
                    filter(
                        f -> endswith(f, ".jl") && !startswith(f, FIXTURES_PREFIX) && isfile(joinpath(ROOT, f)),
                        readlines(Cmd(`git ls-files`; dir = ROOT))
                    )
                ),
            )
            @test !isempty(sel)
            out = IOBuffer()
            ok = success(
                pipeline(
                    Cmd(`$JULIA --project=@runic -e 'using Runic; exit(Runic.main(ARGS))' -- --check --verbose $sel`; dir = ROOT, ignorestatus = true);
                    stdout = out, stderr = out
                )
            )
            report = String(take!(out))
            bad = [m.captures[1] for m in eachmatch(r"Checking `([^`]+)`[^\n]*✖", report)]
            @test ok || (println("Runic --check failed on template scripts: ", bad, "\n", report); false)
        end
    end
end
