# Tests for scripts/_tdd_history.jl and `tdd.jl audit` (factory 0.3.0, plan Task 5; spec §0.5, §3.1,
# §3.2, §4.2, §4.3, §5.2, §6). Included by test_tdd.jl after test_tdd_cli.jl, whose loader
# (TDD_JL_LOADED, tj_mod) this file reuses. This file: the pure history rules H1-H9 (no git).
# test_tdd_history2.jl: H5 on scratch git repos, lane_commits, the evidence rules E1-E5 and audit.
#
# Representation choices the implementer follows (decided from the spec by the test writer):
#
# - Hosting. _tdd_history.jl holds top-level definitions, no `module` of its own (dod.jl includes it
#   too, Task 7). tdd.jl's `module Tdd` includes it, so every name below is reached as `Tdd.<name>`
#   after `include("scripts/tdd.jl")`; no separate include of _tdd_history.jl here. While tdd.jl or a
#   name is missing, each testset fails on `@test isdefined(Tdd, name)` instead of erroring the suite.
# - `LaneCommit(sha, author, phase, mode, paths)`, positional, the field order of the Interfaces block.
#   `author` is "name <email>" verbatim. `phase` is the `TDD:` trailer value or nothing. `mode` is
#   the commit's own `TDD-Mode:` trailer as (mode, reason), whoever authored it; the reason is the
#   text after " — " (em dash), "" when there is none. Pure tests build LaneCommits with fake
#   40-hex shas; paths are repo-relative.
# - `history_rules(commits; stub_ok)`: `stub_ok(sha::String)::Bool` is called for each `stub`
#   commit (audit passes `s -> stub_declares_only(root, s)`). It returns one String per failure, and
#   each String starts with its rule id ("H1".."H9", then a non-digit: "H5 3f2a1b0 stub ..."). An
#   empty vector is a pass. Tests check for or against a rule id, never the whole text.
# - Mode. The oldest commit with a `mode` decides it if it is authored exactly
#   `lead <lead@factory.invalid>`; otherwise that trailer is ignored and the mode is `required`. A
#   `skip` trailer that is ignored (role author), or a lead `skip` with an empty reason, is an H8 failure.
# - Mode `refactor`: H2, H6, H7 are replaced by H8 (no red/green/stub, no test/** change); the merge
#   base's green evidence stands in for a green (E2). Mode `skip` (lead, with a reason): only H8 and
#   H9 are checked; H1's trailer requirement and H2-H7 do not apply (a spike has no phases).
# - H4 seen from the other side: any commit that is not a test-writer phase and touches test/**
#   reports H4 (a `green` touching test/** reports H3 and H4). The one exemption: a phase-less
#   commit authored `lead <lead@factory.invalid>` that changes only test/runtests.jl and
#   test/Project.toml under test/.
# - Evidence (E1-E4) is read from `<root>/.lanes/evidence/`, the files evidence.jl writes. A file
#   is "passing" when its header `head` is the commit's full sha, `dirty: false`, `termsignal: 0`,
#   and: for `red-<sha7>`, its `--- tdd ---` part names at least one ASSERTION/BEHAVIOUR item and no
#   WRONG-REASON, PASSED, NOT-RUN or COLLATERAL; for `green-<sha7>`, `exit: 0` and a `--- tdd ---`
#   part with `green default suite: OK`; for `mutate-<slug>`/`mutexp-<slug>` (any head), `exit: 0`
#   and a tdd part with `KILLED` (review M3). E4 fails on any evidence file of a lane
#   commit with `dirty: true` or `termsignal` != 0. A backfill commit's items are the `@testitem`s it
#   adds; an item whose only assertions are `@test_broken` is printed as listed, not an E3 failure.
# - The TDD ledger is JSONL, one object per line, as _lib.sh's `ledger` writes it:
#   {"ts":…,"ev":"tdd-commit","session":…,"agent_id":…,"agent_type":"test-writer"|"implementer",
#    "checkout":"<abs checkout>","sha":"<full sha>"} and
#   {"ev":"tdd-commit-violation", …same keys…, "reason":…}. E5: each commit authored test-writer or
#   implementer needs a tdd-commit record with its full sha and agent_type equal to its author's
#   name. Any tdd-commit-violation whose sha is a lane commit, or whose checkout is the lane root, fails.
# - `evidence_rules(root, commits; ledger)` returns failure Strings starting "E1".."E5", like H.
#   `audit(root; base, io)` prints every H and E failure on `io` (one per line, rule id first) and
#   returns 0 when there are none, 1 otherwise, 2 when it cannot evaluate. Without `--ledger`
#   it uses the owning repo's main ledger, `Tdd.owning_ledger(root)` (0.3.1 F2): the
#   `.lanes/ledger.jsonl` of the main checkout of the repo `root` belongs to.

