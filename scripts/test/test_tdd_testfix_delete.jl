# Factory 0.3.1, finding 4 (MAJOR): a deletion-only `TDD: test-fix` (RED tests).
#
# Observed: a test-fix commit that only DELETES @testitems gets `tdd.jl red: <sha7> adds or changes
# no @testitem (exit 2)`, so it can never get red evidence, audit rule E1 (every red/test-fix has a
# passing red-<sha7>) can never pass, and the lane can only be reset.
#
# Decided (option A): a deletion-only test-fix needs no failing-test evidence; its evidence RECORDS
# what it removed. Behaviour and format pinned here (the implementer follows them):
#
# - "Deletion-only": `requested(root, sha).red` is empty (the commit adds or changes no @testitem) and
#   at least one @testitem present at `sha^` in a test file is absent at `sha`.
# - `tdd.jl red` at HEAD = a deletion-only commit with trailer `TDD: test-fix` exits 0 and writes
#   `.lanes/evidence/red-<sha7>.txt` (header as evidence.jl writes it: `head: <full sha>`,
#   `dirty: false`, `termsignal: 0`), whose `--- tdd ---` part holds the verdict line
#   `red <sha7>: OK ...` and one line `REMOVED <name>` per removed item (leading/inner whitespace
#   free, the name exactly as in `@testitem "<name>"`). The tree stays clean. No item class
#   (ASSERTION, BEHAVIOUR, ...) is needed in that part.
# - `tdd.jl red` on a deletion-only `TDD: red` commit still exits 2 and writes nothing: deletion-only
#   is a test-fix privilege.
# - A test-fix that deletes an item AND adds or changes another keeps today's behaviour: the added or
#   changed items are run and must fail for the right reason.
# - E1 (`evidence_rules`, `tdd.jl audit`) accepts a red-<sha7> whose `--- tdd ---` part has
#   `red <sha7>: OK` and at least one `REMOVED <name>` line and no ASSERTION/BEHAVIOUR item, ONLY IF
#   the header is clean with `head` = the commit, the commit's phase is `test-fix`, and audit itself
#   confirms from git that the commit is deletion-only. A hand-written "removed" file on a commit
#   that adds or changes an item, removes nothing, or is a `TDD: red` still fails E1.
# - `tdd.jl green`: an item requested by an earlier red/test-fix and removed by a later deletion-only
#   test-fix authored by a test-side role (TEST_ROLES), with that commit's passing red evidence (as
#   `renamed_by`), is dropped and reported on its own line `REMOVED <name> (test-fix <sha7>)`, not
#   NOT-RUN, and does not fail green. A deletion by any other author or phase is still NOT-RUN.
#
# test_tdd_rename.jl's deletion case was reworked to this decision in a test-fix commit (68c3a5e):
# it no longer pins the old behaviour (red exit 2, then NOT-RUN after a deletion-only test-fix).
#
# Helpers are copied (prefix `tf_`) from test_tdd_cli.jl and test_tdd_history2.jl so this file runs
# alone (FACTORY_TEST_ONLY=test_tdd_testfix_delete.jl). Cost: about eight package test runs.

if !isdefined(Main, :Tdd)
    include(joinpath(SCRIPTS, "tdd.jl"))
end
const TF_TDD = getfield(Main, :Tdd)
const TF_IDS = Dict(
    :tw => ("test-writer", "test-writer@factory.invalid"),
    :pt => ("property-tester", "property-tester@factory.invalid"),
    :impl => ("implementer", "implementer@factory.invalid"),
)

"Write `files`, delete `rm`, and commit everything as `who` (author and committer); the new full sha."
function tf_commit!(d, who, files::Dict, msg; rm = String[])
    for (rel, c) in files
        mkpath(dirname(joinpath(d, rel)))
        write(joinpath(d, rel), c)
    end
    foreach(r -> Base.rm(joinpath(d, r)), rm)
    sh(`git -C $d add -A -- .`)
    n, e = TF_IDS[who]
    sh(`git -C $d -c user.name=$n -c user.email=$e commit -q -m $msg`)
    return readchomp(`git -C $d rev-parse HEAD`)
end
tf_sha7(s) = first(s, 7)
tf_head(d) = readchomp(`git -C $d rev-parse HEAD`)
tf_ev(d, kind) = joinpath(d, ".lanes", "evidence", "$kind-$(tf_sha7(tf_head(d))).txt")
tf_tdd_part(path) = (t = read(path, String); i = findlast("--- tdd ---", t); i === nothing ? "" : t[last(i):end])
tf_clean(d) = isempty(read(`git -C $d status --porcelain`, String))
tf_item(name, body = "@test true") = "@testitem \"$name\" begin\n    $body\nend\n"
"Call a Tdd function with an IOBuffer as `io`, offline; (exit code, output)."
function tf_call(f, args...; kw...)
    io = IOBuffer()
    code = withenv("JULIA_PKG_OFFLINE" => "true") do
        f(args...; io, kw...)
    end
    return code, String(take!(io))
