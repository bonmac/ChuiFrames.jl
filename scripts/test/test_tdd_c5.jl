# Review of the critic fixes (factory 0.3.0, round after critic-030). Written red; the implementer does not edit it.
# Included by runtests.jl after test_tdd_c4.jl: uses c3_commit!/c3_repo/c3_hlines/c3_dodtdd/C3_PSRC of
# test_tdd_c3.jl, th/th_testset/th_has and TW/IMPL/LEAD of test_tdd_history.jl, tb_* of test_hooks_tdd.jl,
# tmp_repo/sh of runtests.jl.
#
# Lead's rulings (the behaviour specified here):
# FIX-1 a sub-lane merged twice: segments of merges whose second parents lie on one first-parent chain (the
#   same sub-lane, merged again) are one segment. A different sub-lane (whose chain reaches the first merge's
#   second parent only through a merge's second parent) stays its own segment; nested merges stay as they are.
# CONSIDER-2 `trailers(msg)` agrees with git's commit parser: no `---` divider (git reads a commit's trailers
#   from the last paragraph of the whole message).
# NIT-1 the `=` form of `--trailer` (`--trailer "TDD-Mode=skip — r"`, git writes `Key: value`) is denied at Pre
#   for a role caller, rules `mode-trailer` / `waiver-trailer`, as the `: ` form is.
# NIT-2 parse_mode also accepts the en dash ` – ` as the reason separator.
#
# Assumptions: names `lane_segments(root, base, commits, head)`, `segment_rules(segs; stub_ok)`, `lane_commits`,
# `trailers(msg)`, `git_trailer(root, sha, key)` and `parse_mode(v)` of Tdd stay as today.

"Commit `sub`'s red (test-writer) and green (implementer) on the current branch; (red, green) shas."
c5_red_green(d; t = "test/f_tests.jl", n = 2) =
    (
    c3_commit!(d, TW, Dict(t => "@testitem \"f\" begin\n    @test true\nend\n"), "test: f"; trailers = ["TDD: red"]),
    c3_commit!(d, IMPL, Dict("src/P.jl" => C3_PSRC(n)), "feat: f"; trailers = ["TDD: green"]),
)
c5_merge!(d, into, from, msg) = (sh(`git -C $d checkout -q $into`); sh(`git -C $d merge -q --no-ff -m $msg $from`))
"segment_rules over lane_segments of base main..`head` (every stub ok)."
function c5_srules(d, head)
    cs = th(:lane_commits)(d, "main", head)
    return th(:segment_rules)(th(:lane_segments)(d, "main", cs, head); stub_ok = _ -> true)
end

# ---- FIX-1: one sub-lane merged twice ----
@testset "review FIX-1: a sub-lane merged twice is one segment" begin
    A = (:audit, :lane_commits, :lane_segments, :segment_rules)

    th_testset("reviewer's reproducer: red, green, merge m1, refactor, merge m2 -> segment_rules is empty", A...) do
        d = tmp_repo()
        sh(`git -C $d checkout -q -b integ`)
        sh(`git -C $d checkout -q -b sub`)
        c3_commit!(d, TW, Dict("test/f_tests.jl" => "@testitem \"f\" begin\n    @test true\nend\n"), "test: f"; trailers = ["TDD: red"])
        c3_commit!(d, IMPL, Dict("src/f.jl" => "f(x) = x\n"), "feat: f"; trailers = ["TDD: green"])
        c5_merge!(d, "integ", "sub", "m1")
        sh(`git -C $d checkout -q sub`)
        c3_commit!(d, IMPL, Dict("src/f.jl" => "f(y) = y\n"), "refactor: f"; trailers = ["TDD: refactor"])
        c5_merge!(d, "integ", "sub", "m2")
        r = c5_srules(d, "integ")
        @test r == String[] || (println("FIX-1 reproducer: ", r); false)
    end

    th_testset("sub-lane merged twice on the template repo: audit H lines and dod's tdd pass", A...) do
        d = c3_repo()
        sh(`git -C $d checkout -q -b sub int`)
        c5_red_green(d)
        c5_merge!(d, "int", "sub", "merge sub (1)")
        sh(`git -C $d checkout -q sub`)
        c3_commit!(d, IMPL, Dict("src/P.jl" => "module P\nf(y) = y\ng2(y) = 2 * y\nend\n"), "refactor: f"; trailers = ["TDD: refactor"])
        c5_merge!(d, "int", "sub", "merge sub (2)")
        h = c3_hlines(d)
        @test !th_has(h, "H2") || (println("FIX-1 H2: ", h); false)
        @test !th_has(h, "H6") || (println("FIX-1 H6: ", h); false)
        @test isempty(h) || (println("FIX-1 H lines: ", h); false)
        row = c3_dodtdd(d)
        @test row !== nothing && row[1] == "PASS" || (println("FIX-1 dod: ", row); false)
    end

    th_testset("control: a different sub-lane cut after the first merge, green with no red, is still reported", A...) do
        d = c3_repo()
        sh(`git -C $d checkout -q -b sub int`)
        c5_red_green(d)
        c5_merge!(d, "int", "sub", "merge sub")
        sh(`git -C $d checkout -q -b other int`)   # reaches sub's tip only through the first merge's second parent
        g = c3_commit!(d, IMPL, Dict("src/P.jl" => C3_PSRC(3)), "feat: g3"; trailers = ["TDD: green"])
        c5_merge!(d, "int", "other", "merge other")
        h = c3_hlines(d)
        @test th_has(h, "H2") || th_has(h, "H6") || (println("FIX-1 control no H2/H6: ", h); false)
        @test any(l -> occursin(r"^H[26]", l) && occursin(first(g, 7), l), h) || (println("FIX-1 control no sha $(first(g, 7)): ", h); false)
        r = c5_srules(d, "int")
        @test any(l -> occursin(r"^H[26]", l), r) || (println("FIX-1 control segment_rules: ", r); false)
        row = c3_dodtdd(d)
        @test row !== nothing && row[1] == "FAIL" && occursin(r"^H[26]", row[2]) || (println("FIX-1 control dod: ", row); false)
    end

    th_testset("control: nested merges (a merges b, int merges a) with red in b and green in a pass", A...) do
        d = c3_repo()
        sh(`git -C $d checkout -q -b a int`)
        sh(`git -C $d checkout -q -b b a`)
        c3_commit!(d, TW, Dict("test/f_tests.jl" => "@testitem \"f\" begin\n    @test true\nend\n"), "test: f"; trailers = ["TDD: red"])
        c5_merge!(d, "a", "b", "merge b into a")
        c3_commit!(d, IMPL, Dict("src/P.jl" => C3_PSRC(2)), "feat: f"; trailers = ["TDD: green"])
        c5_merge!(d, "int", "a", "merge a")
        h = c3_hlines(d)
        @test isempty(h) || (println("FIX-1 nested: ", h); false)
        @test c5_srules(d, "int") == String[]
    end
