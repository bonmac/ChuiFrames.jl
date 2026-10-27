# Critic C4, C7 and C8 (critic-030, factory 0.3.0). Written red; the implementer does not edit it.
# Included by runtests.jl after test_hooks_tdd.jl (tb_* hook helpers) and test_tdd.jl (th/th_testset/th_has,
# TW/IMPL/LEAD/OTHER of test_tdd_history.jl; th_lane/th_commit!/th_rec/th_ledger!/er/th_red_ev!/th_green_ev!/
# th_lane_recs of test_tdd_history2.jl); uses ROOT, sh and tmp_repo of runtests.jl.
#
# Lead's rulings (the behaviour specified here):
# C4 commit in its own call
# - Every role body (test_writer, implementer, law_tester, property_tester, differential_tester) and the
#   lane-lifecycle skill say to run `git commit` in its own Bash call, never chained (one line with
#   "own Bash call" and "chain" or "never").
# - The skill names the lead's recovery for a cancelled commit call, in one paragraph: while the commit is
#   HEAD, amend it through the hooks; otherwise reset the lane to before the commit and re-dispatch, or
#   attest it with the E5 waiver `TDD-Waiver: E5`.
# C4 E5 lead waiver
# - A lane commit authored exactly `lead <lead@factory.invalid>` with the git trailer
#   `TDD-Waiver: E5 <sha> <sep> <reason>` (sep ` — `, ` - ` or ` -- `, as for TDD-Mode; <sha> full or a
#   prefix of at least 7 hex characters) makes a role commit whose ONLY ledger record is `tdd-commit-late`
#   pass E5. It does not apply when: the waiver is authored by anyone else; the reason is empty; the sha
#   has no record at all; the waiver commit is outside base..HEAD; the prefix is shorter than 7 or matches
#   another sha. It never hides a `tdd-commit-violation` for that sha, and covers only the sha it names.
# - Hooks: a role caller's git commit carrying a `TDD-Waiver:` trailer is denied at Pre with rule
#   `waiver-trailer` (interface choice of this file, like `mode-trailer`); the lead (no agent_type)
#   committing it as `lead <lead@factory.invalid>` is allowed.
# C7 named blind spots, in .agents/checks.toml (`blind_spots`) and the rendered docs/CHECK_COVERAGE.md:
# - row `tdd`: merge commits are invisible to H1/H3/H4 (`lane_commits` uses --no-merges; only the
#   reviewer's `git show --cc` sees a merge resolution's edits);
# - row `tdd_boundary`: a git alias (e.g. `git ci`) bypasses the commit guard;
# - one of the rows tdd/tdd_boundary/tdd_commit_post: E5 (tdd.jl audit) catches alias commits by role
#   identities but dod does not.
#   NB: test_hooks_tdd.jl pins the tdd row at 9 blind spots and the tdd_boundary list exactly; those pins
#   must move with these new entries.
# C8: test_writer.md rule 1 cites the API through `tdd.jl api` (a docstring as `tdd.jl api` prints it), not
#   docstrings read in src/, and says that on Julia 1.10 api prints NOT RUN.
import TOML

const C4_ROOT = dirname(rstrip(SCRIPTS, '/'))   # factory/template
const C4_BODIES = ("test_writer", "implementer", "law_tester", "property_tester", "differential_tester")
const C4_SKILL = joinpath(C4_ROOT, ".claude", "skills", "lane-lifecycle", "SKILL.md")
c4_read(p) = isfile(p) ? read(p, String) : ""
"Blocks of `text` separated by blank lines or headings, each joined into one whitespace-collapsed string."
function c4_blocks(text)
    out, cur = String[], String[]
    flush() = (isempty(cur) || push!(out, replace(join(cur, ' '), r"\s+" => " ")); empty!(cur))
    for l in split(text, '\n')
        (isempty(strip(l)) || startswith(l, "#")) && (flush(); continue)
        push!(cur, l)
    end
    flush()
    return out
end
"Does `text` have a line saying to commit in its own Bash call, never chained?"
c4_own_call(text) = any(l -> occursin(r"own Bash call"i, l) && occursin(r"chain|never"i, l), split(text, '\n'))

