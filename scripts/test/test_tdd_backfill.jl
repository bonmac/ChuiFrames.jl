# Tests for `tdd.jl mutate` and `tdd.jl gaps` (factory 0.3.0, plan Task 6; spec §3.3, §3.4, §5.1,
# §5.2). Included by runtests.jl right after test_tdd.jl (test_tdd.jl is at its 400-line budget), so
# test_tdd_cli.jl's loader and scratch package (TDD_JL_LOADED, tj_mod, tj_repo, tj_lane, tj_src,
# tj_head, tj_ev, tj_clean, tj_call) and runtests.jl's helpers (commit!, sh, Evidence) are reachable.
#
# Representation choices the implementer follows (decided from the spec by the test writer):
#
# - Reached as `Tdd.slug`, `Tdd.scratch`, `Tdd.mutate`, `Tdd.gaps` after `include("scripts/tdd.jl")`
#   (scripts/_tdd_backfill.jl is included by `module Tdd`). While a name is missing, each testset
#   fails on `@test isempty(missing)` instead of erroring the suite.
# - `mutate(root; item, src = nothing, expect = nothing, from, to, io)`. `src`/`expect` are
#   "F:LINE" strings, F relative to `root` (as the CLI's `--src F:LINE | --expect F:LINE`). `from`
#   must occur on that line; its first occurrence there is replaced by `to`. `root` here is a lane
#   checkout (a git worktree of the scratch package); its HEAD is the committed sha mutated.
# - The scratch is `<root>/.lanes/scratch/mutate/`, exactly: a detached worktree at `root`'s HEAD sha,
#   with `root`'s Manifest.toml / Manifest-v1.10.toml copied in when they exist. `scratch(root)`
#   returns that path.
# - Evidence: `<root>/.lanes/evidence/<kind>-<sha7>.txt`, the evidence.jl naming, kind
#   `mutate-<slug(item)>` (src) or `mutexp-<slug(item)>` (expect), sha7 of `root`'s HEAD. The file
#   has evidence.jl's header (Evidence.header reads it); its `exit:` is mutate's own verdict: `0` for
#   a killed mutant whose real run passed (as test_tdd_history.jl's "passing" mutate evidence). A
#   mutate that does not return 0 never leaves a file with `exit: 0`. Exit 2 cases write no file.
# - Verdicts: killed (the item, matched, fails as ASSERTION/BEHAVIOUR, then passes on the real
#   tree) -> 0. Survived (the mutant passes) -> 1. WRONG-REASON (e.g. the package no longer
#   loads) -> 1, the class printed on `io`. An item name not in TDD_MATCHED -> `NOT-RUN` printed,
#   1. Dirty `root` or `from` not on the line -> 2, before any package run.
# - "scratch file restored after a throw": the throw comes from `io`. The test passes an IO whose
#   writes throw once the scratch source holds the mutation. Contract this relies on: mutate writes
#   to `io` while the mutation is applied (e.g. the mutant run's output, as Evidence.run_evidence(...;
#   io) prints it), does not swallow that exception, and restores the file in `finally`.
# - "real tree untouched" checks, around a killed mutate: the lane's HEAD, branch, `git status
#   --porcelain` (empty) and src/test file bytes are unchanged; and the scratch is a detached
#   worktree at the same sha whose src equals HEAD's (restored), with Manifest.toml copied if the
#   lane has one.
# - gaps(root; io): one line `UNTESTED <name>` per exported or `public` name of the package that
#   appears nowhere in `root/test/` (as a whole identifier); returns 0. Julia < 1.11: prints
#   `NOT RUN`, returns 2.
#
# Cost: about ten package test runs on one shared lane (mut-a): killed x2 runs, two items x2,
# mutexp x2, survived, load-breaking, unmatched, throw x1 each (at least).
using SHA

const TB_NEEDS = (:slug, :scratch, :mutate)
"Tdd's `name`, or nothing while tdd.jl or the name is missing."
tb(name) = (TDD_JL_LOADED && isdefined(tj_mod(), name)) ? getfield(tj_mod(), name) : nothing
"A named testset that fails (instead of erroring the suite) while any of `needs` is missing."
tb_testset(f, name, needs::Symbol...) = @testset "$name" begin
    missing_ = [n for n in needs if tb(n) === nothing]
    if isempty(missing_)
        f()
    else
        @test isempty(missing_)   # RED: tdd.jl does not define these yet
    end
