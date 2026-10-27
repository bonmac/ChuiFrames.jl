# Tests for scripts/_tdd_classify.jl (factory 0.3.0, plan Task 3; spec §3.3, §3.4).
# Inputs: the measured outputs in fixtures/tdd/ (README.md there), on Julia 1.13 and 1.10.
#
# Representation choices the implementer follows (decided from the spec by the test writer):
#
# - Hosting. _tdd_classify.jl holds top-level definitions, no `module` of its own: tdd.jl's
#   `module Tdd` includes _common.jl and then _tdd_classify.jl. These tests do the same in a fresh
#   module, TddClassifyHost (`using TOML`, include _common.jl, include _tdd_classify.jl), so the
#   classifier may use _common.jl's helpers (`git`, ...) but must not include _common.jl itself.
# - Classes are Symbols: :ASSERTION, :BEHAVIOUR, Symbol("WRONG-REASON"), :PASSED, Symbol("NOT-RUN"),
#   :COLLATERAL. HELPER is not a class.
# - `item_spans(text, file)` stores `file` verbatim in each ItemSpan. `first` is the `@testitem` line;
#   `last` is at least the line of the item's last statement and below the next item's first line.
#   `setup` holds the names in `setup = [...]`, in order. `@testmodule`/`@testsnippet` are not items.
# - `requested(root, rev)` returns `(red = Vector{ItemSpan}, must_pass = Vector{ItemSpan})`, with
#   `file` relative to `root` (e.g. "test/a_tests.jl"), the spans as of `rev`.
# - `classify(output, red, must_pass, matched)`: `red` and `must_pass` are Vector{ItemSpan}; `matched`
#   holds the names from TDD_MATCHED. A header belongs to a span when its line is in first:last and
#   its file is the span's file or ends with "/" * span.file (span files may be root-relative; the
#   output's files are absolute).
# - The result is `Vector{Pair{String, Symbol}}`, item name => class:
#   - one pair per `red` item, in `red`'s order;
#   - a `must_pass` item appears only when it is not fine: COLLATERAL (a header in its span), NOT-RUN
#     (not in `matched`), or WRONG-REASON (no `Test Summary:` or `termsignal != 0`, which make every
#     red and must_pass item WRONG-REASON). A passing must_pass item is omitted;
#   - a header in no given span adds a pair `"<header file>:<line>" => WRONG-REASON`.
#   An item with any WRONG-REASON header is WRONG-REASON, even if it also has an ASSERTION or
#   BEHAVIOUR header.
# - `red_ok(result)` is true iff `result` is non-empty and every class is :ASSERTION or :BEHAVIOUR.
# - `headers(output)`: one NamedTuple per header line, in output order, with
#   `prefix::String` (the testset name before ": "), `kind::String` ("Test Failed" or
#   "Error During Test", verbatim), `file::String` (verbatim from the header), `line::Int`,
#   `exc::String` (the exception line, stripped, one "LoadError: " removed), `thrown`
#   (`nothing`, or the type after "Thrown: " in a @test_throws block, e.g. "MethodError"), and
#   `helper` (`nothing`, or "<file>:<line>" of the block's first stacktrace frame when that frame is
#   a `test/` file other than the header's file).
# - HELPER is surfaced only by `report(io, result, hdrs)`: it prints each item with its class, and
#   for a header with a `helper` it prints "HELPER <helper>". The class is unchanged.
using TOML

const TDD_CLASSIFY_PATH = joinpath(SCRIPTS, "_tdd_classify.jl")
module TddClassifyHost
    using TOML
    include(joinpath(Main.SCRIPTS, "_common.jl"))
    # The classifier does not exist before the GREEN step: the guarded include keeps the rest of
    # the factory suite running, and every testset below fails instead.
    isfile(Main.TDD_CLASSIFY_PATH) && include(joinpath(Main.SCRIPTS, "_tdd_classify.jl"))
end
const TC = TddClassifyHost
const TDD_READY = isdefined(TC, :classify) && isdefined(TC, :ItemSpan)

const TDD_FIX = joinpath(@__DIR__, "fixtures", "tdd")
const TDD_PKG = joinpath(TDD_FIX, "scratchpkg")
const TDD_RECORDED = "<PKG>"   # the masked package root in the recorded outputs (fixtures/tdd/README.md)
const TDD_VERSIONS = ("1.13", "1.10")
const WR = Symbol("WRONG-REASON")
const NR = Symbol("NOT-RUN")

