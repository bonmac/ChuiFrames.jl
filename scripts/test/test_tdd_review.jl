# Tests for the fail-open paths a review of factory 0.3.0's tdd tooling found (spec §3.3-§3.5, §4.2,
# §4.3, §5.2). Included by runtests.jl right after test_tdd_classify2.jl: test_tdd.jl and
# _tdd_history.jl are at the 400-line budget. Reuses test_tdd.jl's host (TC, TDD_READY, TDD_FIX,
# TDD_VERSIONS, WR, tdd_out, tdd_spans, tdd_testset), test_tdd_history*.jl's helpers (th, th_testset,
# th_has, hr, stub, red, green, th_lane, th_ev!, th_red_ev!, th_lane_recs, th_slug, er, TW, IMPL) and
# runtests.jl's (tmp_repo, commit!, sh, capture). test_tdd_review2.jl holds the package-run cases.
#
# Rulings these tests pin (the lead's, 2026-10-26):
#
# - B1. A typo inside `@testset let` is WRONG-REASON. Julia 1.13 prints `Context: v = 1` between
#   `Expression:` and the exception line (fixture letctx-1.13.txt, review_tests.jl:10); 1.10 does not
#   (letctx-1.10.txt). The exception line is the first line after the markers that is not
#   `Expression:` or `Context:`.
# - M1. An item whose only failure is an `Unexpected Pass` (a `@test_broken` that now holds;
#   unexpected-pass-<v>.txt) is WRONG-REASON wherever `classify` decides: red, green and mutate.
# - M2. `requested` compares items without any line information, nested macrocalls' line slots
#   included: an item that only moved (a new item inserted above it) is not requested.
# - M3. Passing green evidence also carries tdd.jl's verdict: its `--- tdd ---` part holds the line
#   `green default suite: OK` (tdd.jl green). Passing mutate/mutexp evidence's tdd part holds
#   `KILLED` (_tdd_backfill.jl mutate: "KILLED: the item detects the mutation (exit 0)"). An `exit: 0`
#   alone is not a verdict (`evidence.jl green -- true` writes one).
# - B3. dod's `tdd` reads the commits of `<base>..<head>` (`--head`), not `<base>..HEAD`. A src/ext
#   change with no lane commits fails `tdd`; with `commits === nothing` it fails too, with the detail
#   "not checked: no lane history given".
# - Consecutive reds may be closed by one green (H6); each red keeps its own red evidence (E1).

"The span of `name` in scratchpkg's test/review_tests.jl."
trv_span(name) = only(filter(s -> s.name == name, tdd_spans("test/review_tests.jl")))
"Classify fixture `slug` for item `name` as red (and green: the same call) would."
trv_one(slug, name, v) = TC.classify(tdd_out(slug, v), [trv_span(name)], TC.ItemSpan[], Set([name]))
const TRV_GREEN_OK = "green items: OK (1 red item(s), run exit 0, total 1)\n  PASSED       g doubles\ngreen default suite: OK (exit 0)"
const TRV_KILLED = "mutate 0000000 item `f adds one`: src/P.jl:3 `+ 1` -> `+ 2`\nmutant run (scratch x): ASSERTION\n" *
    "real run: PASSED (exit 0)\nKILLED: the item detects the mutation (exit 0)"
"DoD's `tdd` row of evaluate, or nothing."
trv_tddrow(changed; kw...) = (r = last(DoD.evaluate(TRV_RISK, String.(changed), ["T1"], ""; kw...)); i = findfirst(x -> x[1] == "tdd", r); i === nothing ? nothing : r[i])
const TRV_RISK = Dict{String, Any}(
    "default_tier" => "T1", "protected" => Any[],
    "tiers" => Dict{String, Any}(t => Dict{String, Any}("requires" => (t == "T1" ? ["tdd"] : String[])) for t in ("T0", "T1", "T2", "T3"))
)

