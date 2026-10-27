# More tests for scripts/_tdd_classify.jl (spec §3.3, WRONG-REASON). Included by runtests.jl right
# after test_tdd_backfill.jl, because test_tdd.jl is at its 400-line budget. test_tdd.jl's host
# (TddClassifyHost as TC, TDD_READY, TDD_FIX, WR, tdd_span) is reachable from here; while any of those
# names, or the classifier, is missing, the testset fails instead of erroring the suite.
#
# Inputs: fixtures/tdd/precompile-fail-<v>.txt, a scratch copy of scratchpkg whose src/TddScratch.jl
# does not parse, run with item=assert (header line of each file). The package fails to precompile,
# so the `assert` item errors before its body runs: Pkg prints `Failed to precompile TddScratch [...]`
# (1.13 after `The following 1 package failed to precompile:`), and the item's header is
# `assert: Error During Test at .../test/items_tests.jl:2` with that as its exception, followed by a
# `Test Summary:`. A package that does not load is a wrong reason to be red, not BEHAVIOUR.

const TDD2_NAMES = (:TC, :TDD_READY, :TDD_FIX, :WR, :tdd_span)

@testset "_tdd_classify.jl, more WRONG-REASON cases" begin
    @testset "package that fails to precompile is WRONG-REASON" begin
        missing_names = [n for n in TDD2_NAMES if !isdefined(Main, n)]
        @test isempty(missing_names)
        if isempty(missing_names) && TDD_READY && isdefined(TC, :red_ok)
            for v in ("1.13", "1.10")
                out = read(joinpath(TDD_FIX, "precompile-fail-$v.txt"), String)
                @test occursin("Failed to precompile TddScratch", out)   # the fixture is the case
                res = TC.classify(out, [tdd_span("assert")], TC.ItemSpan[], Set(["assert"]))
                @test res == ["assert" => WR]
                @test !TC.red_ok(res)
            end
        elseif isempty(missing_names)
            @test TDD_READY && isdefined(TC, :red_ok)   # the classifier is missing
        end
    end
end