end
"True when some line of `text` is `REMOVED <name>` (any spacing), optionally followed by `suffix`."
tf_removed(text, name; suffix = "") =
    any(l -> occursin(Regex("^\\s*REMOVED\\s+\\Q$name\\E\\s*\\Q$suffix\\E\\s*\$"), l), split(text, '\n'))
"True when some line of `out` says NOT-RUN and ends with exactly `item`."
tf_notrun(out, item) = any(l -> occursin("NOT-RUN", l) && endswith(rstrip(l), item), split(out, '\n'))

# ---- fast: E1 on plain git repos with hand-written evidence (no package runs) ----

const TF_IGNORE = "/.lanes/\n/.worktrees/\n"
const TF_TWO = tf_item("x one") * "\n" * tf_item("x two")
"A repo whose main holds test/x_tests.jl with items `x one` and `x two`, on branch `lane`."
function tf_plain()
    d = tmp_repo(Dict(".gitignore" => TF_IGNORE, "src/P.jl" => "module P\nend\n", "test/x_tests.jl" => TF_TWO))
    sh(`git -C $d checkout -q -b lane`)
    return d
end
"An evidence file as evidence.jl writes it, with a `--- tdd ---` part; its path."
function tf_ev!(d, kind, sha, tdd; dirty = false, sig = 0, exit = 0)
    p = joinpath(d, ".lanes", "evidence", "$kind-$(tf_sha7(sha)).txt")
    mkpath(dirname(p))
    t = "# evidence: written by scripts/evidence.jl. Cite this file; do not retype its numbers.\n" *
        "kind: $kind\nhead: $sha\ndirty: $dirty\ncmd: julia scripts/tdd.jl red\nexit: $exit\ntermsignal: $sig\n" *
        "seconds: 1.0\ndate: 2026-10-27T00:00:00Z\n--- output ---\n(output)\n--- tdd ---\n$tdd\n"
    write(p, t)
    return p
end
"The deletion evidence format pinned above, for `sha` and `names`."
tf_removed_tdd(sha, names) = "red $(tf_sha7(sha)): OK (deletion-only test-fix)\n" * join(["REMOVED $n" for n in names], "\n")
"The E1 lines `evidence_rules` reports for `sha` on the lane `main..HEAD` of `d`."
function tf_e1(d, sha)
    v = TF_TDD.evidence_rules(d, TF_TDD.lane_commits(d, "main"); ledger = nothing)
    return filter(l -> startswith(l, "E1 $(tf_sha7(sha))"), v)
end

@testset "deletion-only test-fix: E1 (0.3.1 finding 4)" begin
    @testset "E1 accepts REMOVED evidence on a deletion-only test-fix (item removed from a file)" begin
        d = tf_plain()
        s = tf_commit!(d, :tw, Dict("test/x_tests.jl" => tf_item("x two")), "test: drop x one\n\nTDD: test-fix")
        @test tf_e1(d, s) != String[]                    # no evidence yet: E1 fails
        tf_ev!(d, "red", s, tf_removed_tdd(s, ["x one"]))
        @test tf_e1(d, s) == String[]
    end

    @testset "E1 accepts REMOVED evidence on a deletion-only test-fix (whole file removed)" begin
        d = tf_plain()
        s = tf_commit!(d, :tw, Dict{String, String}(), "test: drop x\n\nTDD: test-fix"; rm = ["test/x_tests.jl"])
        tf_ev!(d, "red", s, tf_removed_tdd(s, ["x one", "x two"]))
        @test tf_e1(d, s) == String[]
    end

    @testset "E1 rejects REMOVED evidence on a test-fix that also adds an item" begin
        d = tf_plain()
        s = tf_commit!(d, :tw, Dict("test/x_tests.jl" => tf_item("x two") * "\n" * tf_item("x three")), "test: swap\n\nTDD: test-fix")
        tf_ev!(d, "red", s, tf_removed_tdd(s, ["x one"]))
        @test length(tf_e1(d, s)) == 1
    end

    @testset "E1 rejects REMOVED evidence on a test-fix that also changes an item" begin
        d = tf_plain()
        s = tf_commit!(d, :tw, Dict("test/x_tests.jl" => tf_item("x two", "@test 1 == 1")), "test: drop and edit\n\nTDD: test-fix")
        tf_ev!(d, "red", s, tf_removed_tdd(s, ["x one"]))
        @test length(tf_e1(d, s)) == 1
    end

    @testset "E1 rejects REMOVED evidence on a test-fix that removes no item" begin
        d = tf_plain()
        s = tf_commit!(d, :tw, Dict("test/notes.md" => "x\n"), "test: notes\n\nTDD: test-fix")
        tf_ev!(d, "red", s, tf_removed_tdd(s, ["x one"]))
        @test length(tf_e1(d, s)) == 1
    end

    @testset "E1 rejects REMOVED evidence on a deletion-only TDD: red" begin
        d = tf_plain()
        s = tf_commit!(d, :tw, Dict("test/x_tests.jl" => tf_item("x two")), "test: drop x one\n\nTDD: red")
        tf_ev!(d, "red", s, tf_removed_tdd(s, ["x one"]))
        @test length(tf_e1(d, s)) == 1
    end

    @testset "E1 rejects dirty, killed or wrong-head REMOVED evidence" begin
        d = tf_plain()
        s = tf_commit!(d, :tw, Dict("test/x_tests.jl" => tf_item("x two")), "test: drop x one\n\nTDD: test-fix")
        tf_ev!(d, "red", s, tf_removed_tdd(s, ["x one"]); dirty = true)
        @test length(tf_e1(d, s)) == 1
        tf_ev!(d, "red", s, tf_removed_tdd(s, ["x one"]); sig = 9)
        @test length(tf_e1(d, s)) == 1
        p = tf_ev!(d, "red", s, tf_removed_tdd(s, ["x one"]))
        write(p, replace(read(p, String), "head: $s" => "head: $(readchomp(`git -C $d rev-parse main`))"))
        @test length(tf_e1(d, s)) == 1
    end

    @testset "E1 rejects a deletion-only test-fix whose evidence lists nothing removed" begin
        d = tf_plain()
        s = tf_commit!(d, :tw, Dict("test/x_tests.jl" => tf_item("x two")), "test: drop x one\n\nTDD: test-fix")
        tf_ev!(d, "red", s, "red $(tf_sha7(s)): OK (deletion-only test-fix)")
        @test length(tf_e1(d, s)) == 1
    end