# ---- C4: the bodies and the skill ----
@testset "critic C4: git commit in its own Bash call (bodies, skill)" begin
    for b in C4_BODIES
        @testset "body $b says: commit in its own Bash call, never chained" begin
            p = joinpath(C4_ROOT, ".agents", "bodies", "$b.md")
            @test isfile(p)
            @test c4_own_call(c4_read(p)) || (println("C4: no own-Bash-call line in $b.md"); false)
        end
    end
    @testset "lane-lifecycle skill says: commit in its own Bash call, never chained" begin
        @test isfile(C4_SKILL)
        @test c4_own_call(c4_read(C4_SKILL)) || (println("C4: no own-Bash-call line in the skill"); false)
    end
    @testset "lane-lifecycle skill names the lead's recovery for a cancelled commit call" begin
        bs = filter(b -> occursin(r"cancel"i, b) && occursin(r"commit"i, b), c4_blocks(c4_read(C4_SKILL)))
        @test !isempty(bs) || (println("C4: no cancelled-commit paragraph in the skill"); false)
        hit = filter(b -> occursin(r"amend"i, b) && occursin("HEAD", b) && occursin(r"\breset"i, b) &&
            occursin(r"re-dispatch"i, b) && occursin("TDD-Waiver: E5", b), bs)
        @test !isempty(hit) || (println("C4: the cancelled-commit paragraph lacks amend/HEAD/reset/re-dispatch/TDD-Waiver: E5"); false)
    end
end

# ---- C4: the E5 lead waiver, on real repos with ledger fixtures ----
"The E5 lines of `v` that name `sha` (its sha7 right after the rule id, or a violation for it)."
c4_e5(v, sha) = filter(s -> startswith(s, "E5") && occursin(first(sha, 7), s), v)
"""
A complete lane (stub, red, green, with passing evidence) whose `late` phases (:red, :green, :stub) have only
a `tdd-commit-late` record, `none` phases no record at all, then one waiver commit by `who` with message
`msg(c)`. Returns (d, c, recs, waiver sha).
"""
function c4_lane(msg; who = LEAD, late = (:red,), none = (), extra = String[])
    d, c = th_lane()
    th_red_ev!(d, c.red)
    th_green_ev!(d, c.green)
    recs = String[]
    for (ph, ty) in ((:stub, "implementer"), (:red, "test-writer"), (:green, "implementer"))
        s = getfield(c, ph)
        ph in none && continue
        push!(recs, th_rec(ph in late ? "tdd-commit-late" : "tdd-commit", ty, d, s))
    end
    w = msg === nothing ? nothing : th_commit!(d, who, Dict{String, String}(), msg(c))
    # a role-authored waiver commit gets its own record, so only the waived sha's E5 is under test
    who in (TW, IMPL) && w !== nothing && push!(recs, th_rec("tdd-commit", first(split(who, ' ')), d, w))
    return d, c, [recs; extra], w
end
c4_msg(sha, rest) = "chore: waive E5\n\nTDD-Waiver: E5 $sha$rest"

