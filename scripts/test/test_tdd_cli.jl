# Tests for scripts/tdd.jl `red`, `green`, `api`, `brief` (factory 0.3.0, plan Task 4; spec §0.4,
# §0.6, §3, §4.1). Included by test_tdd.jl (its own file: test_tdd.jl is at the 400-line budget).
#
# Representation choices the implementer follows (decided from the spec by the test writer):
#
# - Loading. tdd.jl is `module Tdd` with `main(args; io)`; it includes what it needs itself
#   (_common.jl, _tdd_classify.jl, evidence.jl). These tests `include` it into Main, guarded: while
#   it is missing (or fails to load) every testset below fails instead of erroring the suite.
# - Calls are in-process, keyword-only, with all output on the `io` keyword (an IOBuffer here), and
#   return the exit code: `Tdd.red(root; rev = "HEAD", io)`, `Tdd.green(root; base = "main", io)`,
#   `Tdd.api(root; io)`, `Tdd.brief(root; role = "test-writer" | "implementer", io)`.
# - The scratch package. A temp git repo R on `main` holds a tiny package TddLane, a verbatim copy
#   of the seeded test/runtests.jl, and a committed copy of the template's scripts/*.jl (as a synced
#   package has them), with `/.lanes/`, `/.worktrees/` and `/Manifest*.toml` gitignored. Each
#   scenario is a lane: `git worktree add R/.worktrees/<lane> -b <lane> main`, with commits whose
#   last paragraph is the trailer `TDD: <phase>`. The lane name is the worktree directory's basename.
#   Package runs inherit ENV (JULIA_PKG_OFFLINE=true is set here). tdd.jl may run them as
#   `julia scripts/ci.jl test -- item=<name> ...` in `root` (the copied ci.jl, whose root is `root`).
# - Evidence. `<root>/.lanes/evidence/red-<sha7>.txt` and `green-<sha7>.txt`, written through
#   Evidence.run_evidence (kinds `red`, `green`). After the run's output, the file has a line
#   `--- tdd ---` and then the classifier report: each item's name and class on one line. `io` gets
#   the report too. Running never leaves the tree dirty (the TDD_MATCHED file lives outside it).
# - killed. The run is bounded through ci.jl's own CI_TIMEOUT env (ci.jl kills the process group and
#   exits 124; the output has no `Test Summary:`), so tdd.jl must not override that bound. The item
#   is WRONG-REASON and red exits 1.
# - green. The lane's red items are those of every `red`/`test-fix` commit in `base..HEAD`. An
#   unmatched one is printed with `NOT-RUN` (exit 1). The default-suite run's output reaches `io`.
# - api. `## <name>` per exported or `public` name, then its docstring; never method source. On
#   VERSION < v"1.11" it prints `NOT RUN` and returns 2.
# - brief. The first line printed on `io` and the first line of the saved file is exactly
#   `<!-- tdd-brief role=<role> lane=<basename(root)> checkout=<abspath(root)> head=<full HEAD sha> -->`.
#   The brief is saved to `<main>/.lanes/briefs/<lane>/<role>-<n>.md` (n = 1 for the first, then 2,
#   ...), never under the lane's own .lanes, and its absolute path is printed on `io`. `## Stub diffs`
#   holds `git show` of each `TDD: stub` commit in main..HEAD (full sha and the added lines). A stub
#   that fails H5: exit 1, its sha7 printed, nothing saved. A dirty tree: exit 2, nothing saved.
#
# Cost: about nine package test runs (red x4, green x5), the killed one bounded at 30 s. Measured
# with the copied ci.jl directly (no tdd.jl): 4-9 s per run, the killed one 31 s.
const TDD_JL = joinpath(SCRIPTS, "tdd.jl")
const TDD_JL_LOADED = isfile(TDD_JL) && try
    include(TDD_JL)
    isdefined(Main, :Tdd)
catch e
    @error "scripts/tdd.jl failed to load" exception = (e, catch_backtrace())
    false
end
tj_mod() = getfield(Main, :Tdd)
"A named testset that fails (instead of erroring the suite) while scripts/tdd.jl is missing."
tj_testset(f, name) = @testset "$name" begin
    if TDD_JL_LOADED
        f()
    else
        @test isfile(TDD_JL)   # RED: scripts/tdd.jl does not exist yet
    end
end

