# Tests for scripts/_tdd_history.jl and `tdd.jl audit`, part 2 (plan Task 5): H5 on scratch git repos,
# `lane_commits`/`trailers`, the evidence rules E1-E5 and `audit`. Included by test_tdd.jl right after
# test_tdd_history.jl, whose header holds the representation choices and whose helpers (th, th_testset, th_has, TW,
# IMPL, LEAD, OTHER) this file uses. Further choices made here:
#
# - `trailers(msg)` returns a Dict{String,String} of the `Key: value` lines of the message's last
#   paragraph. `lane_commits(root, base)` yields LaneCommits oldest first, merges skipped, `paths`
#   from the commit's own diff (sorted here before comparing).
# - Mutate evidence: evidence.jl names a file `<kind>-<sha7>.txt`, so the kind `mutate-<slug>` is
#   the file `mutate-<slug>-<sha7>.txt` (sha7 of the HEAD the mutator ran at; here the backfill
#   commit). E3 accepts any passing `mutate-<slug>-*.txt` or `mutexp-<slug>-*.txt`.
# - H5 for a file the commit adds: its parent side is empty, and an `include` of it is allowed only
#   when the commit adds the file. Including a file that already existed is not a declaration.
using SHA

const TH_IDS = Dict(
    TW => ("test-writer", "test-writer@factory.invalid"), IMPL => ("implementer", "implementer@factory.invalid"),
    LEAD => ("lead", "lead@factory.invalid"), OTHER => ("Some One", "someone@example.com"),
)
"Write `files` and commit everything as `author` (author and committer); the new full sha."
function th_commit!(d, author, files::Dict, msg)
    for (rel, c) in files
        mkpath(dirname(joinpath(d, rel)))
        write(joinpath(d, rel), c)
    end
    sh(`git -C $d add -A -- .`)
    n, e = TH_IDS[author]
    sh(`git -C $d -c user.name=$n -c user.email=$e commit -q --allow-empty -m $msg`)
    return readchomp(`git -C $d rev-parse HEAD`)
end
th_sha(d, rev = "HEAD") = readchomp(`git -C $d rev-parse $rev`)
th_fix(n) = read(joinpath(TDD_FIX, "h5", n), String)

"""
H5 on a scratch repo: `file` holds `parent` on main, then a `TDD: stub` commit writes `child` and
`extra`. Checks that `stub_declares_only` and `history_rules` (which must report H5 exactly when
the stub does not only declare) agree, and returns `stub_declares_only`.
"""
function th_h5ok(parent, child; file = "src/P.jl", extra = Dict{String, String}(), base = Dict{String, String}())
    d = tmp_repo(merge(Dict(file => parent), base))
    sha = th_commit!(d, IMPL, merge(Dict(file => child), extra), "feat: declare\n\nTDD: stub")
    ok = th(:stub_declares_only)(d, sha)
    c = th(:LaneCommit)(sha, IMPL, "stub", nothing, sort!([file; collect(keys(extra))]))
    v = th(:history_rules)([c]; stub_ok = s -> th(:stub_declares_only)(d, s))
    @test ok == !th_has(v, "H5")
    return ok
end
const P0 = "module P\nexport f\nf(x) = x + 1\nend\n"
pmod(body) = "module P\n$(body)end\n"

const TH_IGNORE = "/.lanes/\n/.worktrees/\n"
const TH_P1 = "module P\nexport f, g\nfunction g end\nf(x) = x + 1\nend\n"
const TH_P2 = "module P\nexport f, g\nfunction g end\nf(x) = x + 1\ng(x) = 2x\nend\n"
const TH_T = "@testitem \"g doubles\" begin\n    using P\n    @test g(2) == 4\nend\n"
"A repo on main and branch `lane`: an optional lead mode commit, then stub, red, green."
function th_lane(; mode = nothing)
    d = tmp_repo(Dict(".gitignore" => TH_IGNORE, "src/P.jl" => P0, "Project.toml" => "name = \"P\"\n"))
    sh(`git -C $d checkout -q -b lane`)
    m = mode === nothing ? nothing : th_commit!(d, LEAD, Dict{String, String}(), "chore: mode\n\nTDD-Mode: $mode")
    s = th_commit!(d, IMPL, Dict("src/P.jl" => TH_P1), "feat: declare g\n\nTDD: stub")
    r = th_commit!(d, TW, Dict("test/g_tests.jl" => TH_T), "test: g doubles\n\nTDD: red")
    g = th_commit!(d, IMPL, Dict("src/P.jl" => TH_P2), "feat: g doubles\n\nTDD: green")
    return d, (; mode = m, stub = s, red = r, green = g)
