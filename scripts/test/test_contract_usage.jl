@testset "contract_usage.jl" begin
    CU = ContractUsage
    @test CU.check(mktempdir()) === nothing                        # no USED.md (the coordinator): skipped
    @test capture(() -> CU.main(["--root", mktempdir()]))[1] == 0
    if IN_FACTORY
        # the seeded USED.md lists nothing (its example sits in a comment) and the template is
        # consistent. Only here: a vendored repo's USED.md is its own (the coordinator has none),
        # and `ci.jl guards` runs contract_usage.jl on it.
        @test isempty(CU.parse_used(read(joinpath(ROOT, "test/contracts/USED.md"), String)))
        errs, warns, _ = CU.check(ROOT)
        @test isempty(errs) && isempty(warns)
        @test haskey(TOML.parsefile(joinpath(ROOT, "test/contracts/upstreams.toml")), "contract_files")
    end

    @testset "USED.md lines" begin
        md = "# x\n- CC-004 — aggregators\n* CF-002\n- CC-004 again\nprose CC-009 is not a bullet\n<!-- - CT-001 -->\n```\n- CT-002\n```\n"
        @test CU.parse_used(md) == ["CC-004", "CF-002"]
    end

    @testset "grep of qualified upstream names" begin
        code = """
        using ChuiCore: compose, ⨟, fmap as fm
        import ChuiTypes: Effect
        x = ChuiCore.pure(1) |> ChuiCore.:⨟   # ChuiCore.commented
        y = ChuiCoreExtra.thing; z = NotChuiCore.thing
        """
        @test CU.used_names(code, ["ChuiCore", "ChuiTypes"]) ==
            Set(["ChuiCore.compose", "ChuiCore.⨟", "ChuiCore.fmap", "ChuiTypes.Effect", "ChuiCore.pure"])
        # parenthesised operators; #= =# block comments (0.2.1 review)
        @test CU.used_names("using ChuiCore: (⨟), init\nf = ChuiCore.:(⨟)\n", ["ChuiCore"]) == Set(["ChuiCore.⨟", "ChuiCore.init"])
        @test CU.used_names("#= old:\nChuiCore.Sum()\n=#\nChuiCore.pure(1)\n", ["ChuiCore"]) == Set(["ChuiCore.pure"])
    end

    contract = """
    # chui-core contract
    ### CC-001 `⨟` composes
    `since=0.0.1 status=stable`
    names: `ChuiCore.:⨟`, `ChuiCore.opcompose`
    ### CC-002 Old thing
    `since=0.0.1 status=retired`
    names: `ChuiCore.old`
    ### CC-003 Aggregators
    `since=0.0.1 status=deprecated`
    #### Details
    names: `ChuiCore.init`
    ### CC-004 Rule only
    `since=0.0.1 status=stable`
    ### CC-005 No status line
    names: `ChuiCore.broken`
    ## PROVISIONAL
    #### lazy
    names: `ChuiCore.lazy`
    """

    @testset "contract file parsing" begin
        e = CU.parse_contract(contract)
        @test e["CC-001"] == ("stable", ["ChuiCore.⨟", "ChuiCore.opcompose"])
        @test e["CC-002"][1] == "retired" && e["CC-003"] == ("deprecated", ["ChuiCore.init"])  # #### stays in the entry
        @test e["CC-004"] == ("stable", String[]) && e["CC-005"][1] == "invalid"
        @test !any(v -> "ChuiCore.lazy" in v[2], values(e))        # PROVISIONAL contributes no names
        # 0.2.1 review: status needs a whole word; a fence closes only on its own character;
        # a `# ` heading ends an entry; a repeated ID is flagged
        @test CU.parse_contract("### CC-001 x\n`since=0.1 status=stable-ish`\n")["CC-001"][1] == "invalid"
        e2 = CU.parse_contract("### CC-001 x\n`since=0.1 status=stable`\n```\n~~~\nnames: `ChuiCore.in_fence`\n```\nnames: `ChuiCore.a`\n# Top\nnames: `ChuiCore.b`\n")
        @test e2["CC-001"] == ("stable", ["ChuiCore.a"])
        @test CU.parse_contract("### CC-001 x\n`since=0.1 status=stable`\n### CC-001 y\n`since=0.1 status=stable`\n")["CC-001"][1] == "duplicate"
    end

    @testset "the cross-checks" begin
        files = Dict(
            "test/contracts/upstreams.toml" => """
                [upstreams]
                ChuiCore = "https://example.org/ChuiCore.jl"
                [contract_files]
                ChuiCore = "test/contracts/chui-core.md"
                """,
            "test/contracts/chui-core.md" => contract,
            "test/contracts/USED.md" => "- CC-001 — composition\n- CC-004\n",
            "test/contracts/core.jl" => """
                @testitem "CC-001 ⨟ composes" tags = [:contract] begin end
                @testitem "CC-004 rule" tags = [:contract] begin end
                """,
            "src/P.jl" => "module P\nusing ChuiCore: ⨟\nf = ChuiCore.opcompose\nend\n"
        )
        r = tmp_repo(files)
        errs, warns, summary = CU.check(r)
        @test (isempty(errs) && isempty(warns)) || (foreach(println, [errs; warns]); false)
        @test occursin("2 IDs listed, 2 tested, 2 upstream names used", summary)

        # unmapped name: a warning, an error under --strict
        commit!(r, Dict("ext/E.jl" => "ChuiCore.lazy(x)\n"))
        errs, warns, _ = CU.check(r)
        @test isempty(errs) && length(warns) == 1 && occursin("ChuiCore.lazy", warns[1])
        @test length(first(CU.check(r; strict = true))) == 1
        @test capture(() -> CU.main(["--root", r]))[1] == 0
        @test capture(() -> CU.main(["--root", r, "--strict"]))[1] == 1

        # every kind of error at once
        commit!(
            r, Dict(
                "test/contracts/USED.md" => "- CC-001\n- CC-004\n- CC-002\n- CC-003\n- CC-099\n- CC-005\n",
                "test/contracts/more.jl" => """
                    @testitem "CC-002 old" tags = [:contract] begin end
                    @testitem "CC-003 agg" tags = [:contract] begin @test_skip false end
                    @testitem "CC-004 again" begin end
                    @testitem "CC-005 x" begin end
                    @testitem "CC-007 unlisted" begin end
                    """,
                "src/Q.jl" => "using ChuiCore: init\nChuiTypes.x\n"
            )
        )
        errs, warns, _ = CU.check(r)
        has(p) = any(e -> occursin(p, e), errs) || (println("missing error: ", p, "\n  got: ", errs); false)
        @test has("CC-099 is listed in USED.md but has no `@testitem")           # untested (and unknown)
        @test has("CC-099 is listed in USED.md but is in no contract file")
        @test has("CC-004 has 2 contract test items")
        @test has("CC-007 has a contract test item")
        @test has("@test_skip/@test_broken in a contract test")
        @test has("CC-002 is status=retired")
        @test has("CC-005's header is not followed")
        @test any(w -> occursin("CC-003 is status=deprecated", w), warns)
        # ChuiTypes is not in upstreams.toml, so its names are not grepped at all; init maps to deprecated CC-003, listed
        @test !any(e -> occursin("ChuiCore.init", e), errs)
        commit!(r, Dict("test/contracts/USED.md" => "- CC-001\n- CC-004\n"))
        @test any(e -> occursin("ChuiCore.init is covered by CC-003, which USED.md does not list", e), first(CU.check(r)))

        # a missing contract file, and --contracts DIR reading it from elsewhere by basename
        mv(joinpath(r, "test/contracts/chui-core.md"), joinpath(r, "elsewhere.md"))
        @test any(e -> occursin("contract file for ChuiCore not found", e), first(CU.check(r)))
        alt = mktempdir(); cp(joinpath(r, "elsewhere.md"), joinpath(alt, "chui-core.md"))
        @test !any(e -> occursin("not found", e), first(CU.check(r; contracts = alt)))
        # a used upstream with no contract file configured
        commit!(r, Dict("test/contracts/upstreams.toml" => "[upstreams]\nChuiCore = \"u\"\n"))
        @test any(e -> occursin("has no contract file", e), first(CU.check(r)))
    end

    @testset "0.2.1 review: contract_files-only upstreams, commented-out and untagged items" begin
        r = tmp_repo(
            Dict(
                # no URL yet: the upstream is named only in [contract_files], and its names are still grepped
                "test/contracts/upstreams.toml" => "[upstreams]\n[contract_files]\nChuiCore = \"test/contracts/chui-core.md\"\n",
                "test/contracts/chui-core.md" => contract,
                "test/contracts/USED.md" => "- CC-001\n",
                "test/contracts/c.jl" => "# @testitem \"CC-001 commented out\" tags = [:contract] begin end\n" *
                    "#=\n@testitem \"CC-001 in a block comment\" tags = [:contract] begin end\n=#\n",
                "src/P.jl" => "using ChuiCore: ⨟, init\n"
            )
        )
        errs, _, summary = CU.check(r)
        @test any(e -> occursin("CC-001 is listed in USED.md but has no `@testitem", e), errs)   # comments are not tests
        @test any(e -> occursin("ChuiCore.init is covered by CC-003", e), errs)                   # grepped without a URL
        @test occursin("2 upstream names used", summary)                                          # ⨟ and init
        commit!(r, Dict("test/contracts/c.jl" => "@testitem \"CC-001 composes\" begin end\n", "src/P.jl" => "using ChuiCore: ⨟\n"))
        errs, _, _ = CU.check(r)
        @test errs == ["test/contracts/c.jl:1 (CC-001): contract test item not tagged `:contract` (`tags = [:contract]`); ci.jl contracts runs only those"]
        commit!(r, Dict("test/contracts/c.jl" => "@testitem \"CC-001 composes\" tags = [:unit, :contract] begin end\n"))
        @test isempty(first(CU.check(r)))
    end

    if IN_FACTORY && isdir(joinpath(FACTORY, "..", "contracts"))
        @testset "against the coordinator's contracts/ (read only)" begin
            cdir = normpath(joinpath(FACTORY, "..", "contracts"))
            r = tmp_repo(
                Dict(
                    "test/contracts/upstreams.toml" => "[upstreams]\nChuiCore = \"u\"\n[contract_files]\nChuiCore = \"test/contracts/chui-core.md\"\n",
                    "test/contracts/USED.md" => "- CC-001\n- CC-002\n- CC-004\n- CC-006\n- CC-003\n",
                    "test/contracts/c.jl" => join(("@testitem \"$id t\" tags = [:contract] begin end\n" for id in ("CC-001", "CC-002", "CC-004", "CC-006", "CC-003"))),
                    "src/P.jl" => "using ChuiCore: ⨟, init, partial, combine, final\nChuiCore.Sum\n"
                )
            )
            errs, _, _ = CU.check(r; contracts = cdir)
            @test any(e -> occursin("CC-003 is status=retired", e), errs)                   # retired in chui-core.md
            @test any(e -> occursin("ChuiCore.Sum is covered by CC-007", e), errs)
            @test !any(e -> occursin("ChuiCore.⨟", e) || occursin("ChuiCore.init", e), errs) # CC-001/002/004/006 listed
        end
    end
end