const TW = "test-writer <test-writer@factory.invalid>"
const IMPL = "implementer <implementer@factory.invalid>"
const LEAD = "lead <lead@factory.invalid>"
const OTHER = "Some One <someone@example.com>"

"Tdd's `name`, or nothing while tdd.jl or the name is missing."
th(name) = (TDD_JL_LOADED && isdefined(tj_mod(), name)) ? getfield(tj_mod(), name) : nothing
"A named testset that fails (instead of erroring the suite) while any of `needs` is missing."
th_testset(f, name, needs::Symbol...) = @testset "$name" begin
    missing_ = [n for n in needs if th(n) === nothing]
    if isempty(missing_)
        f()
    else
        @test isempty(missing_)   # RED: tdd.jl does not define these yet
    end
end
"Does a rule result report rule `id` (e.g. \"H5\")?"
th_has(v, id) = any(s -> occursin(Regex("^" * id * "(?![0-9])"), s), v)

const TH_SEQ = Ref(0)
"A fake commit: author, phase, paths; a fresh 40-hex sha."
function lc(author, phase, paths...; mode = nothing, sha = nothing)
    TH_SEQ[] += 1
    s = something(sha, string(TH_SEQ[]; base = 16, pad = 40))
    return th(:LaneCommit)(s, author, phase, mode, String[paths...])
end
hr(cs...; stub_ok = _ -> true) = th(:history_rules)(collect(cs); stub_ok)
stub() = lc(IMPL, "stub", "src/A.jl")
red() = lc(TW, "red", "test/a_tests.jl")
green() = lc(IMPL, "green", "src/A.jl")
"A lane that passes every history rule: stub, red, green."
good_lane() = (stub(), red(), green())