end
tb_slug_expected(name) = first(replace(lowercase(name), r"[^a-z0-9]+" => "-"), 24) * "-" * bytes2hex(sha1(name))[1:8]
"\"F:LINE\" of the first line of `d/rel` containing `needle`."
function tb_at(d, rel, needle)
    i = findfirst(l -> occursin(needle, l), readlines(joinpath(d, rel)))
    i === nothing && error("$needle not in $rel")
    return "$rel:$i"
end
tb_scratch_dir(d) = joinpath(d, ".lanes", "scratch", "mutate")
tb_exit(path) = (h = Evidence.header(path); h === nothing ? nothing : get(h, "exit", nothing))
tb_evs(d, prefix) = (e = joinpath(d, ".lanes", "evidence"); isdir(e) ? filter(f -> startswith(f, prefix), readdir(e)) : String[])

const ITEM_G = "g adds one"                       # test/base_tests.jl, on main
const ITEM_P = "g is positive on positives"        # test/pos_tests.jl, the lane's backfill commit
const KILL = (from = "secret_body_marker = 1", to = "secret_body_marker = -5")   # fails both items
const TB_STATE = Dict{Symbol, Any}()
"The shared lane `mut-a`: main plus one backfill item."
tb_lane_a() = get!(TB_STATE, :a) do
    d = tj_lane("mut-a")
    commit!(d, Dict("test/pos_tests.jl" => "@testitem \"$ITEM_P\" begin\n    @test g(1) > 0\nend\n"), "test: g positive\n\nTDD: backfill")
    d
end
tb_snap(d) = (
    head = tj_head(d), branch = readchomp(`git -C $d rev-parse --abbrev-ref HEAD`),
    status = read(`git -C $d status --porcelain`, String),
    files = Dict(f => read(joinpath(d, f), String) for f in ("src/TddLane.jl", "test/base_tests.jl", "test/pos_tests.jl")),
)
"The killed mutate of ITEM_G on mut-a, run once: (code, out, before, after)."
tb_killed() = get!(TB_STATE, :killed) do
    d = tb_lane_a()
    before = tb_snap(d)
    code, out = tj_call(tb(:mutate), d; item = ITEM_G, src = tb_at(d, "src/TddLane.jl", KILL.from), KILL...)
    (code = code, out = out, before = before, after = tb_snap(d))
end

"An IO that throws on the first write made while `path` contains `marker`."
mutable struct TbTripIO <: IO
    path::String
    marker::String
    tripped::Bool
    buf::IOBuffer
end
TbTripIO(path, marker) = TbTripIO(path, marker, false, IOBuffer())
function Base.unsafe_write(t::TbTripIO, p::Ptr{UInt8}, n::UInt)
    if !t.tripped && isfile(t.path) && occursin(t.marker, read(t.path, String))
        t.tripped = true
        error("TbTripIO: a write while the mutation is applied")
    end
    return unsafe_write(t.buf, p, n)
end
Base.write(t::TbTripIO, b::UInt8) = write(t, UInt8[b])