@testset "tdd review: classifier, history, evidence, dod (0.3.0)" begin
    tdd_testset("typo inside @testset let (Context: line) is WRONG-REASON") do
        for v in TDD_VERSIONS
            out = tdd_out("letctx", v)
            @test occursin("UndefVarError", out)                          # the fixture is the case
            v == "1.13" && @test occursin("Context: v = 1", out)
            h = only(TC.headers(out))
            @test h.kind == "Error During Test" && h.line == 10
            @test startswith(h.exc, "UndefVarError")                      # not the Context: line
            res = trv_one("letctx", "letctx", v)
            @test res == ["letctx" => WR]
            @test !TC.red_ok(res)
        end
    end

    tdd_testset("Unexpected Pass of @test_broken is WRONG-REASON") do
        for v in TDD_VERSIONS
            out = tdd_out("unexpected-pass", v)
            @test occursin("Unexpected Pass", out) && occursin("Test Summary:", out)
            h = only(TC.headers(out))
            @test h.kind == "Error During Test" && h.line == 4
            # red, green and mutate all decide by `classify(output, spans, ItemSpan[], matched)`;
            # mutate's item_run must not be the only place that sees it
            res = trv_one("unexpected-pass", "unexpected pass", v)
            @test res == ["unexpected pass" => WR]
            @test !TC.red_ok(res)
            @test !(:BEHAVIOUR in last.(res)) && !(:PASSED in last.(res))   # green needs PASSED; mutate red-ok
        end
    end

    tdd_testset("requested ignores items that only moved") do
        a0 = """
        @testitem "a" begin
            @test 1 == 1
            @testset "inner" begin
                @test 2 == 2
                let x = 1
                    @test x == 1
                end
            end
        end
        """
        d = tmp_repo(Dict("test/x_tests.jl" => a0, "src/X.jl" => "module X end\n"))
        new = "@testitem \"new\" begin\n    @test f(1) == 2\nend\n\n"
        commit!(d, Dict("test/x_tests.jl" => new * a0), "test: new\n\nTDD: red")
        r = TC.requested(d, "HEAD")
        @test [s.name for s in r.red] == ["new"]                          # "a" only moved down 4 lines
        @test isempty(r.must_pass)
        # a real change to the moved item is still requested
        commit!(d, Dict("test/x_tests.jl" => new * replace(a0, "@test 2 == 2" => "@test 2 == 3")), "test: a\n\nTDD: red")
        @test [s.name for s in TC.requested(d, "HEAD").red] == ["a"]
    end

    th_testset("H6: red, red, green passes", :LaneCommit, :history_rules) do
        v = hr(stub(), red(), red(), green())
        @test !th_has(v, "H6") && !th_has(v, "H7")
        @test isempty(v)
        @test isempty(hr(stub(), red(), lc(TW, "test-fix", "test/a_tests.jl"), red(), green()))
        # a red after a green opens a new cycle, which needs its own green
        @test th_has(hr(stub(), red(), red(), green(), red()), "H7")
        @test !th_has(hr(stub(), red(), green(), red(), red(), green()), "H6")
    end

    th_testset("green evidence without the tdd verdict fails E2", :lane_commits, :evidence_rules) do
        d, c = th_lane()
        th_red_ev!(d, c.red)
        recs = th_lane_recs(d, c)
        th_ev!(d, "green", c.green; tdd = TRV_GREEN_OK)
        @test !th_has(er(d, recs), "E2")                                   # control: the verdict passes
        th_ev!(d, "green", c.green)                                        # `evidence.jl green -- true`
        @test th_has(er(d, recs), "E2")
        th_ev!(d, "green", c.green; tdd = "green items: OK (1 red item(s), run exit 0, total 1)")
        @test th_has(er(d, recs), "E2")                                    # items only, no default suite
        th_ev!(d, "green", c.green; tdd = "green items: OK (1 red item(s))\ngreen default suite: NOT OK (exit 1)")
        @test th_has(er(d, recs), "E2")
    end

    th_testset("mutate evidence without KILLED fails E3", :lane_commits, :evidence_rules) do
        d = tmp_repo(Dict(".gitignore" => "/.lanes/\n/.worktrees/\n", "src/P.jl" => "module P\nf(x) = x + 1\nend\n"))
        sh(`git -C $d checkout -q -b lane`)
        b = th_commit!(d, TW, Dict("test/f_tests.jl" => "@testitem \"f adds one\" begin\n    using P\n    @test P.f(1) == 2\nend\n"), "test: backfill f\n\nTDD: backfill")
        recs = [th_rec("tdd-commit", "test-writer", d, b)]
        kind = "mutate-$(th_slug("f adds one"))"
        th_ev!(d, kind, b; tdd = TRV_KILLED)
        @test !th_has(er(d, recs), "E3")                                   # control
        th_ev!(d, kind, b)                                                 # `evidence.jl mutate-<slug> -- true`
        @test th_has(er(d, recs), "E3")
        th_ev!(d, kind, b; tdd = "SURVIVED: `f adds one` passes with the mutation (exit 1)")
        @test th_has(er(d, recs), "E3")
        rm(joinpath(d, ".lanes", "evidence", "$kind-$(first(b, 7)).txt"))
        th_ev!(d, "mutexp-$(th_slug("f adds one"))", b)                    # the fallback kind, no verdict
        @test th_has(er(d, recs), "E3")
    end

    @testset "dod tdd with --head reads the head's commits" begin
        d = tmp_repo(Dict("risk.toml" => seed_fixture("risk.toml"), "src/A.jl" => "x\n"))
        sh(`git -C $d checkout -q -b feat/x`)
        commit!(d, Dict("src/A.jl" => "y\n"), "feat: A, no TDD trailer")
        rc, out = capture(() -> DoD.main(["--root", d, "--base", "main", "--labels", "T1"]))
        @test rc == 1 && occursin(r"\[FAIL\] tdd +H1", out) || (print(out); false)   # control: on the branch
        sh(`git -C $d checkout -q main`)
        rc, out = capture(() -> DoD.main(["--root", d, "--base", "main", "--head", "feat/x", "--labels", "T1"]))
        @test rc == 1
        @test occursin(r"\[FAIL\] tdd +H1", out) || (print(out); false)
        @test !occursin("0 commits", out)
    end

    @testset "tdd fails when src changed but no lane commits found" begin
        r = trv_tddrow(["src/A.jl"]; commits = DoD.LaneCommit[], stub_ok = _ -> true)
        @test r !== nothing && r[2] == :fail || (@show r; false)
        r = trv_tddrow(["docs/x.md"]; commits = DoD.LaneCommit[], stub_ok = _ -> true)
        @test r !== nothing && r[2] == :pass                               # control: no code, no lane needed
    end

    @testset "evaluate with commits === nothing and a src change fails tdd" begin
        @test trv_tddrow(["src/A.jl"]) == ("tdd", :fail, "not checked: no lane history given")
        @test trv_tddrow(["ext/AExt.jl"]; commits = nothing) == ("tdd", :fail, "not checked: no lane history given")
        r = trv_tddrow(["docs/x.md"])
        @test r !== nothing && r[2] == :pass                               # control
    end
end

include("test_tdd_review2.jl")   # B2, green after two reds, mutate arguments and evidence (package runs)