@testset "tdd history rules H1-H9 (0.3.0)" begin
    H = (:LaneCommit, :history_rules)

    th_testset("no code change passes with no trailers", H...) do
        @test isempty(hr(lc(LEAD, nothing, "docs/x.md"), lc(OTHER, nothing, "README.md", "CHANGELOG.md")))
        @test isempty(hr(lc(OTHER, nothing, ".github/workflows/ci.yml")))
        @test isempty(hr(good_lane()...))    # and the canonical lane passes too
    end

    th_testset("code commit without trailer fails H1", H...) do
        @test th_has(hr(lc(LEAD, nothing, "src/A.jl")), "H1")
        @test th_has(hr(good_lane()..., lc(OTHER, nothing, "ext/AExt.jl")), "H1")
        @test !th_has(hr(good_lane()...), "H1")
    end

    th_testset("required lane with only refactor/stub src commits fails", H...) do
        v = hr(stub(), lc(IMPL, "refactor", "src/A.jl"))
        @test th_has(v, "H2")
        @test th_has(hr(stub()), "H2")
    end

    th_testset("stub editing test fails H3", H...) do
        @test th_has(hr(lc(IMPL, "stub", "src/A.jl", "test/a_tests.jl"), red(), green()), "H3")
    end

    th_testset("green editing any test file fails H4", H...) do
        for t in ("test/a_tests.jl", "test/helpers.jl", "test/runtests.jl", "test/Project.toml", "test/data/x.csv")
            v = hr(stub(), red(), lc(IMPL, "green", "src/A.jl", t))
            @test th_has(v, "H4")
        end
    end

    th_testset("test-fix touching src fails H3", H...) do
        v = hr(stub(), red(), green(), lc(TW, "test-fix", "test/a_tests.jl", "src/A.jl"), green())
        @test th_has(v, "H3")
    end

    th_testset("red touching changelog.d fails H3", H...) do
        v = hr(stub(), lc(TW, "red", "test/a_tests.jl", "changelog.d/x.md"), green())
        @test th_has(v, "H3")
    end

    th_testset("red touching Project.toml fails H3", H...) do
        @test th_has(hr(stub(), lc(TW, "red", "test/a_tests.jl", "Project.toml"), green()), "H3")
    end

    th_testset("red touching test/runtests.jl fails H3", H...) do
        @test th_has(hr(stub(), lc(TW, "red", "test/a_tests.jl", "test/runtests.jl"), green()), "H3")
        @test th_has(hr(stub(), lc(TW, "red", "test/a_tests.jl", "test/Project.toml"), green()), "H3")
    end

    th_testset("lead-authored non-phase commit to test/runtests.jl passes H4; to test/foo_tests.jl fails", H...) do
        @test !th_has(hr(good_lane()..., lc(LEAD, nothing, "test/runtests.jl", "test/Project.toml")), "H4")
        @test th_has(hr(good_lane()..., lc(LEAD, nothing, "test/foo_tests.jl")), "H4")
        @test th_has(hr(good_lane()..., lc(LEAD, nothing, "test/runtests.jl", "test/foo_tests.jl")), "H4")
        @test th_has(hr(good_lane()..., lc(OTHER, nothing, "test/runtests.jl")), "H4")   # not the lead
    end

    th_testset("stub before its red passes H6; red before any stub with a later stub fails H6", H...) do
        @test !th_has(hr(stub(), red(), green()), "H6")
        @test th_has(hr(red(), stub(), green()), "H6")
    end

    th_testset("green before red fails H6", H...) do
        @test th_has(hr(stub(), green(), red(), green()), "H6")
        @test th_has(hr(stub(), green()), "H6")
    end

    th_testset("two greens for one red fail H6", H...) do
        @test th_has(hr(stub(), red(), green(), green()), "H6")
        @test !th_has(hr(stub(), red(), green(), lc(TW, "test-fix", "test/a_tests.jl"), green()), "H6")
    end

    th_testset("refactor before any green fails H6", H...) do
        @test th_has(hr(stub(), red(), lc(IMPL, "refactor", "src/A.jl"), green()), "H6")
        @test th_has(hr(stub(), red(), lc(TW, "test-refactor", "test/a_tests.jl"), green()), "H6")
        v = hr(stub(), red(), green(), lc(IMPL, "refactor", "src/A.jl"), lc(TW, "test-refactor", "test/a_tests.jl"))
        @test !th_has(v, "H6")
    end

    th_testset("lane ending on red fails H7", H...) do
        @test th_has(hr(stub(), red()), "H7")
        @test th_has(hr(stub(), red(), green(), red()), "H7")
        @test !th_has(hr(good_lane()...), "H7")
    end

    th_testset("mode trailer on a non-lead-authored commit is ignored (mode required)", H...) do
        # an implementer's `TDD-Mode: refactor` does not make this a refactor lane: no red is H2
        v = hr(lc(IMPL, "refactor", "src/A.jl"; mode = ("refactor", "rename only")))
        @test th_has(v, "H2")
        v = hr(lc(OTHER, nothing; mode = ("refactor", "rename")), lc(IMPL, "refactor", "src/A.jl"))
        @test th_has(v, "H2")
        # the oldest mode trailer decides: a later lead trailer does not rescue the lane
        v = hr(lc(TW, "backfill", "test/b_tests.jl"; mode = ("refactor", "x")), lc(LEAD, nothing; mode = ("refactor", "y")), lc(IMPL, "refactor", "src/A.jl"))
        @test th_has(v, "H2")
    end

    th_testset("refactor mode: test/** change fails H8", H...) do
        mode = lc(LEAD, nothing; mode = ("refactor", "rename internals"))
        @test isempty(hr(mode, lc(IMPL, "refactor", "src/A.jl")))           # a pure refactor lane passes
        @test th_has(hr(mode, lc(IMPL, "refactor", "src/A.jl", "test/a_tests.jl")), "H8")
        @test th_has(hr(mode, lc(IMPL, "refactor", "src/A.jl"), lc(TW, "test-refactor", "test/a_tests.jl")), "H8")
    end

    th_testset("refactor mode: red commit fails H8", H...) do
        mode = lc(LEAD, nothing; mode = ("refactor", "rename internals"))
        @test th_has(hr(mode, lc(IMPL, "refactor", "src/A.jl"), red(), green()), "H8")
        @test th_has(hr(mode, green()), "H8")
        @test th_has(hr(mode, stub(), lc(IMPL, "refactor", "src/A.jl")), "H8")
    end

    th_testset("skip mode by a role-authored commit fails H8", H...) do
        @test th_has(hr(lc(IMPL, "stub", "src/A.jl"; mode = ("skip", "spike")), lc(OTHER, nothing, "src/A.jl")), "H8")
        @test th_has(hr(lc(TW, "red", "test/a_tests.jl"; mode = ("skip", "spike")), green()), "H8")
        @test th_has(hr(lc(LEAD, nothing; mode = ("skip", "")), lc(LEAD, nothing, "src/A.jl")), "H8")   # no reason
    end

    th_testset("skip mode by a lead-authored commit with reason passes", H...) do
        v = hr(lc(LEAD, nothing; mode = ("skip", "spike: try a new layout")), lc(LEAD, nothing, "src/A.jl", "src/B.jl"))
        @test isempty(v)
    end

    th_testset("red authored implementer fails H9", H...) do
        @test th_has(hr(stub(), lc(IMPL, "red", "test/a_tests.jl"), green()), "H9")
        @test th_has(hr(lc(TW, "stub", "src/A.jl"), red(), green()), "H9")
        @test th_has(hr(stub(), red(), lc(LEAD, "green", "src/A.jl")), "H9")
        @test th_has(hr(lc(IMPL, "backfill", "test/b_tests.jl")), "H9")       # H9 applies with no code too
    end

    th_testset("phase-less commit with a role author fails H9", H...) do
        @test th_has(hr(lc(TW, nothing, "docs/x.md")), "H9")
        @test th_has(hr(good_lane()..., lc(IMPL, nothing, "src/A.jl")), "H9")
        @test !th_has(hr(lc(LEAD, nothing, "docs/x.md")), "H9")
    end
end