end

# Lead's ruling (2ec8012): a deletion-only test-fix may also change a @testsnippet/@testmodule that
# remaining items use. `requested(...).must_pass` is then non-empty, which does not matter: red records
# the removed items (no package run: red_removed only runs `git diff --stat`), and E1 accepts it.
const TF_SNIP_MAIN = "@testsnippet XSnip begin\n    k = 1\nend\n\n" * tf_item("x one") * "\n" *
    "@testitem \"x two\" setup = [XSnip] begin\n    @test k == 1\nend\n"
@testset "deletion-only test-fix that also edits a setup snippet (0.3.1 finding 4)" begin
    d = tmp_repo(Dict(".gitignore" => TF_IGNORE, "src/P.jl" => "module P\nend\n", "test/x_tests.jl" => TF_SNIP_MAIN))
    sh(`git -C $d checkout -q -b lane`)
    edited = replace(replace(TF_SNIP_MAIN, "k = 1" => "k = 2 - 1"), tf_item("x one") * "\n" => "")
    s = tf_commit!(d, :tw, Dict("test/x_tests.jl" => edited), "test: drop x one, tidy XSnip\n\nTDD: test-fix")
    req = TF_TDD.requested(d, s)
    @test isempty(req.red)
    @test [m.name for m in req.must_pass] == ["x two"]    # the snippet edit counts: not vacuous
    @test TF_TDD.removed_items(d, s) == ["x one"]
    code, out = tf_call(TF_TDD.red, d)
    @test code == 0
    @test !occursin("adds or changes no @testitem", out)
    ev = tf_ev(d, "red")
    @test isfile(ev)
    if isfile(ev)
        part = tf_tdd_part(ev)
        @test occursin(Regex("(?m)^red $(tf_sha7(s)): OK\\b"), part)
        @test TF_TDD.removed_names(TF_TDD.evidence_file(ev)) == ["x one"]
    end
    @test tf_clean(d)
    @test tf_e1(d, s) == String[]
end

# ---- slow: tdd.jl red and green on a scratch package ----