end
"An evidence file as evidence.jl writes it, with an optional `--- tdd ---` part; its path."
function th_ev!(d, kind, sha; exit = 0, dirty = false, sig = 0, tdd = nothing)
    p = joinpath(d, ".lanes", "evidence", "$kind-$(first(sha, 7)).txt")
    mkpath(dirname(p))
    t = "# evidence: written by scripts/evidence.jl. Cite this file; do not retype its numbers.\n" *
        "kind: $kind\nhead: $sha\ndirty: $dirty\ncmd: julia scripts/ci.jl test\nexit: $exit\ntermsignal: $sig\n" *
        "seconds: 1.0\ndate: 2026-10-26T00:00:00Z\n--- output ---\n(output)\n"
    tdd === nothing || (t *= "--- tdd ---\n$tdd\n")
    write(p, t)
    return p
end
th_red_ev!(d, sha; kw...) = th_ev!(d, "red", sha; exit = 1, tdd = "g doubles BEHAVIOUR", kw...)
# The verdicts tdd.jl writes under `--- tdd ---` (tdd.jl green; _tdd_backfill.jl mutate): passing
# green and mutate evidence carries them, not only `exit: 0` (review M3, test_tdd_review.jl).
const TH_GREEN_TDD = "green items: OK (1 red item(s), run exit 0, total 1)\n  PASSED       g doubles\ngreen default suite: OK (exit 0)"
const TH_KILLED_TDD = "mutant run (scratch x): ASSERTION\nreal run: PASSED (exit 0)\nKILLED: the item detects the mutation (exit 0)"
"A passing green evidence file for `sha`: exit 0 and tdd.jl's verdict."
th_green_ev!(d, sha; kw...) = th_ev!(d, "green", sha; tdd = TH_GREEN_TDD, kw...)
th_rec(ev, type, d, sha) = """{"ts":"2026-10-26T00:00:00Z","ev":"$ev","session":"s1","agent_id":"a$(first(sha, 7))","agent_type":"$type","checkout":"$d","sha":"$sha"}"""
function th_ledger!(path, lines)
    mkpath(dirname(path))
    write(path, isempty(lines) ? "" : join(lines, "\n") * "\n")
    return path
end
th_lane_recs(d, c) = [th_rec("tdd-commit", "implementer", d, c.stub), th_rec("tdd-commit", "test-writer", d, c.red), th_rec("tdd-commit", "implementer", d, c.green)]
"evidence_rules over the lane `main..HEAD` of `d`, with the ledger lines `recs`."
er(d, recs) = th(:evidence_rules)(d, th(:lane_commits)(d, "main"); ledger = th_ledger!(tempname() * ".jsonl", recs))
th_slug(name) = first(replace(lowercase(name), r"[^a-z0-9]+" => "-"), 24) * "-" * bytes2hex(sha1(name))[1:8]