@testset "tdd.jl mutate and gaps (0.3.0)" begin
    tb_testset("slug is <=33 chars and stable", :slug) do
        slug = tb(:slug)
        @test slug(ITEM_G) == tb_slug_expected(ITEM_G)
        @test slug(ITEM_G) == "g-adds-one-" * bytes2hex(sha1(ITEM_G))[1:8]
        long = "Frames: join on 3 keys --- with NaN!! and missing values, sorted"
        @test slug(long) == tb_slug_expected(long)
        @test length(slug(long)) <= 33 && length(slug(ITEM_G)) <= 33
        @test slug(long) == slug(long)                       # stable
        @test slug("Ab") != slug("ab")                        # the hash is of the name, not the lowered one
        @test occursin(r"^[a-z0-9-]{1,24}-[0-9a-f]{8}$", slug(long))
        @test slug(long) isa String
        @test occursin(Evidence.KIND, "mutate-" * slug(long)) && occursin(Evidence.KIND, "mutexp-" * slug(long))
    end

    tb_testset("killed mutant exits 0", TB_NEEDS...) do
        k = tb_killed()
        d = tb_lane_a()
        @test k.code == 0
        @test occursin(ITEM_G, k.out)
        @test occursin("ASSERTION", k.out)
        ev = tj_ev(d, "mutate-$(tb(:slug)(ITEM_G))")
        @test isfile(ev)
        @test tb_exit(ev) == "0"
        @test isempty(tb_evs(d, "mutexp-"))                   # src writes mutate-, never mutexp-
    end

    tb_testset("two items at one sha give two files", TB_NEEDS...) do
        tb_killed()                                           # ITEM_G's file at this sha
        d = tb_lane_a()
        code, _ = tj_call(tb(:mutate), d; item = ITEM_P, src = tb_at(d, "src/TddLane.jl", KILL.from), KILL...)
        @test code == 0
        eg, ep = tj_ev(d, "mutate-$(tb(:slug)(ITEM_G))"), tj_ev(d, "mutate-$(tb(:slug)(ITEM_P))")
        @test eg != ep
        @test isfile(eg) && isfile(ep)
        @test tb_exit(eg) == "0" && tb_exit(ep) == "0"
        sha7 = first(tj_head(d), 7)
        @test count(f -> endswith(f, "-$sha7.txt"), tb_evs(d, "mutate-")) >= 2
    end

    tb_testset("surviving mutant exits 1", TB_NEEDS...) do
        d = tb_lane_a()
        line = tb_at(d, "src/TddLane.jl", "return x + secret_body_marker")
        code, out = tj_call(tb(:mutate), d; item = ITEM_P, src = line, from = "x + secret_body_marker", to = "secret_body_marker + x")
        @test code == 1
        @test occursin(ITEM_P, out)
        ev = tj_ev(d, "mutate-$(tb(:slug)(ITEM_P))")
        # the file may have been written by "two items"; a survivor must not leave it passing
        @test !isfile(ev) || tb_exit(ev) != "0"
        @test tj_clean(d)
    end

    tb_testset("load-breaking mutation is wrong-reason, exits 1", TB_NEEDS...) do
        d = tb_lane_a()
        line = tb_at(d, "src/TddLane.jl", "return x + secret_body_marker")
        code, out = tj_call(tb(:mutate), d; item = ITEM_G, src = line, from = "return x + secret_body_marker", to = "return x + secret_body_marker)")
        @test code == 1
        @test occursin("WRONG-REASON", out)
        ev = tj_ev(d, "mutate-$(tb(:slug)(ITEM_G))")
        @test !isfile(ev) || tb_exit(ev) != "0"
        @test tj_clean(d)
    end

    tb_testset("from not on line exits 2", TB_NEEDS...) do
        d = tj_lane("mut-from")
        line = tb_at(d, "src/TddLane.jl", KILL.from)
        code, _ = tj_call(tb(:mutate), d; item = ITEM_G, src = line, from = "no_such_text_on_this_line", to = "x")
        @test code == 2
        # `from` exists in the file, but on another line
        other = tb_at(d, "src/TddLane.jl", "function g(x)")
        code2, _ = tj_call(tb(:mutate), d; item = ITEM_G, src = other, KILL...)
        @test code2 == 2
        @test isempty(tb_evs(d, "mutate-"))
        @test tj_clean(d)
    end

    tb_testset("dirty tree exits 2", TB_NEEDS...) do
        d = tj_lane("mut-dirty")
        write(joinpath(d, "test", "base_tests.jl"), "@testitem \"$ITEM_G\" begin\n    @test g(1) == 2\n    @test true\nend\n")   # uncommitted
        code, _ = tj_call(tb(:mutate), d; item = ITEM_G, src = tb_at(d, "src/TddLane.jl", KILL.from), KILL...)
        @test code == 2
        @test isempty(tb_evs(d, "mutate-"))
        @test !tj_clean(d)                                    # mutate did not clean or commit it
    end

    tb_testset("scratch file restored after a throw", TB_NEEDS...) do
        d = tb_lane_a()
        to = "secret_body_marker = 7"                         # unique to this testset
        tio = TbTripIO(joinpath(tb_scratch_dir(d), "src", "TddLane.jl"), to)
        threw = try
            withenv("JULIA_PKG_OFFLINE" => "true") do
                tb(:mutate)(d; item = ITEM_G, src = tb_at(d, "src/TddLane.jl", KILL.from), from = KILL.from, to, io = tio)
            end
            false
        catch
            true
        end
        @test tio.tripped                                     # mutate wrote to io while the mutant was applied
        @test threw                                           # and did not swallow the throw
        sf = joinpath(tb_scratch_dir(d), "src", "TddLane.jl")
        @test isfile(sf) && read(sf, String) == read(`git -C $d show HEAD:src/TddLane.jl`, String)
        @test tj_clean(d)
    end

    tb_testset("real tree untouched", TB_NEEDS...) do
        k = tb_killed()
        d = tb_lane_a()
        @test k.code == 0                                     # a real run happened on this tree
        @test k.after.head == k.before.head
        @test k.after.branch == k.before.branch == "mut-a"
        @test k.before.status == "" && k.after.status == ""
        @test k.after.files == k.before.files
        sc = tb_scratch_dir(d)
        @test tb(:scratch)(d) == sc
        @test isdir(sc)
        @test readchomp(`git -C $sc rev-parse HEAD`) == tj_head(d)
        @test !success(`git -C $sc symbolic-ref -q HEAD`)     # detached
        @test isfile(joinpath(sc, "src", "TddLane.jl")) &&
            read(joinpath(sc, "src", "TddLane.jl"), String) == read(`git -C $d show HEAD:src/TddLane.jl`, String)
        @test !isfile(joinpath(d, "Manifest.toml")) || isfile(joinpath(sc, "Manifest.toml"))
    end

    tb_testset("mutexp writes its own kind", TB_NEEDS...) do
        d = tb_lane_a()
        line = tb_at(d, "test/base_tests.jl", "@test g(1) == 2")
        code, out = tj_call(tb(:mutate), d; item = ITEM_G, expect = line, from = "== 2", to = "== 3")
        @test code == 0
        ev = tj_ev(d, "mutexp-$(tb(:slug)(ITEM_G))")
        @test isfile(ev)
        @test tb_exit(ev) == "0"
        h = Evidence.header(ev)
        @test h !== nothing && get(h, "kind", "") == "mutexp-$(tb(:slug)(ITEM_G))"
        @test read(joinpath(d, "test", "base_tests.jl"), String) == read(`git -C $d show HEAD:test/base_tests.jl`, String)
        @test tj_clean(d)
    end

    tb_testset("unmatched item name is NOT-RUN", TB_NEEDS...) do
        d = tb_lane_a()
        name = "no such item anywhere"
        code, out = tj_call(tb(:mutate), d; item = name, src = tb_at(d, "src/TddLane.jl", KILL.from), KILL...)
        @test code == 1
        @test occursin(name, out) && occursin("NOT-RUN", out)
        ev = tj_ev(d, "mutate-$(tb(:slug)(name))")
        @test !isfile(ev) || tb_exit(ev) != "0"
    end

    tb_testset("gaps lists the untested public name only", :gaps) do
        if VERSION < v"1.11"
            @test_skip "gaps needs Julia >= 1.11"
        else
            d = tj_lane("gaps")
            extra = """

            \"\"\"
                untested_pub()

            Public, and named nowhere in test/.
            \"\"\"
            untested_pub() = 1
            public untested_pub

            internal_untested_helper() = 2
            """
            commit!(d, Dict("src/TddLane.jl" => tj_src(extra = extra)), "feat: untested_pub")
            code, out = tj_call(tb(:gaps), d)
            @test code == 0
            untested = [strip(l) for l in split(out, '\n') if startswith(strip(l), "UNTESTED ")]
            @test untested == ["UNTESTED untested_pub"]       # g is tested; the internal name is not public
        end
    end

    tb_testset("gaps on 1.10 exits 2 NOT RUN", :gaps) do
        if VERSION >= v"1.11"
            @test_skip "only on Julia < 1.11"
        else
            code, out = tj_call(tb(:gaps), tj_repo())
            @test code == 2
            @test occursin("NOT RUN", out)
        end
    end
end