const TJ_PROJECT = """
name = "TddLane"
uuid = "5d1c7e2a-3b4f-4c6d-9e8f-0a1b2c3d4e5f"
version = "0.1.0"

[compat]
julia = "1.10"

[extras]
Test = "8dfed614-e22c-5e08-85e1-65c5234f0b40"
TestItemRunner = "f8b46487-2199-4994-9208-9a1283c18c0a"

[targets]
test = ["Test", "TestItemRunner"]
"""
"""
The package source. `stub`: export h and declare it (passes H5). `fix`: add h's method. `breakg`:
g returns x + 2 (fails "g adds one"). `extra`: statements appended inside the module.
"""
function tj_src(; stub = false, fix = false, breakg = false, extra = "")
    return """
    module TddLane
    export $(stub ? "g, h" : "g")

    \"\"\"
        g(x)

    g(x) adds one.
    \"\"\"
    function g(x)
        secret_body_marker = $(breakg ? 2 : 1)
        return x + secret_body_marker
    end
    $(stub ? "\n\"\"\"\n    h(x)\n\nh(x) doubles x.\n\"\"\"\nfunction h end\n" : "")$(fix ? "\nh(x) = 2x\n" : "")$extra
    end
    """
end
const TJ_BASE_TEST = """
@testitem "g adds one" begin
    @test g(1) == 2
end
"""
const TJ_RED_TEST = """
@testitem "h doubles" begin
    @test h(2) == 4
end
"""
const TJ_STATE = Dict{Symbol, Any}()
"The shared scratch repo (main checkout), built once."
function tj_repo()
    return get!(TJ_STATE, :repo) do
        files = Dict(
            ".gitignore" => "/.lanes/\n/.worktrees/\n/Manifest*.toml\n/test/Manifest*.toml\n",
            "Project.toml" => TJ_PROJECT,
            "src/TddLane.jl" => tj_src(),
            "test/runtests.jl" => seed_fixture("runtests.jl"),   # the package seed; a coordinator has no test/ (tw-032)
            "test/base_tests.jl" => TJ_BASE_TEST,
        )
        for f in readdir(SCRIPTS)
            p = joinpath(SCRIPTS, f)
            isfile(p) && endswith(f, ".jl") && (files["scripts/$f"] = read(p, String))
        end
        tmp_repo(files)
    end
end
"A new lane worktree `R/.worktrees/<name>` on branch `<name>` from main; its realpath."
function tj_lane(name)
    r = tj_repo()
    d = joinpath(r, ".worktrees", name)
    sh(`git -C $r worktree add -q -b $name $d main`)
    return realpath(d)
end
tj_head(d) = readchomp(`git -C $d rev-parse HEAD`)
tj_ev(d, kind) = joinpath(d, ".lanes", "evidence", "$kind-$(first(tj_head(d), 7)).txt")
tj_tdd_part(path) = (t = read(path, String); i = findlast("--- tdd ---", t); i === nothing ? "" : t[last(i):end])
tj_clean(d) = isempty(read(`git -C $d status --porcelain`, String))
"Call a Tdd function with an IOBuffer as `io`, offline; (exit code, output)."
function tj_call(f, args...; env = (), kw...)
    io = IOBuffer()
    code = withenv("JULIA_PKG_OFFLINE" => "true", env...) do
        f(args...; io, kw...)
    end
    return code, String(take!(io))
end
tj_stub!(d) = commit!(d, Dict("src/TddLane.jl" => tj_src(stub = true)), "feat: declare h\n\nTDD: stub")
tj_red!(d) = commit!(d, Dict("test/h_tests.jl" => TJ_RED_TEST), "test: h doubles\n\nTDD: red")
"The lane `fixed`: stub, red, green (shared by two testsets; nothing here changes it)."
tj_fixed() = get!(TJ_STATE, :fixed) do
    d = tj_lane("fixed")
    tj_stub!(d)
    tj_red!(d)
    commit!(d, Dict("src/TddLane.jl" => tj_src(stub = true, fix = true)), "feat: h doubles\n\nTDD: green")
    d
end