@testset "critic C4: E5 lead waiver (evidence_rules, audit)" begin
    E = (:lane_commits, :evidence_rules)

    th_testset("controls: a late-only red record fails E5 without a waiver; a complete lane passes", E...) do
        d, c, recs, _ = c4_lane(nothing)
        @test !isempty(c4_e5(er(d, recs), c.red))
        d2, c2 = th_lane()
        th_red_ev!(d2, c2.red); th_green_ev!(d2, c2.green)
        @test !th_has(er(d2, th_lane_recs(d2, c2)), "E5")
    end

    th_testset("a lead waiver for a late-only record clears E5 (full sha, em dash)", E...) do
        d, c, recs, _ = c4_lane(c -> c4_msg(c.red, " — Esc during the red run; diff reviewed by the lead"))
        v = er(d, recs)
        @test isempty(c4_e5(v, c.red)) || (println("C4 waiver not honoured: ", v); false)
        @test !th_has(v, "E5")
    end

    th_testset("waiver separators - and --, and a sha prefix of 7 or 10 characters", E...) do
        for (n, sep) in ((7, " - "), (10, " -- "), (40, " - "), (7, " — "))
            d, c, recs, _ = c4_lane(c -> c4_msg(first(c.red, n), "$(sep)cancelled commit call"))
            v = er(d, recs)
            @test isempty(c4_e5(v, c.red)) || (println("C4 waiver ($n, $(repr(sep))) not honoured: ", v); false)
        end
    end

    th_testset("a late-only green waived on top of later commits (no rewrite needed)", E...) do
        d, c, recs, _ = c4_lane(c -> c4_msg(c.green, " — cancelled during green"); late = (:green,))
        @test isempty(c4_e5(er(d, recs), c.green))
    end

    th_testset("the same waiver authored by a non-lead or a role does not clear E5", E...) do
        for who in (OTHER, TW, IMPL)
            d, c, recs, _ = c4_lane(c -> c4_msg(c.red, " — cancelled"); who)
            @test !isempty(c4_e5(er(d, recs), c.red)) || (println("C4 waiver by $who honoured"); false)
        end
    end

    th_testset("a waiver with no reason does not clear E5", E...) do
        for rest in ("", " —", " -", " --", " — ")
            d, c, recs, _ = c4_lane(c -> c4_msg(c.red, rest))
            @test !isempty(c4_e5(er(d, recs), c.red)) || (println("C4 reason-less waiver $(repr(rest)) honoured"); false)
        end
    end

    th_testset("a waiver for a sha with no record at all does not clear E5", E...) do
        d, c, recs, _ = c4_lane(c -> c4_msg(c.red, " — cancelled"); late = (), none = (:red,))
        @test !isempty(c4_e5(er(d, recs), c.red))
    end

    th_testset("a waiver never hides a tdd-commit-violation for that sha", E...) do
        d, c, recs, _ = c4_lane(c -> c4_msg(c.red, " — cancelled"))
        recs = [recs; th_rec("tdd-commit-violation", "test-writer", d, c.red)]
        @test !isempty(c4_e5(er(d, recs), c.red))
        d2, c2, recs2, _ = c4_lane(c -> c4_msg(c.red, " — cancelled"); late = ())   # a normal record plus a violation
        recs2 = [recs2; th_rec("tdd-commit-violation", "test-writer", d2, c2.red)]
        @test !isempty(c4_e5(er(d2, recs2), c2.red))
    end

    th_testset("a waiver for one sha does not cover another", E...) do
        d, c, recs, _ = c4_lane(c -> c4_msg(c.red, " — cancelled"); late = (:red, :green))
        v = er(d, recs)
        @test isempty(c4_e5(v, c.red)) || (println("C4 red not waived: ", v); false)
        @test !isempty(c4_e5(v, c.green))
    end

    th_testset("a 6-character prefix or a wrong sha does not clear E5", E...) do
        d, c, recs, _ = c4_lane(c -> c4_msg(first(c.red, 6), " — cancelled"))
        @test !isempty(c4_e5(er(d, recs), c.red))
        d2, c2, recs2, _ = c4_lane(c -> c4_msg(c.stub, " — cancelled"))   # names the stub, not the late red
        @test !isempty(c4_e5(er(d2, recs2), c2.red))
    end

    th_testset("a lead waiver outside base..HEAD (on main) does not clear E5", E...) do
        d, c, recs, _ = c4_lane(nothing)
        sh(`git -C $d checkout -q main`)
        th_commit!(d, LEAD, Dict{String, String}(), c4_msg(c.red, " — cancelled"))
        sh(`git -C $d checkout -q lane`)
        @test !isempty(c4_e5(er(d, recs), c.red))
    end

    th_testset("tdd.jl audit: a waived late-only commit prints no E5 line", :audit) do
        d, c, recs, _ = c4_lane(c -> c4_msg(c.red, " — Esc during red; reviewed"))
        io = IOBuffer()
        th(:audit)(d; base = "main", ledger = th_ledger!(tempname() * ".jsonl", recs), io)
        out = String(take!(io))
        @test !occursin(r"^E5"m, out) || (println("C4 audit:\n", out); false)
    end
end

# ---- C4: the hooks ----
@testset "critic C4: TDD-Waiver trailer at the commit guard" begin
    t = tb_topo(); L = t.lane
    w = "TDD-Waiver: E5 $(tb_head(L)) — cancelled"
    deny_rule(r) = r.rc == 2 && occursin("§0.5", r.err) && occursin("(waiver-trailer)", r.err)
    @testset "a test-writer commit with a TDD-Waiver trailer is denied (waiver-trailer)" begin
        for extra in (" --trailer \"$w\"", " -m \"$w\"")
            r = tb_run(t, tb_bash("git -C $L commit -q -m \"test: x\" --trailer \"TDD: red\"$extra --author \"$TB_TW\""; cwd = L))
            @test deny_rule(r) || (println("C4 tw waiver not denied (rc $(r.rc)): ", r.err); false)
        end
    end
    @testset "an implementer commit with a TDD-Waiver trailer is denied (waiver-trailer)" begin
        r = tb_run(t, tb_bash("git -C $L commit -q -m \"feat: x\" --trailer \"TDD: green\" --trailer \"$w\" --author \"$TB_IMPL\"";
            agent = "implementer", cwd = L))
        @test deny_rule(r) || (println("C4 impl waiver not denied (rc $(r.rc)): ", r.err); false)
    end
    @testset "the lead's waiver commit as lead <lead@factory.invalid> is allowed and clean" begin
        f = tb_flow(t, "git -C $L commit -q --allow-empty -m \"chore: waive E5\" --trailer \"$w\" --author \"$TB_LEAD\""; agent = nothing)
        @test f.pre.rc == 0 && f.ran && f.post !== nothing && f.post.rc == 0
        @test readchomp(`git -C $L log -1 --format=%an`) == "lead"
    end