end

# ---- CONSIDER-2: trailers(msg) reads the message as git's commit parser does ----
@testset "review CONSIDER-2: trailers(msg) has no --- divider" begin
    msg = "s\n\nTDD: red\n---\nfoo\n\nCo-Authored-By: x"
    th_testset("a TDD: line before --- in a non-final paragraph is not a trailer", :trailers) do
        tr = th(:trailers)(msg)
        @test !haskey(tr, "TDD") || (println("CONSIDER-2 trailers: ", tr); false)
        @test get(tr, "Co-Authored-By", "") == "x"
    end
    th_testset("on a real commit, trailers(git log %B) agrees with git_trailer for TDD", :trailers, :git_trailer) do
        for m in (msg, "s\n\nbody\n---\nTDD: red", "s\n\nTDD: red", "s\n---\n\nTDD: green\nCo-Authored-By: x")
            d = tmp_repo()
            sh(`git -C $d commit -q --allow-empty -m $m`)
            sha = readchomp(`git -C $d rev-parse HEAD`)
            body = read(`git -C $d log -1 --format=%B $sha`, String)
            @test get(th(:trailers)(body), "TDD", "") == th(:git_trailer)(d, sha, "TDD") ||
                (println("CONSIDER-2 $(repr(m)): trailers ", th(:trailers)(body), " git ", repr(th(:git_trailer)(d, sha, "TDD"))); false)
        end
    end
end

# ---- NIT-1: the = form of --trailer at the commit guard ----
@testset "review NIT-1: --trailer \"Key=value\" is denied at Pre for a role caller" begin
    t = tb_topo(); L = t.lane
    deny_rule(r, rule) = r.rc == 2 && occursin("($rule)", r.err)
    LAW = "law-tester <law-tester@factory.invalid>"
    cases = (("TDD-Waiver=E5 $(first(tb_head(L), 7)) — r", "waiver-trailer"), ("TDD-Mode=skip — r", "mode-trailer"))
    @testset "git writes `Key: value` for the = form (sanity)" begin
        d = tmp_repo()
        sh(`git -C $d commit -q --allow-empty -m s --trailer "TDD-Mode=skip — r"`)
        @test strip(readchomp(`git -C $d log -1 "--format=%(trailers:key=TDD-Mode,valueonly)"`)) == "skip — r"
    end
    # control (passes today): the `Key: value` form of the same trailers is denied for both callers
    for (tr, rule) in cases, (agent, who) in (("law-tester", LAW), ("implementer", TB_IMPL))
        tr2 = replace(tr, "=" => ": "; count = 1)
        c = "git -C $L commit -q -m \"x\" --trailer \"$tr2\" --author \"$who\""
        @test deny_rule(tb_run(t, tb_bash(c; agent, cwd = L)), rule)
    end
    for (tr, rule) in cases, (agent, who, subj, ph) in (("law-tester", LAW, "test: laws", "red"), ("implementer", TB_IMPL, "feat: x", "green"))
        @testset "$agent --trailer \"$(first(tr, 10))…\" denied ($rule)" begin
            c = "git -C $L commit -q -m \"$subj\" --trailer \"TDD: $ph\" --trailer \"$tr\" --author \"$who\""
            r = tb_run(t, tb_bash(c; agent, cwd = L))
            @test deny_rule(r, rule) || (println("NIT-1 $agent $(repr(tr)) not denied (rc $(r.rc)): ", r.err); false)
        end
    end
end

# ---- NIT-2: the en dash separator ----
@testset "review NIT-2: parse_mode accepts the en dash" begin
    th_testset("parse_mode(\"skip – en\") == (\"skip\", \"en\")", :parse_mode) do
        pm = th(:parse_mode)
        @test pm("skip – en") == ("skip", "en") || (println("NIT-2: ", pm("skip – en")); false)
        @test pm("refactor – rename internals") == ("refactor", "rename internals")
        @test pm("skip — a – b") == ("skip", "a – b")   # the first separator wins
    end
end