"A fixture output, with the recorded package path mapped to where the fixture is now."
tdd_out(slug, v) = replace(read(joinpath(TDD_FIX, "$slug-$v.txt"), String), TDD_RECORDED => TDD_PKG)
tdd_spans(rel) = TC.item_spans(read(joinpath(TDD_PKG, rel), String), rel)
function tdd_span(name)
    # parse_tests.jl does not parse (that is its point), so its span is written by hand.
    name == "parse error" && return TC.ItemSpan("parse error", "test/parse_tests.jl", 1, 3, String[])
    for rel in ("test/items_tests.jl", "test/setup_tests.jl", "test/killed_tests.jl")
        i = findfirst(s -> s.name == name, tdd_spans(rel))
        i === nothing || return tdd_spans(rel)[i]
    end
    return error("no span for $name")
end
"Classify one fixture run of one requested item, as tdd.jl red would."
tdd_one(slug, item, v; matched = Set([item]), kw...) = TC.classify(tdd_out(slug, v), [tdd_span(item)], TC.ItemSpan[], matched; kw...)
"A named testset that fails (instead of erroring the suite) while the classifier is missing."
tdd_testset(f, name) = @testset "$name" begin
    if TDD_READY
        f()
    else
        @test isfile(TDD_CLASSIFY_PATH)   # RED: scripts/_tdd_classify.jl does not exist yet
    end
end