const TF_PROJECT = """
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
"The package source: g adds one; `stub` declares and exports h (no method)."
tf_src(; stub = false) = """
module TddLane
export $(stub ? "g, h" : "g")
g(x) = x + 1
$(stub ? "\"\"\"\n    h(x)\n\nh(x) doubles x.\n\"\"\"\nfunction h end\n" : "")
end
"""
const TF_A = "h doubles"
const TF_A2 = "h triples"
const TF_RED = tf_item(TF_A, "@test h(2) == 4") * "\n" * tf_item(TF_A2, "@test h(2) == 6")
const TF_STATE = Dict{Symbol, Any}()
"The shared scratch package repo (main checkout), built once."
function tf_repo()
    return get!(TF_STATE, :repo) do
        files = Dict(
            ".gitignore" => "/.lanes/\n/.worktrees/\n/Manifest*.toml\n/test/Manifest*.toml\n",
            "Project.toml" => TF_PROJECT,
            "src/TddLane.jl" => tf_src(),
            "test/runtests.jl" => seed_fixture("runtests.jl"),
            "test/base_tests.jl" => tf_item("g adds one", "@test g(1) == 2"),
        )
        for f in readdir(SCRIPTS)
            p = joinpath(SCRIPTS, f)
            isfile(p) && endswith(f, ".jl") && (files["scripts/$f"] = read(p, String))
        end
        tmp_repo(files)
    end
end
"A lane worktree with a stub and a test-writer red adding `h doubles` and `h triples` (not run)."
function tf_lane(name)
    r = tf_repo()
    d = joinpath(r, ".worktrees", name)
    sh(`git -C $r worktree add -q -b $name $d main`)
    d = realpath(d)
    tf_commit!(d, :impl, Dict("src/TddLane.jl" => tf_src(stub = true)), "feat: declare h\n\nTDD: stub")
    tf_commit!(d, :tw, Dict("test/h_tests.jl" => TF_RED), "test: h doubles, triples\n\nTDD: red")
    return d
end
"Delete both red items (the whole file) as `who` with trailer `phase`; the sha."
tf_delete!(d, who, phase) = tf_commit!(d, who, Dict{String, String}(), "test: drop h tests\n\nTDD: $phase"; rm = ["test/h_tests.jl"])

@testset "deletion-only test-fix: tdd.jl red and green (0.3.1 finding 4)" begin
    @testset "red on a deletion-only test-fix exits 0 and records the removed items" begin
        d = tf_lane("td-red-ok")
        s = tf_delete!(d, :tw, "test-fix")
        code, out = tf_call(TF_TDD.red, d)
        @test code == 0
        ev = tf_ev(d, "red")
        @test isfile(ev)
        if isfile(ev)
            h = TF_TDD.evidence_file(ev)
            @test get(h.h, "head", "") == s
            @test get(h.h, "dirty", "") == "false"
            @test get(h.h, "termsignal", "") == "0"
            part = tf_tdd_part(ev)
            @test occursin(Regex("(?m)^red $(tf_sha7(s)): OK\\b"), part)
            @test tf_removed(part, TF_A)
            @test tf_removed(part, TF_A2)
        end
        @test tf_removed(out, TF_A)
        @test tf_clean(d)
        # and audit's E1 accepts what red wrote
        @test filter(l -> startswith(l, "E1 $(tf_sha7(s))"), TF_TDD.evidence_rules(d, TF_TDD.lane_commits(d, "main"); ledger = nothing)) == String[]
    end

    @testset "red on a deletion-only TDD: red still exits 2 and writes no evidence" begin
        d = tf_lane("td-red-phase")
        tf_delete!(d, :tw, "red")
        code, out = tf_call(TF_TDD.red, d)
        @test code == 2
        @test occursin("adds or changes no @testitem", out)
        @test !isfile(tf_ev(d, "red"))
    end

    @testset "a test-fix that deletes one item and adds a passing one still fails red" begin
        d = tf_lane("td-red-mixed")
        tf_commit!(d, :tw, Dict("test/h_tests.jl" => tf_item(TF_A2, "@test h(2) == 6") * "\n" * tf_item("g still adds", "@test g(2) == 3")), "test: swap\n\nTDD: test-fix")
        code, out = tf_call(TF_TDD.red, d)
        @test code == 1                                   # the added item passes: not red
        @test occursin("g still adds", out)
    end

    @testset "green reports items removed by a test-side deletion-only test-fix as REMOVED, not NOT-RUN" begin
        for (lane, who) in (("td-green-tw", :tw), ("td-green-pt", :pt))
            d = tf_lane(lane)
            s = tf_delete!(d, who, "test-fix")
            code, _ = tf_call(TF_TDD.red, d)
            @test code == 0
            code, out = tf_call(TF_TDD.green, d)
            @test code == 0
            @test !tf_notrun(out, TF_A)
            @test !tf_notrun(out, TF_A2)
            @test tf_removed(out, TF_A; suffix = "(test-fix $(tf_sha7(s)))")
            @test tf_removed(out, TF_A2; suffix = "(test-fix $(tf_sha7(s)))")
        end
    end

    @testset "green still reports NOT-RUN when the deleting commit is not a test-side test-fix" begin
        d = tf_lane("td-green-impl")
        tf_delete!(d, :impl, "test-fix")
        tf_call(TF_TDD.red, d)                            # its exit code is not asserted
        code, out = tf_call(TF_TDD.green, d)
        @test code == 1
        @test tf_notrun(out, TF_A)
        @test !tf_removed(out, TF_A; suffix = "(test-fix $(tf_sha7(tf_head(d))))")
    end
end