@testset "tdd.jl red, green, api, brief (0.3.0)" begin
    tj_testset("red on a clean red commit exits 0 and writes red-<sha7>") do
        d = tj_lane("red-ok")
        tj_stub!(d)
        tj_red!(d)
        code, out = tj_call(tj_mod().red, d)
        @test code == 0
        ev = tj_ev(d, "red")
        @test isfile(ev)
        part = tj_tdd_part(ev)
        @test occursin("h doubles", part) && occursin("BEHAVIOUR", part)
        @test occursin("h doubles", out) && occursin("BEHAVIOUR", out)
        @test tj_clean(d)                                   # the run leaves nothing in the tree
    end

    tj_testset("red with a passing item exits 1 and names it") do
        d = tj_lane("red-pass")
        commit!(d, Dict("test/p_tests.jl" => "@testitem \"already passes\" begin\n    @test g(1) == 2\nend\n"), "test: passes\n\nTDD: red")
        code, out = tj_call(tj_mod().red, d)
        @test code == 1
        @test occursin("already passes", out) && occursin("PASSED", out)
        @test occursin("PASSED", tj_tdd_part(tj_ev(d, "red")))
    end

    tj_testset("red on a dirty tree exits 2") do
        d = tj_lane("red-dirty")
        tj_stub!(d)
        tj_red!(d)
        write(joinpath(d, "test", "h_tests.jl"), replace(TJ_RED_TEST, "== 4" => "== 5"))   # uncommitted
        code, _ = tj_call(tj_mod().red, d)
        @test code == 2
        @test !isfile(tj_ev(d, "red"))
    end

    tj_testset("red on a commit with no items exits 2") do
        d = tj_lane("red-noitem")
        commit!(d, Dict("test/helpers.jl" => "helper(x) = x\n"), "test: a helper\n\nTDD: red")
        code, _ = tj_call(tj_mod().red, d)
        @test code == 2
        @test !isfile(tj_ev(d, "red"))
    end

    tj_testset("red on a green commit exits 2") do
        d = tj_fixed()
        code, _ = tj_call(tj_mod().red, d)                  # HEAD is `TDD: green`
        @test code == 2
        code, _ = tj_call(tj_mod().red, d; rev = "HEAD~2")  # `TDD: stub` is not red either
        @test code == 2
        @test !isfile(tj_ev(d, "red"))
    end

    tj_testset("killed run is not red") do
        # The item sleeps only when selected by name; ci.jl's CI_TIMEOUT kills the run (exit 124).
        d = tj_lane("red-killed")
        commit!(
            d, Dict("test/k_tests.jl" => "@testitem \"sleeps\" begin\n    \"item=sleeps\" in ARGS && sleep(3600)\n    @test g(1) == 3\nend\n"),
            "test: sleeps\n\nTDD: red"
        )
        code, out = tj_call(tj_mod().red, d; env = ("CI_TIMEOUT" => "30",))
        @test code == 1
        @test occursin("WRONG-REASON", out)
        ev = tj_ev(d, "red")
        @test isfile(ev)
        part = tj_tdd_part(ev)
        @test occursin("sleeps", part) && occursin("WRONG-REASON", part)
    end

    tj_testset("green after the fix exits 0") do
        d = tj_fixed()
        code, out = tj_call(tj_mod().green, d)
        @test code == 0
        @test isfile(tj_ev(d, "green"))
        @test tj_clean(d)
    end

    tj_testset("green with an unmatched name is NOT-RUN") do
        # A :contract item is never selected by item= (spec §3.4), so it is never matched.
        d = tj_lane("green-unmatched")
        commit!(d, Dict("test/c_tests.jl" => "@testitem \"h contract\" tags = [:contract] begin\n    @test true\nend\n"), "test: contract\n\nTDD: red")
        code, out = tj_call(tj_mod().green, d)
        @test code == 1
        @test occursin("h contract", out) && occursin("NOT-RUN", out)
    end

    tj_testset("green fails when the default suite fails") do
        # The red item passes after the fix, but the fix breaks the older item "g adds one".
        d = tj_lane("green-breaks")
        tj_stub!(d)
        tj_red!(d)
        commit!(d, Dict("src/TddLane.jl" => tj_src(stub = true, fix = true, breakg = true)), "feat: h doubles\n\nTDD: green")
        code, out = tj_call(tj_mod().green, d)
        @test code == 1
        @test occursin("g adds one", out)
    end

    tj_testset("api prints docstrings, not bodies") do
        if VERSION < v"1.11"
            @test_skip "api needs Julia >= 1.11"
        else
            d = tj_lane("api")
            extra = """

            \"\"\"
                k()

            k is public.
            \"\"\"
            k() = :k_body_marker
            public k

            \"\"\"
                internal_helper()

            internal is private.
            \"\"\"
            internal_helper() = :internal_body_marker
            """
            commit!(d, Dict("src/TddLane.jl" => tj_src(stub = true, fix = true, extra = extra)), "feat: k")
            code, out = tj_call(tj_mod().api, d)
            @test code == 0
            @test occursin("## g", out) && occursin("g(x) adds one.", out)
            @test occursin("## h", out) && occursin("h(x) doubles x.", out)
            @test occursin("## k", out) && occursin("k is public.", out)          # `public`, not exported
            @test !occursin("secret_body_marker", out) && !occursin("k_body_marker", out) && !occursin("2x", out)
            @test !occursin("internal_helper", out) && !occursin("internal is private.", out)
        end
    end

    tj_testset("api on 1.10 exits 2 NOT RUN") do
        if VERSION >= v"1.11"
            @test_skip "only on Julia < 1.11"
        else
            code, out = tj_call(tj_mod().api, tj_repo())
            @test code == 2
            @test occursin("NOT RUN", out)
        end
    end

    tj_testset("brief refuses a dirty tree") do
        d = tj_lane("brief-dirty")
        tj_stub!(d)
        write(joinpath(d, "src", "TddLane.jl"), tj_src(stub = true, fix = true))   # uncommitted
        code, _ = tj_call(tj_mod().brief, d; role = "test-writer")
        @test code == 2
        dir = joinpath(tj_repo(), ".lanes", "briefs", "brief-dirty")
        @test !isdir(dir) || isempty(readdir(dir))
    end

    tj_testset("brief test-writer has header, api and stub diffs") do
        d = tj_lane("brief-tw")
        tj_stub!(d)
        stub = tj_head(d)
        code, out = tj_call(tj_mod().brief, d; role = "test-writer")
        hdr = "<!-- tdd-brief role=test-writer lane=brief-tw checkout=$(abspath(d)) head=$stub -->"
        @test first(split(out, '\n')) == hdr
        saved = joinpath(tj_repo(), ".lanes", "briefs", "brief-tw", "test-writer-1.md")
        @test isfile(saved)
        txt = isfile(saved) ? read(saved, String) : ""
        @test first(split(txt, '\n')) == hdr
        @test occursin(saved, out)
        @test occursin("## Public API", txt) && occursin("## Stub diffs", txt)
        i = findfirst("## Stub diffs", txt)
        diffs = i === nothing ? "" : txt[last(i):end]
        @test occursin(stub, diffs) && occursin("+function h end", diffs)
        @test !occursin("## Red tests", txt)
        if VERSION >= v"1.11"
            @test code == 0
            api = i === nothing ? "" : txt[1:first(i)]
            @test occursin("g(x) adds one.", api) && !occursin("secret_body_marker", api)
        else
            @test occursin("NOT RUN", txt)                  # the api section says it did not run
        end
    end

    tj_testset("brief refuses a stub that fails H5") do
        d = tj_lane("brief-h5")
        src = replace(tj_src(stub = true), "function h end" => "h(x) = 2x")   # a method body in a stub
        commit!(d, Dict("src/TddLane.jl" => src), "feat: h\n\nTDD: stub")
        stub = tj_head(d)
        code, out = tj_call(tj_mod().brief, d; role = "test-writer")
        @test code == 1
        @test occursin(first(stub, 7), out)
        @test !isfile(joinpath(tj_repo(), ".lanes", "briefs", "brief-h5", "test-writer-1.md"))
    end

    tj_testset("brief header carries checkout= and saves under the owning repo's main .lanes") do
        d = tj_lane("brief-impl")
        tj_stub!(d)
        tj_red!(d)
        head = tj_head(d)
        @test isfile(joinpath(d, ".git"))                   # a worktree: .git is a file naming the main repo
        code, out = tj_call(tj_mod().brief, d; role = "implementer")
        @test code == 0
        hdr = "<!-- tdd-brief role=implementer lane=brief-impl checkout=$(abspath(d)) head=$head -->"
        @test first(split(out, '\n')) == hdr
        saved = joinpath(tj_repo(), ".lanes", "briefs", "brief-impl", "implementer-1.md")
        @test isfile(saved) && occursin(saved, out)
        @test !isdir(joinpath(d, ".lanes", "briefs"))       # never under the lane's own .lanes
        txt = isfile(saved) ? read(saved, String) : ""
        @test first(split(txt, '\n')) == hdr
        @test occursin("## Red tests", txt) && occursin("## Red evidence", txt) && occursin("test/h_tests.jl", txt)
        @test !occursin("## Stub diffs", txt)
        code2, _ = tj_call(tj_mod().brief, d; role = "implementer")
        @test code2 == 0
        @test isfile(joinpath(tj_repo(), ".lanes", "briefs", "brief-impl", "implementer-2.md"))
    end
end