@testset "_tdd_classify.jl (0.3.0)" begin
    tdd_testset("assert is ASSERTION") do
        for v in TDD_VERSIONS
            res = tdd_one("assert", "assert", v)
            @test res == ["assert" => :ASSERTION]
            @test TC.red_ok(res)
            h = TC.headers(tdd_out("assert", v))
            @test length(h) == 1
            @test keys(h[1]) == (:prefix, :kind, :file, :line, :exc, :thrown, :helper)
            @test h[1].prefix == "assert" && h[1].kind == "Test Failed" && h[1].line == 2
            @test endswith(h[1].file, "scratchpkg/test/items_tests.jl")
            @test h[1].thrown === nothing && h[1].helper === nothing
        end
    end

    tdd_testset("stub in test is BEHAVIOUR") do
        for v in TDD_VERSIONS
            res = tdd_one("stub-in-test", "stub in test", v)
            @test res == ["stub in test" => :BEHAVIOUR]
            @test TC.red_ok(res)
            h = only(TC.headers(tdd_out("stub-in-test", v)))
            @test h.kind == "Error During Test" && h.line == 6
            @test startswith(h.exc, "MethodError: no method matching f(::Int64)")
        end
    end

    tdd_testset("stub outside test is BEHAVIOUR (LoadError prefix stripped)") do
        for v in TDD_VERSIONS
            res = tdd_one("stub-outside-test", "stub outside test", v)
            @test res == ["stub outside test" => :BEHAVIOUR]
            @test TC.red_ok(res)
            h = only(TC.headers(tdd_out("stub-outside-test", v)))
            @test h.line == 10
            @test startswith(h.exc, "MethodError: no method matching f(::Int64)")
            @test !occursin("LoadError", h.exc)
        end
    end

    tdd_testset("new method on existing g is BEHAVIOUR") do
        for v in TDD_VERSIONS
            res = tdd_one("new-method-on-existing-g", "new method on existing g", v)
            @test res == ["new method on existing g" => :BEHAVIOUR]
            @test TC.red_ok(res)
            h = only(TC.headers(tdd_out("new-method-on-existing-g", v)))
            @test startswith(h.exc, "MethodError: no method matching +(::String, ::Int64)")
            @test h.helper === nothing                          # first frame is src/, not test/
        end
    end

    tdd_testset("typo and typo outside are WRONG-REASON") do
        for v in TDD_VERSIONS
            res = tdd_one("typo", "typo", v)
            @test res == ["typo" => WR]
            @test !TC.red_ok(res)
            @test startswith(only(TC.headers(tdd_out("typo", v))).exc, "UndefVarError")
            res = tdd_one("typo-outside", "typo outside", v)
            @test res == ["typo outside" => WR]
            @test !TC.red_ok(res)
            @test startswith(only(TC.headers(tdd_out("typo-outside", v))).exc, "UndefVarError")   # LoadError stripped
            # a broken @testmodule is the same wrong reason (UndefVarError at load)
            @test tdd_one("setup-module", "setup module", v) == ["setup module" => WR]
        end
    end

    tdd_testset("test_throws hiding UndefVarError is wrong-reason") do
        for v in TDD_VERSIONS
            res = tdd_one("throws-typo", "throws typo", v)
            @test res == ["throws typo" => WR]
            @test !TC.red_ok(res)
            h = only(TC.headers(tdd_out("throws-typo", v)))
            @test h.kind == "Test Failed" && h.line == 37
            @test h.thrown == "UndefVarError"
        end
    end

    tdd_testset("throws wrong with Thrown: MethodError is ASSERTION") do
        for v in TDD_VERSIONS
            res = tdd_one("throws-wrong", "throws wrong", v)
            @test res == ["throws wrong" => :ASSERTION]
            @test TC.red_ok(res)
            h = only(TC.headers(tdd_out("throws-wrong", v)))
            @test h.kind == "Test Failed" && h.line == 33
            @test h.thrown == "MethodError"
        end
    end

    tdd_testset("helper is BEHAVIOUR with HELPER flag") do
        for v in TDD_VERSIONS
            out = tdd_out("helper", v)
            res = tdd_one("helper", "helper", v)
            @test res == ["helper" => :BEHAVIOUR]
            @test TC.red_ok(res)
            hdrs = TC.headers(out)
            h = only(hdrs)
            @test h.line == 25 && startswith(h.exc, "AssertionError: helper")
            @test h.helper !== nothing && endswith(h.helper, "test/helpers.jl:1")
            rep = sprint(TC.report, res, hdrs)
            @test occursin("helper", rep) && occursin("BEHAVIOUR", rep)
            @test occursin("HELPER", rep) && occursin("helpers.jl:1", rep)
            # no other fixture's first frame is another test/ file
            for slug in ("assert", "stub-in-test", "stub-outside-test", "typo", "typo-outside", "throws-wrong",
                    "throws-typo", "nested", "parse-error", "setup-module")
                @test all(x -> x.helper === nothing, TC.headers(tdd_out(slug, v)))
            end
            areport = sprint(TC.report, tdd_one("assert", "assert", v), TC.headers(tdd_out("assert", v)))
            @test occursin("ASSERTION", areport) && !occursin("HELPER", areport)
        end
    end

    tdd_testset("nested testset prefix still attributed by span") do
        for v in TDD_VERSIONS
            h = only(TC.headers(tdd_out("nested", v)))
            @test h.prefix == "inner" && h.line == 46
            res = tdd_one("nested", "nested", v)
            @test res == ["nested" => :ASSERTION]
            @test TC.red_ok(res)
        end
    end

    tdd_testset("Some tests did not pass line ignored") do
        for v in TDD_VERSIONS
            for slug in ("assert", "stub-in-test", "stub-outside-test", "typo", "typo-outside", "helper",
                    "throws-wrong", "throws-typo", "new-method-on-existing-g", "nested", "parse-error", "setup-module")
                out = tdd_out(slug, v)
                @test occursin("Some tests did not pass", out)            # the fixture has the line ...
                hdrs = TC.headers(out)
                @test length(hdrs) == 1                                    # ... and it is not a header
                @test !occursin("Some tests did not pass", only(hdrs).exc)
            end
        end
        out = "ERROR: LoadError: Some tests did not pass: 0 passed, 1 failed, 0 errored, 0 broken.\n" *
            "Test Summary: | Pass  Total\nTddScratch    |    1      1\n"
        @test isempty(TC.headers(out))
        @test TC.classify(out, [tdd_span("passes")], TC.ItemSpan[], Set(["passes"])) == ["passes" => :PASSED]
    end

    tdd_testset("parse error is WRONG-REASON") do
        for v in TDD_VERSIONS
            h = only(TC.headers(tdd_out("parse-error", v)))
            @test h.line == 2 && endswith(h.file, "test/parse_tests.jl")
            @test startswith(h.exc, "ParseError")                         # LoadError stripped
            res = tdd_one("parse-error", "parse error", v)
            @test res == ["parse error" => WR]
            @test !TC.red_ok(res)
        end
    end

    tdd_testset("passes is PASSED") do
        for v in TDD_VERSIONS
            @test isempty(TC.headers(tdd_out("passes", v)))
            res = tdd_one("passes", "passes", v)
            @test res == ["passes" => :PASSED]
            @test !TC.red_ok(res)                                         # a passing requested item is not red
        end
    end

    tdd_testset("unmatched requested item is NOT-RUN") do
        for v in TDD_VERSIONS
            # item=nosuch: exit 0, Total 0, nothing matched
            res = TC.classify(tdd_out("none", v), [tdd_span("assert")], TC.ItemSpan[], Set{String}())
            @test res == ["assert" => NR]
            @test !TC.red_ok(res)
            # two requested, one matched
            res = TC.classify(tdd_out("passes", v), [tdd_span("passes"), tdd_span("assert")], TC.ItemSpan[], Set(["passes"]))
            @test res == ["passes" => :PASSED, "assert" => NR]
            # an unmatched must_pass item is reported too
            res = TC.classify(tdd_out("assert", v), [tdd_span("assert")], [tdd_span("passes")], Set(["assert"]))
            @test res == ["assert" => :ASSERTION, "passes" => NR]
            @test !TC.red_ok(res)
        end
    end

    tdd_testset("failure in a must_pass item is COLLATERAL") do
        for v in TDD_VERSIONS
            res = TC.classify(tdd_out("assert", v), [tdd_span("passes")], [tdd_span("assert")], Set(["passes", "assert"]))
            @test length(res) == 2 && Dict(res) == Dict("passes" => :PASSED, "assert" => :COLLATERAL)
            @test !TC.red_ok(res)
            # a must_pass item that passes is not listed, and the red item stays red
            res = TC.classify(tdd_out("assert", v), [tdd_span("assert")], [tdd_span("passes")], Set(["passes", "assert"]))
            @test res == ["assert" => :ASSERTION]
            @test TC.red_ok(res)
        end
    end

    tdd_testset("header outside every span is WRONG-REASON") do
        for v in TDD_VERSIONS
            # the assert header (items_tests.jl:2) lies in no given span
            res = TC.classify(tdd_out("assert", v), [tdd_span("passes")], TC.ItemSpan[], Set(["passes"]))
            @test length(res) == 2
            @test res[1] == ("passes" => :PASSED)
            @test res[2].second == WR && endswith(res[2].first, "test/items_tests.jl:2")
            @test !TC.red_ok(res)
            # a span with the same lines in another file does not claim the header
            other = TC.ItemSpan("assert", "test/other_tests.jl", 1, 3, String[])
            res = TC.classify(tdd_out("assert", v), [other], TC.ItemSpan[], Set(["assert"]))
            @test Dict(res)["assert"] == :PASSED
            @test any(p -> p.second == WR && endswith(p.first, "items_tests.jl:2"), res)
            @test !TC.red_ok(res)
        end
    end

    tdd_testset("no Test Summary is WRONG-REASON") do
        for v in TDD_VERSIONS
            out = tdd_out("killed", v)
            @test !occursin("Test Summary:", out) && isempty(TC.headers(out))
            res = TC.classify(out, [tdd_span("killed")], TC.ItemSpan[], Set(["killed"]))
            @test res == ["killed" => WR]
            @test !TC.red_ok(res)
            # a failing item whose run lost its summary is not red either
            cut = replace(tdd_out("assert", v), "Test Summary:" => "Test Overview:")
            res = TC.classify(cut, [tdd_span("assert")], TC.ItemSpan[], Set(["assert"]))
            @test res == ["assert" => WR]
            @test !TC.red_ok(res)
        end
    end

    tdd_testset("termsignal 15 is WRONG-REASON for all") do
        for v in TDD_VERSIONS
            res = TC.classify(tdd_out("assert", v), [tdd_span("assert")], [tdd_span("passes")], Set(["assert", "passes"]); termsignal = 15)
            @test length(res) == 2 && Dict(res) == Dict("assert" => WR, "passes" => WR)
            @test !TC.red_ok(res)
            @test tdd_one("passes", "passes", v; termsignal = 15) == ["passes" => WR]
            @test tdd_one("assert", "assert", v; termsignal = 0) == ["assert" => :ASSERTION]
        end
    end

    tdd_testset("item_spans finds nested begin/end") do
        text = """
        @testitem "outer" tags = [:a] begin
            let x = 1
                if x == 1
                    begin
                        @test x == 1
                    end
                end
            end
        end

        @testsnippet Snip begin
            y = 2
        end

        @testitem "after" setup = [Snip, Shared] begin
            @test y == 2
        end
        """
        sp = TC.item_spans(text, "test/x_tests.jl")
        @test [s.name for s in sp] == ["outer", "after"]
        @test sp[1].file == "test/x_tests.jl" && sp[1].first == 1 && 5 <= sp[1].last <= 9 && sp[1].setup == String[]
        @test sp[2].first == 15 && 16 <= sp[2].last <= 17 && sp[2].setup == ["Snip", "Shared"]
        @test TC.module_names(text) == ["Snip"]

        items = tdd_spans("test/items_tests.jl")
        @test length(items) == 11 && all(s -> s.file == "test/items_tests.jl" && isempty(s.setup), items)
        @test issorted([s.first for s in items]) && all(i -> items[i].last < items[i + 1].first, 1:(length(items) - 1))
        n = only(filter(s -> s.name == "nested", items))
        @test n.first == 44 && 46 <= n.last <= 48                          # the header line 46 is inside
        a = only(filter(s -> s.name == "assert", items))
        @test a.first == 1 && 2 <= a.last <= 3
        @test TC.module_names(read(joinpath(TDD_PKG, "test/items_tests.jl"), String)) == String[]

        setup = read(joinpath(TDD_PKG, "test/setup_tests.jl"), String)
        s = only(TC.item_spans(setup, "test/setup_tests.jl"))            # the @testmodule is not an item
        @test s.name == "setup module" && s.first == 5 && 6 <= s.last <= 7 && s.setup == ["BrokenSetup"]
        @test TC.module_names(setup) == ["BrokenSetup"]
    end

    tdd_testset("requested: setup-module change adds must_pass items") do
        a0 = """
        @testmodule Shared begin
            const base = 1
        end

        @testitem "uses shared" setup = [Shared] begin
            @test Shared.base == 1
        end

        @testitem "other" begin
            @test true
        end

        @testitem "target" begin
            @test 1 == 1
        end
        """
        b0 = """
        @testitem "far user" setup = [Shared] begin
            @test Shared.base >= 1
        end

        @testitem "far other" begin
            @test true
        end
        """
        d = tmp_repo(Dict("test/a_tests.jl" => a0, "test/b_tests.jl" => b0, "src/X.jl" => "module X end\n"))
        a1 = replace(a0, "const base = 1" => "const base = 2", "@test 1 == 1" => "@test 1 == 2") * """

        @testitem "added" begin
            @test false
        end
        """
        commit!(d, Dict("test/a_tests.jl" => a1), "test: red for target\n\nTDD: red")
        r = TC.requested(d, "HEAD")
        @test keys(r) == (:red, :must_pass)
        @test sort([s.name for s in r.red]) == ["added", "target"]          # touched and added items
        @test sort([s.name for s in r.must_pass]) == ["far user", "uses shared"]   # unchanged, setup names Shared
        t = only(filter(s -> s.name == "target", r.red))
        @test t.file == "test/a_tests.jl" && t.first == 13
        @test only(filter(s -> s.name == "far user", r.must_pass)).file == "test/b_tests.jl"
        # a red commit that changes only an item, no module: nothing must pass
        commit!(d, Dict("test/b_tests.jl" => replace(b0, "@test true" => "@test 2 > 1")), "test: red\n\nTDD: red")
        r = TC.requested(d, "HEAD")
        @test [s.name for s in r.red] == ["far other"] && isempty(r.must_pass)
    end
end

include("test_tdd_cli.jl")   # tdd.jl red, green, api, brief (plan Task 4)
include("test_tdd_history.jl")    # history rules H1-H9, pure (plan Task 5)
include("test_tdd_history2.jl")   # H5 on git, lane_commits, E1-E5, audit (plan Task 5)