@testset "tdd H5 on git, lane_commits, E1-E5, audit (0.3.0)" begin
    H5 = (:LaneCommit, :history_rules, :stub_declares_only)

    th_testset("stub with a method body fails H5", H5...) do
        @test !th_h5ok(P0, pmod("export f, g\ng(x) = 2x\nf(x) = x + 1\n"))
        @test !th_h5ok(P0, pmod("export f, g\nfunction g(x)\n    2x\nend\nf(x) = x + 1\n"))
        @test !th_h5ok(P0, pmod("export f\nf(x) = x + 1\nf(x::String) = 0\n"))   # a new method on f
    end

    th_testset("stub with inner constructor fails H5", H5...) do
        @test !th_h5ok(P0, pmod("export f, S\nstruct S\n    x::Int\n    S(x) = new(x)\nend\nf(x) = x + 1\n"))
        # the same struct, field-only, passes; so do the other declaration forms
        decls = "export f, S, M, A, B\n\"doc S\"\nstruct S\n    x::Int\nend\nmutable struct M\n    y\nend\n" *
            "abstract type A end\nprimitive type B 8 end\nusing Base: Fix1\nimport Base: show\nf(x) = x + 1\n"
        @test th_h5ok(P0, pmod(decls))
    end

    th_testset("stub with @kwdef fails H5", H5...) do
        @test !th_h5ok(P0, pmod("export f, K\nBase.@kwdef struct K\n    a::Int = 1\nend\nf(x) = x + 1\n"))
        @test !th_h5ok(P0, pmod("export f, K\n@kwdef struct K\n    a::Int = 1\nend\nf(x) = x + 1\n"))
    end

    th_testset("stub adding export + function-end inside the module block passes H5", H5...) do
        @test th_h5ok(th_fix("parent.jl"), th_fix("child.jl"); file = "src/Pkg1.jl")   # NB2, the critic's pair
    end

    th_testset("stub adding include of a new declaration-only file passes H5", H5...) do
        decl = "export g\n\"doc g\"\nfunction g end\nstruct T\n    a::Int\nend\n"
        @test th_h5ok(P0, pmod("export f\ninclude(\"decl.jl\")\nf(x) = x + 1\n"); extra = Dict("src/decl.jl" => decl))
    end

    th_testset("stub adding include of a file with a method fails H5", H5...) do
        bad = "function g end\ng(x) = 1\n"
        @test !th_h5ok(P0, pmod("export f\ninclude(\"decl.jl\")\nf(x) = x + 1\n"); extra = Dict("src/decl.jl" => bad))
        # including a file the commit does not add is not a declaration, however harmless the file
        @test !th_h5ok(P0, pmod("export f\ninclude(\"old.jl\")\nf(x) = x + 1\n"); base = Dict("src/old.jl" => "h(x) = 3\n"))
    end

    th_testset("stub adding a name to @compat public passes H5", H5...) do
        # R4-B1: `@compat public a, h` is macrocall(@compat, LNN, :public, (a, h)); a matcher that
        # takes one argument after the line slot fails both pairs
        @test th_h5ok(th_fix("names-p.jl"), th_fix("names-c.jl"))
        @test th_h5ok(th_fix("p2.jl"), th_fix("c2.jl"))
    end

    th_testset("is_compat_decl: public with one name, a tuple, and export; rejects @compat with any other payload", :is_compat_decl, :strip_lines!) do
        ok = ("@compat public a", "@compat public a, h", "@compat public (a, h)", "Compat.@compat public a",
            "Compat.@compat public a, h", "@compat export g", "@compat export g, h", "Compat.@compat export g")
        bad = ("@compat f(x) = 1", "@compat public f(x)", "@compat public a, f(x)", "@compat begin end", "@compat 1",
            "@compat", "@compat public a b", "@compat public \"a\"", "@other public a", "Compat.@other export g",
            "export g", "@compat import Base: show", "@compat const c = 1")
        for s in ok
            e = Meta.parse(s)
            @test th(:is_compat_decl)(e)
            th(:strip_lines!)(e)
            @test e.args[2] === nothing           # the macrocall's own line slot is cleared
            @test th(:is_compat_decl)(e)          # and it is still a declaration
        end
        for s in bad
            @test !th(:is_compat_decl)(Meta.parse(s))
        end
    end

    th_testset("stub adding @compat export passes H5", H5...) do
        @test th_h5ok(P0, pmod("export f\n@compat export g\nfunction g end\nf(x) = x + 1\n"))
        @test th_h5ok(P0, pmod("export f\nCompat.@compat export g, h\nfunction g end\nfunction h end\nf(x) = x + 1\n"))
        @test !th_h5ok(P0, pmod("export f\n@compat g(x) = 1\nf(x) = x + 1\n"))
    end

    th_testset("stub inserted above a documented method passes H5", H5...) do
        @test th_h5ok(th_fix("p4.jl"), th_fix("c4.jl"))   # R4-M1: Core.@doc's line slot moves
    end

    th_testset("stub inserted above an undocumented method passes H5", H5...) do
        @test th_h5ok(th_fix("p6.jl"), th_fix("c6.jl"))
    end

    th_testset("stub that deletes a method fails H5", H5...) do
        @test !th_h5ok(th_fix("p3.jl"), th_fix("c3.jl"))
        @test !th_h5ok(th_fix("p5.jl"), th_fix("c5.jl"))
    end

    th_testset("stub replacing an export by a superset passes; by a subset fails", H5...) do
        @test th_h5ok(P0, pmod("export f, g\nfunction g end\nf(x) = x + 1\n"))
        @test th_h5ok(pmod("@compat public a\n"), pmod("@compat public a, b\nfunction b end\n"))
        @test !th_h5ok(pmod("export f, g\nf(x) = 1\ng(x) = 2\n"), pmod("export f\nf(x) = 1\ng(x) = 2\n"))
        @test !th_h5ok(pmod("export f\nf(x) = 1\n"), pmod("export g\nf(x) = 1\nfunction g end\n"))   # not a superset
        @test !th_h5ok(pmod("@compat public a, b\n"), pmod("@compat public a\n"))
    end

    th_testset("merge commits ignored", :lane_commits, :trailers) do
        t = th(:trailers)("feat: x\n\nTDD: red appears in the body\n\nTDD: green\nTDD-Mode: skip — spike")
        @test t["TDD"] == "green" && t["TDD-Mode"] == "skip — spike"
        d, c = th_lane(mode = "refactor — rename only")
        sh(`git -C $d checkout -q main`)
        onmain = th_commit!(d, OTHER, Dict("docs/x.md" => "x\n"), "docs: x")
        sh(`git -C $d checkout -q lane`)
        sh(`git -C $d -c user.name=lead -c user.email=lead@factory.invalid merge -q --no-ff -m "merge main" main`)
        merge = th_sha(d)
        cs = th(:lane_commits)(d, "main")
        @test [x.sha for x in cs] == [c.mode, c.stub, c.red, c.green]   # oldest first; no merge, no main commit
        @test merge ∉ [x.sha for x in cs] && onmain ∉ [x.sha for x in cs]
        @test [x.author for x in cs] == [LEAD, IMPL, TW, IMPL]
        @test [x.phase for x in cs] == [nothing, "stub", "red", "green"]
        @test cs[1].mode == ("refactor", "rename only") && all(x -> x.mode === nothing, cs[2:end])
        @test isempty(cs[1].paths) && sort(cs[3].paths) == ["test/g_tests.jl"] && cs[4].paths == ["src/P.jl"]
    end

    E = (:lane_commits, :evidence_rules)

    th_testset("missing red evidence fails E1", E...) do
        d, c = th_lane()
        th_green_ev!(d, c.green)
        @test th_has(er(d, th_lane_recs(d, c)), "E1")
        th_red_ev!(d, c.red)
        @test isempty(er(d, th_lane_recs(d, c)))                           # the complete lane passes
        th_ev!(d, "red", c.red; exit = 1, tdd = "g doubles PASSED")        # a red run whose item passed
        @test th_has(er(d, th_lane_recs(d, c)), "E1")
    end

    th_testset("green without green evidence fails E2", E...) do
        d, c = th_lane()
        th_red_ev!(d, c.red)
        @test th_has(er(d, th_lane_recs(d, c)), "E2")
        th_ev!(d, "green", c.green; exit = 1)                              # a failing green run
        @test th_has(er(d, th_lane_recs(d, c)), "E2")
    end

    th_testset("refactor mode needs green at merge base (E2)", E...) do
        d = tmp_repo(Dict(".gitignore" => TH_IGNORE, "src/P.jl" => P0))
        mb = th_sha(d)
        sh(`git -C $d checkout -q -b lane`)
        th_commit!(d, LEAD, Dict{String, String}(), "chore: mode\n\nTDD-Mode: refactor — rename internals")
        rf = th_commit!(d, IMPL, Dict("src/P.jl" => replace(P0, "x + 1" => "1 + x")), "refactor: swap\n\nTDD: refactor")
        th_green_ev!(d, rf)
        recs = [th_rec("tdd-commit", "implementer", d, rf)]
        @test th_has(er(d, recs), "E2")
        th_green_ev!(d, mb)
        @test !th_has(er(d, recs), "E2")
    end

    th_testset("backfill item without mutate evidence fails E3", E...) do
        d = tmp_repo(Dict(".gitignore" => TH_IGNORE, "src/P.jl" => P0))
        sh(`git -C $d checkout -q -b lane`)
        items = "@testitem \"f adds one\" begin\n    using P\n    @test P.f(1) == 2\nend\n\n" *
            "@testitem \"f: Int overflow!\" begin\n    using P\n    @test P.f(typemax(Int)) > 0\nend\n"
        b = th_commit!(d, TW, Dict("test/f_tests.jl" => items), "test: backfill f\n\nTDD: backfill")
        recs = [th_rec("tdd-commit", "test-writer", d, b)]
        @test th_has(er(d, recs), "E3")
        th_ev!(d, "mutate-$(th_slug("f adds one"))", b; tdd = TH_KILLED_TDD)
        @test th_has(er(d, recs), "E3")                                    # one item still unproved
        th_ev!(d, "mutexp-$(th_slug("f: Int overflow!"))", b; tdd = TH_KILLED_TDD)
        @test !th_has(er(d, recs), "E3")
        th_ev!(d, "mutate-$(th_slug("f adds one"))", b; exit = 1)          # a failed mutate proves nothing
        @test th_has(er(d, recs), "E3")
    end

    th_testset("@test_broken-only item exempt from E3", E...) do
        d = tmp_repo(Dict(".gitignore" => TH_IGNORE, "src/P.jl" => P0))
        sh(`git -C $d checkout -q -b lane`)
        items = "@testitem \"f of nothing\" begin\n    using P\n    # BUG: f(nothing) throws; reported 2026-10-26\n" *
            "    @test_broken P.f(nothing) == 1\nend\n"
        b = th_commit!(d, TW, Dict("test/f_tests.jl" => items), "test: backfill f\n\nTDD: backfill")
        @test !th_has(er(d, [th_rec("tdd-commit", "test-writer", d, b)]), "E3")
    end

    th_testset("dirty evidence fails E4", E...) do
        d, c = th_lane()
        th_red_ev!(d, c.red; dirty = true)
        th_green_ev!(d, c.green)
        @test th_has(er(d, th_lane_recs(d, c)), "E4")
    end

    th_testset("killed evidence fails E4", E...) do
        d, c = th_lane()
        th_red_ev!(d, c.red)
        th_ev!(d, "green", c.green; exit = 143, sig = 15)
        @test th_has(er(d, th_lane_recs(d, c)), "E4")
    end

    th_testset("role commit without tdd-commit record fails E5", E...) do
        # Review Focus 6: an amended or `-C HEAD` commit leaves no record with its own sha
        d, c = th_lane()
        th_red_ev!(d, c.red)
        th_green_ev!(d, c.green)
        recs = th_lane_recs(d, c)
        @test !th_has(er(d, recs), "E5")
        @test th_has(er(d, recs[1:2]), "E5")                               # green has no record
        @test th_has(er(d, [recs[1], recs[3]]), "E5")                      # red has no record
        @test th_has(er(d, String[]), "E5")
        @test th_has(er(d, [recs[1], th_rec("tdd-commit", "test-writer", d, c.stub), recs[3]]), "E5")   # wrong sha
    end

    th_testset("tdd-commit record with another agent_type fails E5", E...) do
        d, c = th_lane()
        th_red_ev!(d, c.red)
        th_green_ev!(d, c.green)
        for other in ("test-writer", "general-purpose", "")
            recs = th_lane_recs(d, c)
            recs[3] = th_rec("tdd-commit", other, d, c.green)
            @test th_has(er(d, recs), "E5")
        end
    end

    th_testset("tdd-commit-violation for the lane fails E5", E...) do
        d, c = th_lane()
        th_red_ev!(d, c.red)
        th_green_ev!(d, c.green)
        recs = th_lane_recs(d, c)
        @test th_has(er(d, [recs; th_rec("tdd-commit-violation", "implementer", d, c.green)]), "E5")
        @test th_has(er(d, [recs; th_rec("tdd-commit-violation", "implementer", "/elsewhere", c.stub)]), "E5")
        # B2 ruling: violations match by the lane's shas only; one in this checkout for a sha outside the
        # lane (e.g. a sha a later commit replaced) is not this lane's
        @test !th_has(er(d, [recs; th_rec("tdd-commit-violation", "implementer", d, "f"^40)]), "E5")
        @test !th_has(er(d, [recs; th_rec("tdd-commit-violation", "implementer", "/elsewhere", "f"^40)]), "E5")
    end

    th_testset("B2 E5 violation for a sha not in the lane does not fail the lane", E...) do
        d, c = th_lane()
        th_red_ev!(d, c.red)
        th_green_ev!(d, c.green)
        recs = th_lane_recs(d, c)
        @test !th_has(er(d, [recs; th_rec("tdd-commit-violation", "test-writer", d, "f"^40)]), "E5")   # same checkout
        @test th_has(er(d, [recs; th_rec("tdd-commit-violation", "test-writer", "/elsewhere", c.red)]), "E5")
    end

    th_testset("B2 E5 late-only record fails with the late hint", E...) do
        d, c = th_lane()
        th_red_ev!(d, c.red)
        th_green_ev!(d, c.green)
        recs = th_lane_recs(d, c)
        recs[2] = th_rec("tdd-commit-late", "test-writer", d, c.red)
        v = er(d, recs)
        e5 = filter(s -> startswith(s, "E5 $(first(c.red, 7))"), v)
        @test !isempty(e5) && any(s -> occursin("only a late swept record", s), e5)
        @test !any(s -> occursin("late", s), er(d, th_lane_recs(d, c)[1:2]))   # green unrecorded: no hint without a late record
    end

    th_testset("E5 default ledger is the outermost .lanes/ledger.jsonl above the lane", :audit) do
        # A coordinator-style root C holds the nested package repo C/Pkg.jl, which has its own .lanes;
        # the lane is the worktree C/Pkg.jl/.worktrees/lane.
        C = realpath(mktempdir())
        anc = [dirname(C)]
        while dirname(anc[end]) != anc[end]
            push!(anc, dirname(anc[end]))
        end
        @test !any(a -> isfile(joinpath(a, ".lanes", "ledger.jsonl")), anc)   # precondition
        d0, c = th_lane()
        pkg = joinpath(C, "Pkg.jl")
        mv(d0, pkg)
        sh(`git -C $pkg checkout -q main`)
        sh(`git -C $pkg worktree add -q $(joinpath(pkg, ".worktrees", "lane")) lane`)
        lane = realpath(joinpath(pkg, ".worktrees", "lane"))
        th_red_ev!(lane, c.red)
        th_green_ev!(lane, c.green)
        outer, inner = joinpath(C, ".lanes", "ledger.jsonl"), joinpath(pkg, ".lanes", "ledger.jsonl")
        aud() = (io = IOBuffer(); code = th(:audit)(lane; base = "main", io); (code, String(take!(io))))

        th_ledger!(outer, th_lane_recs(lane, c))
        th_ledger!(inner, String[])
        code, out = aud()
        @test code == 0
        @test !occursin(r"^E5"m, out)

        th_ledger!(outer, String[])
        th_ledger!(inner, th_lane_recs(lane, c))
        code, out = aud()
        @test code == 1
        @test occursin(r"^E5"m, out)
    end
end