end

# ---- C7: named blind spots ----
"The checks.toml rows by id."
c4_rows() = Dict(r["id"] => r for r in TOML.parsefile(joinpath(C4_ROOT, ".agents", "checks.toml"))["checks"])
c4_spots(rows, id) = String[get(get(rows, id, Dict()), "blind_spots", String[])...]
"The CHECK_COVERAGE.md table line of the row whose prevented_by is `pb`."
function c4_md_line(pb)
    ls = split(c4_read(joinpath(C4_ROOT, "docs", "CHECK_COVERAGE.md")), '\n')
    i = findfirst(l -> occursin("| `$pb` |", l), ls)
    return i === nothing ? "" : String(ls[i])
end
md_has(line, s) = occursin(replace(s, "|" => "\\|"), line)
const C4_PB = Dict("tdd" => "scripts/tdd.jl", "tdd_boundary" => ".claude/hooks/tdd_boundary.sh",
    "tdd_commit_post" => ".claude/hooks/tdd_commit_post.sh")

@testset "critic C7: blind spots named in checks.toml and CHECK_COVERAGE.md" begin
    rows = c4_rows()
    @testset "tdd: merge commits invisible to H1/H3/H4 (--no-merges); only git show --cc sees them" begin
        hit = filter(s -> occursin(r"merge"i, s) && occursin("--no-merges", s) && occursin("H1", s) && occursin("H3", s) &&
            occursin("H4", s) && occursin("git show --cc", s), c4_spots(rows, "tdd"))
        @test !isempty(hit) || (println("C7: no merge blind spot in the tdd row"); false)
        isempty(hit) || @test md_has(c4_md_line(C4_PB["tdd"]), first(hit))
    end
    @testset "tdd_boundary: a git alias (git ci) bypasses the commit guard" begin
        hit = filter(s -> occursin(r"alias"i, s) && occursin("git ci", s) && occursin(r"commit guard"i, s), c4_spots(rows, "tdd_boundary"))
        @test !isempty(hit) || (println("C7: no `git ci` alias blind spot in the tdd_boundary row"); false)
        isempty(hit) || @test md_has(c4_md_line(C4_PB["tdd_boundary"]), first(hit))
    end
    @testset "E5 (tdd.jl audit) catches alias commits by role identities; dod does not" begin
        hits = [(id, s) for id in keys(C4_PB) for s in c4_spots(rows, id) if occursin(r"alias"i, s) && occursin("E5", s) &&
            occursin(r"\bdod\b", s) && occursin(r"role"i, s)]
        @test !isempty(hits) || (println("C7: no alias/E5/dod blind spot"); false)
        isempty(hits) || @test md_has(c4_md_line(C4_PB[first(hits)[1]]), first(hits)[2])
    end
end

# ---- C8: test-writer rule 1 cites the API through tdd.jl api ----
"Rule 1 of test_writer.md: from the line starting `1. ` to the next top-level numbered rule."
function c4_rule1()
    ls = split(c4_read(joinpath(C4_ROOT, ".agents", "bodies", "test_writer.md")), '\n')
    i = findfirst(l -> startswith(l, "1. "), ls)
    i === nothing && return ""
    j = something(findnext(l -> occursin(r"^[0-9]+\. ", l), ls, i + 1), length(ls) + 1) - 1
    return join(ls[i:j], '\n')
end

@testset "critic C8: test-writer rule 1 cites the API as tdd.jl api prints it" begin
    r1 = c4_rule1()
    @test !isempty(r1)
    @test occursin("tdd.jl api", r1) || (println("C8: rule 1 has no tdd.jl api:\n", r1); false)
    @test occursin(r"1\.10", r1) && occursin("NOT RUN", r1)
    # every "docstring" in rule 1 is tied to tdd.jl api (within 100 characters), never a bare "a docstring"
    for m in eachmatch(r"docstring", r1)
        lo, hi = max(1, m.offset - 100), min(ncodeunits(r1), m.offset + 100)
        win = r1[thisind(r1, lo):thisind(r1, hi)]
        @test occursin("tdd.jl api", win) || (println("C8: a docstring not tied to tdd.jl api near: ", win); false)
    end
end
