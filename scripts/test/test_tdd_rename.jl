# Tests for the renamed-red deadlock in `tdd.jl green` (factory 0.3.0; plan Task 9 ruling, spec
# §3.1, §3.5, §4.2 H6). Included by runtests.jl after test_tdd.jl, whose helpers (tj_lane, tj_call,
# tj_ev, tj_src, tj_stub!, tj_testset, TJ_RED_TEST, ...) and the Tdd module are top-level in Main.
#
# The ruling: a red item that a later commit renames is NOT-RUN ("gone at HEAD") for good today,
# which deadlocks `green`. The way out is a `TDD: test-fix` commit authored by the test-writer that
# renames the item and records fresh red evidence (`tdd.jl red` at that commit, red-<sha7> OK) under
# the new name; after that, `green` proceeds (the new name must then be matched and pass).
#
# Scenario: A = "h doubles" (TJ_RED_TEST, added by a `TDD: red` commit), B = "h doubles two" (the
# renamed item, still failing until the fix). Authors follow spec §3.1: red/test-fix by
# test-writer, green by implementer.
#
# Cost: about eleven package test runs (red x7, green x6).
const TR_IDS = Dict(
    :tw => ("test-writer", "test-writer@factory.invalid"),
    :impl => ("implementer", "implementer@factory.invalid"),
)
const TR_A = "h doubles"
const TR_B = "h doubles two"
const TR_B_TEST = """
@testitem "$TR_B" begin
    @test h(3) == 6
end
"""
"Write `files`, delete `rm`, and commit everything as `who` (author and committer)."
function tr_commit!(d, who, files::Dict, msg; rm = String[])
    for (rel, c) in files
        mkpath(dirname(joinpath(d, rel)))
        write(joinpath(d, rel), c)
    end
    foreach(r -> Base.rm(joinpath(d, r)), rm)
    sh(`git -C $d add -A -- .`)
    n, e = TR_IDS[who]
    return sh(`git -C $d -c user.name=$n -c user.email=$e commit -q -m $msg`)
end
"A lane with stub, red A (test-writer) and `tdd.jl red` OK at the red commit."
function tr_red_lane(name)
    d = tj_lane(name)
    tj_stub!(d)
    tr_commit!(d, :tw, Dict("test/h_tests.jl" => TJ_RED_TEST), "test: h doubles\n\nTDD: red")
    code, _ = tj_call(tj_mod().red, d)
    @test code == 0                                     # A's red evidence is recorded
    @test isfile(tj_ev(d, "red"))
    return d
end
"The rename A -> B in place (same file), as a commit with `msg` by `who`."
tr_rename!(d, who, msg) = tr_commit!(d, who, Dict("test/h_tests.jl" => TR_B_TEST), msg)
"The implementer's fix: h gets its method."
tr_fix!(d) = tr_commit!(d, :impl, Dict("src/TddLane.jl" => tj_src(stub = true, fix = true)), "feat: h doubles\n\nTDD: green")
"True when some line of `out` says NOT-RUN and ends with exactly `item` (so B never counts as A)."
tr_notrun(out, item) = any(l -> occursin("NOT-RUN", l) && endswith(rstrip(l), item) && !endswith(rstrip(l), "$item two"), split(out, '\n'))

@testset "tdd.jl green after a renamed red item (0.3.0)" begin
    tj_testset("green proceeds after a test-writer test-fix renames a red item and records red evidence") do
        d = tr_red_lane("rn-ok")
        tr_rename!(d, :tw, "test: rename h doubles\n\nTDD: test-fix")
        code, out = tj_call(tj_mod().red, d)            # fresh red evidence under the new name
        @test code == 0
        ev = tj_ev(d, "red")
        @test isfile(ev)
        @test occursin(TR_B, tj_tdd_part(ev))
        tr_fix!(d)
        code, out = tj_call(tj_mod().green, d)
        @test code == 0
        @test !tr_notrun(out, TR_A)                     # A no longer blocks
        @test occursin(TR_B, out)                       # B is one of green's items
        @test isfile(tj_ev(d, "green"))
    end

    tj_testset("after a valid rename, green still requires the new name to pass") do
        # Freeing A must not free B: the renamed item is a red item of the test-fix commit, so an
        # unfixed B fails green (it is selected and fails; never silently dropped).
        d = tr_red_lane("rn-unfixed")
        tr_rename!(d, :tw, "test: rename h doubles\n\nTDD: test-fix")
        code, _ = tj_call(tj_mod().red, d)
        @test code == 0
        tr_commit!(d, :impl, Dict("src/TddLane.jl" => tj_src(stub = true, extra = "\n# not the fix\n")), "chore: no fix\n\nTDD: green")
        code, out = tj_call(tj_mod().green, d)
        @test code == 1
        @test occursin(TR_B, out)
    end

    tj_testset("renamed red item still blocks green without fresh red evidence") do
        d = tr_red_lane("rn-noev")
        tr_rename!(d, :tw, "test: rename h doubles\n\nTDD: test-fix")
        @test !isfile(tj_ev(d, "red"))                  # no `tdd.jl red` at the test-fix commit
        tr_fix!(d)
        code, out = tj_call(tj_mod().green, d)
        @test code == 1
        @test tr_notrun(out, TR_A)
    end

    # Two variants of "not a test-writer test-fix", both WITH a `tdd.jl red` run at the renaming
    # commit, so only the phase/author differs from the passing scenario:
    #   (a) a `TDD: test-fix` authored by the implementer (wrong author, spec §3.1);
    #   (b) a `TDD: red` authored by the implementer (wrong phase: the ruling frees only test-fix).
    # The exit code of `tdd.jl red` there is not asserted: it may refuse the commit, either way A
    # must stay NOT-RUN.
    tj_testset("renamed red item still blocks green when the rename is not a test-writer test-fix") do
        for (lane, msg) in (
                ("rn-impl-fix", "test: rename h doubles\n\nTDD: test-fix"),
                ("rn-impl-red", "test: rename h doubles\n\nTDD: red"),
            )
            d = tr_red_lane(lane)
            tr_rename!(d, :impl, msg)
            tj_call(tj_mod().red, d)
            tr_fix!(d)
            code, out = tj_call(tj_mod().green, d)
            @test code == 1
            @test tr_notrun(out, TR_A)
        end
    end

    # Deletion: the ruling frees a red item only through a rename "under the new name" backed by
    # fresh red evidence. A test-writer test-fix that deletes A and adds nothing has no new name
    # and no red evidence can be recorded for it (`tdd.jl red` exits 2 on a commit with no items),
    # so nothing replaces A's red evidence and green must keep blocking: deleting a red test is not
    # a way to get a lane to green.
    tj_testset("an item deleted with no replacement still blocks green") do
        d = tr_red_lane("rn-deleted")
        tr_commit!(d, :tw, Dict{String, String}(), "test: drop h doubles\n\nTDD: test-fix"; rm = ["test/h_tests.jl"])
        code, _ = tj_call(tj_mod().red, d)
        @test code == 2                                 # no items: no red evidence
        @test !isfile(tj_ev(d, "red"))
        tr_fix!(d)
        code, out = tj_call(tj_mod().green, d)
        @test code == 1
        @test tr_notrun(out, TR_A)
    end
end
