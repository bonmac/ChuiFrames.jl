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

# factory 0.3.2 (lane tw-035): the 0.3.1 exclusion matched only at the repo root. The coordinator
# vendors the template at factory/template/, so there format_files selected
# factory/template/scripts/test/fixtures/** and Runic hit parse_tests.jl's ParseError (sync-031
# evidence tests-8028094.txt: 3 fails here). "Under scripts/test/fixtures/" is read as whole path
# segments at any depth: a/b/scripts/test/fixtures/x.jl is under it; myscripts/test/fixtures/x.jl
# and scripts/test/fixtures.jl are not.
"True when `rel` lies under a `scripts/test/fixtures/` directory at any depth (whole path segments)."
in_fixtures(rel) = startswith(rel, FIXTURES_PREFIX) || occursin("/" * FIXTURES_PREFIX, rel)

"""
    runic_scope(root, sel) -> Vector{String}

Test policy (0.3.2), not ci.jl behaviour: the files of the format selection `sel` that the
Runic-clean item checks, the factory-managed scripts only. In the template (inside factory/, or
`root` has no `.factory-version`) all of `sel`. In a synced host, the keys of `[managed]` in its
`.factory-version`, plus a vendored template under `factory/template/scripts/` (the coordinator).
A host's own files (the coordinator's contracts/*.jl, reference/prototype/**) are not the
factory's to format; in the coordinator they made this item fail (tests-8028094.txt, :108).
"""
function runic_scope(root, sel)
    fv = joinpath(root, ".factory-version")
    ((root == ROOT && IN_FACTORY) || !isfile(fv)) && return sel
    managed = Set(keys(get(TOML.parsefile(fv), "managed", Dict())))
    return filter(f -> f in managed || startswith(f, "factory/template/scripts/"), sel)
end

@testset "ci.jl format selects its files (0.3.1 finding 1)" begin
    @testset "CI.format_files exists" begin
        @test isdefined(CI, :format_files)
    end

    @testset "template: fixtures excluded, ordinary scripts selected" begin
        sel = format_selection(ROOT)
        @test sel isa Vector{String}
        if sel isa Vector{String}
            @test !isempty(sel)
            bad = filter(in_fixtures, sel)    # at any depth: a coordinator's ROOT vendors factory/template/
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

    @testset "a vendored template: fixtures excluded under any directory, in git and outside (0.3.2)" begin
        files = Dict(
            "scripts/ci.jl" => "y = 2\n",
            "factory/template/scripts/ci.jl" => "y = 2\n",
            "factory/template/scripts/test/runtests.jl" => "z = 3\n",
            "factory/template/scripts/test/fixtures/x.jl" => "function (\n",
            "factory/template/scripts/test/fixtures/tdd/scratchpkg/test/parse_tests.jl" => "end end\n",
            "a/b/scripts/test/fixtures/deep.jl" => "end\n",
            "myscripts/test/fixtures/a.jl" => "a = 1\n",       # not a scripts/ segment: kept
            "scripts/test/fixtures.jl" => "b = 2\n",           # a file, not under the directory: kept
        )
        kept = sort!(
            [
                "factory/template/scripts/ci.jl", "factory/template/scripts/test/runtests.jl",
                "myscripts/test/fixtures/a.jl", "scripts/ci.jl", "scripts/test/fixtures.jl",
            ]
        )
        plain = mktempdir()                                    # the walk fallback (no git)
        for (rel, c) in files
            mkpath(dirname(joinpath(plain, rel)))
            write(joinpath(plain, rel), c)
        end
        for d in (tmp_repo(files), plain)
            sel = format_selection(d)
            @test sel isa Vector{String}
            sel isa Vector{String} || continue
            bad = filter(in_fixtures, sel)
            @test isempty(bad) || (println("format_files selected nested fixtures: ", bad); false)
            @test !("factory/template/scripts/test/fixtures/tdd/scratchpkg/test/parse_tests.jl" in sel)
            @test sel == kept || (println("format_files: got ", sel, ", want ", kept); false)
        end
    end

    @testset "the Runic-clean item covers only factory-managed scripts (0.3.2, test policy)" begin
        sel = [
            "contracts/bad.jl", "factory/template/scripts/ci.jl", "reference/prototype/Tidy.jl",
            "scripts/ci.jl", "scripts/test/test_x.jl",
        ]
        fv = "version = \"0.3.1\"\nprofile = \"coordinator\"\n\n[managed]\n\"scripts/ci.jl\" = \"ab\"\n\"scripts/test/test_x.jl\" = \"cd\"\n"
        host = tmp_repo(Dict(".factory-version" => fv, "contracts/bad.jl" => "x=[1,2 ,3]\n"))
        scope = runic_scope(host, sel)
        @test !("contracts/bad.jl" in scope) && !("reference/prototype/Tidy.jl" in scope)
        @test scope == ["factory/template/scripts/ci.jl", "scripts/ci.jl", "scripts/test/test_x.jl"]
        @test runic_scope(mktempdir(), sel) == sel             # the template: no .factory-version
        @test runic_scope(tmp_repo(Dict(".factory-version" => "version = \"0.3.1\"\n")), sel) == ["factory/template/scripts/ci.jl"]
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

    @testset "every selected factory-managed script is Runic-clean" begin
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
            # The format selection, narrowed to the factory-managed scripts (runic_scope, 0.3.2).
            sel = runic_scope(ROOT, something(format_selection(ROOT), String[]))
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
            @test ok || (println("Runic --check failed on factory-managed scripts: ", bad, "\n", report); false)
        end
    end
end
