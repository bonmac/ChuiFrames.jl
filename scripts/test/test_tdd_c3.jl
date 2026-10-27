# Critic C3 and C6 (factory 0.3.0, critic-030). Written red; the implementer does not edit it.
# Included by runtests.jl after test_tdd.jl (Tdd via th/th_testset/th_has, lc/hr, TW/IMPL/LEAD/OTHER of
# test_tdd_history.jl) and test_dod.jl (DoD); uses tmp_repo/sh/capture of runtests.jl.
#
# Lead's rulings (the behaviour specified here):
# C3
# - The `TDD-Mode: skip <sep> <reason>` separator accepts ` — ` (em dash), ` - ` and ` -- `. A lead-authored
#   `skip - format fix` or `skip -- format fix` is mode skip with that reason (no H8); `skip` and `skip -` with
#   no reason still fail H8; a hyphenated word in the reason keeps the whole reason.
# - factory/CHANGELOG.md's 0.3.0 migration list names: the exact lead skip commit command (one line with
#   `--author "lead <lead@factory.invalid>"` and `--trailer "TDD-Mode: skip — `); that non-TDD code lanes
#   (format, perf, release fixes, sub-lead work) need it once `tdd` is in a tier; that TDD dispatches and mode
#   commits are the lead's, a sub-lead (it has an agent_type) can do neither; that in-flight branches take the
#   skip commit before main is merged into them.
# - The lane-lifecycle skill tells a sub-lead to ask the lead for the TDD dispatch and the mode commit.
# C6 (option a)
# - The H rules evaluate the mode per merged sub-lane: for each `--no-ff` merge M on the first-parent chain of
#   base..head, `M^1..M^2` is its own segment with its own mode; the commits made directly on the integration
#   branch form one segment governed only by that branch's own mode commit.
#
# Assumptions: `parse_mode(value) -> (mode, reason)` stays Tdd's name for the trailer-value parser (it is today);
# `audit(root; base, io)` prints H lines starting with their rule id and the failing commit's sha7, as today.
# The real-repo tests filter audit output to `^H[0-9]` lines (the E rules lack evidence and ledgers here), and
# read only dod's `tdd` row.

# ---- C3: the skip separator, parse level ----
@testset "critic C3 skip separator: parse_mode" begin
    th_testset("parse_mode accepts em dash, - and -- as the reason separator", :parse_mode) do
        pm = th(:parse_mode)
        for v in ("skip — format fix", "skip - format fix", "skip -- format fix")
            @test pm(v) == ("skip", "format fix") || (println("C3 parse_mode($(repr(v))) = ", pm(v)); false)
        end
        @test pm("refactor -- rename internals") == ("refactor", "rename internals")
        @test pm("refactor - rename internals") == ("refactor", "rename internals")
        @test pm("required") == ("required", "")
    end
    th_testset("parse_mode: no reason after the separator is an empty reason", :parse_mode) do
        pm = th(:parse_mode)
        @test pm("skip") == ("skip", "")
        for v in ("skip -", "skip --", "skip —")
            m, r = pm(v)
            @test isempty(r) || (println("C3 parse_mode($(repr(v))) = ", (m, r)); false)
        end
    end
    th_testset("parse_mode keeps hyphenated words and later separators inside the reason", :parse_mode) do
        pm = th(:parse_mode)
        @test pm("skip — re-run x") == ("skip", "re-run x")
        @test pm("skip - re-run x") == ("skip", "re-run x")
        @test pm("skip -- re-run x - twice") == ("skip", "re-run x - twice")
        @test pm("skip - format fix — and a perf fix") == ("skip", "format fix — and a perf fix")
    end
end

# ---- C3: the skip separator through lane_mode and history_rules ----
@testset "critic C3 skip separator: lane_mode and history_rules" begin
    H = (:LaneCommit, :history_rules, :lane_mode, :parse_mode)
    mc(who, v) = lc(who, nothing; mode = th(:parse_mode)(v))
    code() = lc(OTHER, nothing, "src/A.jl")   # a non-TDD code change (format fix)

    th_testset("lead skip with -, -- or em dash: mode skip, no H rule fails", H...) do
        for v in ("skip — format fix", "skip - format fix", "skip -- format fix")
            cs = [mc(LEAD, v), code()]
            @test th(:lane_mode)(cs) == ("skip", String[]) || (println("C3 lane_mode $(repr(v)): ", th(:lane_mode)(cs)); false)
            r = hr(cs...)
            @test isempty(r) || (println("C3 hr $(repr(v)): ", r); false)
        end
    end
    th_testset("skip with no reason (bare, or a separator only) still fails H8", H...) do
        for v in ("skip", "skip -", "skip --", "skip —")
            r = hr(mc(LEAD, v), code())
            @test th_has(r, "H8") || (println("C3 no H8 for $(repr(v)): ", r); false)
        end
    end
    th_testset("skip - reason by a non-lead is still refused (H8)", H...) do
        for who in (OTHER, TW, IMPL)
            @test th_has(hr(mc(who, "skip - format fix"), code()), "H8")
        end
    end
end

# ---- real git repos ----
"Write `files`, stage everything, commit as `author` with the trailers; the new full sha."
function c3_commit!(d, author, files::Dict, subject; trailers = String[])
    for (rel, c) in files
        mkpath(dirname(joinpath(d, rel)))
        write(joinpath(d, rel), c)
    end
    sh(`git -C $d add -A -- .`)
    tr = reduce(vcat, [["--trailer", t] for t in trailers]; init = String[])
    sh(`git -C $d commit -q --allow-empty --author=$author -m $subject $tr`)
    return readchomp(`git -C $d rev-parse HEAD`)
end
"A repo whose main has the template risk.toml and src/P.jl, checked out on branch `int`."
function c3_repo()
    d = tmp_repo(
        Dict(
            ".gitignore" => "/.lanes/\n/.worktrees/\n", "src/P.jl" => "module P\nf(x) = x\nend\n",
            "risk.toml" => seed_fixture("risk.toml"), "Project.toml" => "name = \"P\"\n"
        )
    )
    sh(`git -C $d checkout -q -b int`)
    return d
end
"Run `body(d)` on a new branch `name` cut from `int`, then merge it into `int` with --no-ff."
function c3_sublane!(body, d, name)
    sh(`git -C $d checkout -q -b $name int`)
    out = body(d)
    sh(`git -C $d checkout -q int`)
    sh(`git -C $d merge -q --no-ff -m "merge $name" $name`)
    return out
end
"The H-rule lines tdd.jl audit prints for `d` (base main)."
function c3_hlines(d)
    io = IOBuffer()
    th(:audit)(d; base = "main", io)
    return [String(l) for l in split(String(take!(io)), '\n') if occursin(r"^H[0-9]", l)]
end
"dod's `tdd` row for `d` (base main, label T1) as (status, detail), or nothing."
function c3_dodtdd(d)
    _, out = capture(() -> DoD.main(["--root", d, "--base", "main", "--labels", "T1"]))
    m = match(r"\[(PASS|FAIL|info)\] tdd +(.*)", out)
    m === nothing && (print(out); return nothing)
    return (m.captures[1], m.captures[2])
end
C3_PSRC(n) = "module P\nf(x) = x\ng$n(x) = $n * x\nend\n"
c3_mode(v) = ["TDD-Mode: $v"]
"A refactor-mode sub-lane: lead mode commit, implementer refactor on src."
c3_refactor_lane(d) = (
    c3_commit!(d, LEAD, Dict{String, String}(), "chore: mode"; trailers = c3_mode("refactor — rename internals")),
    c3_commit!(d, IMPL, Dict("src/P.jl" => "module P\nf(y) = y\nend\n"), "refactor: rename"; trailers = ["TDD: refactor"]),
)
"A required-mode sub-lane: test-writer red, implementer green."
function c3_required_lane(d)
    r = c3_commit!(d, TW, Dict("test/g_tests.jl" => "@testitem \"g\" begin\n    @test true\nend\n"), "test: g"; trailers = ["TDD: red"])
    g = c3_commit!(d, IMPL, Dict("src/P.jl" => C3_PSRC(2)), "feat: g"; trailers = ["TDD: green"])
    return (; red = r, green = g)
end

@testset "critic C3 skip separator on a real branch (lane_commits, audit, dod)" begin
    th_testset("a lead `TDD-Mode: skip - format fix` commit passes audit's H rules and dod's tdd", :lane_commits, :audit) do
        for v in ("skip - format fix", "skip -- format fix")
            d = c3_repo()
            c3_commit!(d, LEAD, Dict{String, String}(), "chore: skip"; trailers = c3_mode(v))
            c3_commit!(d, OTHER, Dict("src/P.jl" => "module P\nf(x)=x\nend\n"), "style: format")
            cs = th(:lane_commits)(d, "main")
            @test cs[1].mode == ("skip", "format fix") || (println("C3 git mode $(repr(v)): ", cs[1].mode); false)
            h = c3_hlines(d)
            @test isempty(h) || (println("C3 audit $(repr(v)): ", h); false)
            row = c3_dodtdd(d)
            @test row !== nothing && row[1] == "PASS" || (println("C3 dod $(repr(v)): ", row); false)
        end
    end
    th_testset("a lead `TDD-Mode: skip -` with no reason fails H8 on a real branch", :audit) do
        d = c3_repo()
        c3_commit!(d, LEAD, Dict{String, String}(), "chore: skip"; trailers = c3_mode("skip -"))
        c3_commit!(d, OTHER, Dict("src/P.jl" => "module P\nf(x)=x\nend\n"), "style: format")
        @test th_has(c3_hlines(d), "H8")
    end
end

# ---- C3: the migration list and the skill ----
"The 0.3.0 entry's migration bullet of factory/CHANGELOG.md: from `**Migration` to the next top-level bullet."
function c3_migration()
    t = read(joinpath(FACTORY, "CHANGELOG.md"), String)
    ls = split(t, '\n')
    s = findfirst(l -> startswith(l, "## 0.3.0"), ls)
    s === nothing && return String[]
    e = something(findnext(l -> startswith(l, "## "), ls, s + 1), length(ls) + 1) - 1
    sec = ls[s:e]
    i = findfirst(l -> occursin("**Migration", l), sec)
    i === nothing && return String[]
    j = something(findnext(l -> startswith(l, "- **"), sec, i + 1), length(sec) + 1) - 1
    return String.(sec[i:j])
end
"Bullets and paragraphs of `lines`, each one joined into a single whitespace-collapsed string."
function c3_items(lines)
    items, cur = String[], String[]
    flush() = (isempty(cur) || push!(items, replace(join(cur, ' '), r"\s+" => " ")); empty!(cur))
    for l in lines
        (isempty(strip(l)) || occursin(r"^\s*(- |\d+\. )", l)) && flush()
        isempty(strip(l)) || push!(cur, l)
    end
    flush()
    return items
end

@testset "critic C3 migration list and lane-lifecycle skill" begin
    if !IN_FACTORY
        @test_skip "not inside factory/: no factory/CHANGELOG.md"
    else
        mig = c3_migration()
        items = c3_items(mig)
        @testset "the migration list names the exact lead skip commit command on one line" begin
            @test !isempty(mig)
            @test any(
                l -> occursin("--author \"lead <lead@factory.invalid>\"", l) &&
                    occursin("--trailer \"TDD-Mode: skip — ", l), mig
            ) || (println("C3: no one-line skip command in\n", join(mig, '\n')); false)
        end
        @testset "the migration list: non-TDD code lanes need the skip commit once tdd is in a tier" begin
            hit = filter(it -> occursin(r"non-TDD"i, it) && occursin(r"skip"i, it), items)
            @test !isempty(hit) || (println("C3: no non-TDD lanes item"); false)
            for w in (r"format"i, r"perf"i, r"release"i, r"sub-lead"i, r"\btdd\b.*\btier"i)
                @test any(it -> occursin(w, it), hit) || (println("C3: non-TDD item lacks $w"); false)
            end
        end
        @testset "the migration list: TDD dispatches and mode commits are the lead's, not a sub-lead's" begin
            hit = filter(it -> occursin("sub-lead", it) && occursin("agent_type", it), items)
            @test !isempty(hit) || (println("C3: no sub-lead/agent_type item"); false)
            @test any(it -> occursin(r"dispatch"i, it) && occursin(r"mode"i, it) && occursin(r"\blead\b|main session"i, it), hit)
        end
        @testset "the migration list: in-flight branches take the skip commit before merging main" begin
            @test any(it -> occursin(r"in-flight"i, it) && occursin(r"skip commit"i, it) && occursin(r"before merging main"i, it), items) ||
                (println("C3: no in-flight branch item"); false)
        end
    end
    @testset "lane-lifecycle: a sub-lead asks the lead for the TDD dispatch and the mode commit" begin
        sk = read(joinpath(ROOT, ".claude", "skills", "lane-lifecycle", "SKILL.md"), String)
        items = c3_items(split(sk, '\n'))
        @test any(
            it -> occursin(r"sub-lead"i, it) && occursin(r"\bask\w*\b.{0,20}\bthe lead\b"i, it) &&
                occursin(r"dispatch"i, it) && occursin(r"mode commit"i, it), items
        ) || (println("C3: no sub-lead line in the skill"); false)
    end
end

# ---- C6: per-merge segments ----
@testset "critic C6 per-merge mode segments (audit, dod)" begin
    A = (:audit, :lane_commits)

    th_testset("refactor sub-lane then required sub-lane: no H8, audit and dod pass", A...) do
        d = c3_repo()
        c3_sublane!(c3_refactor_lane, d, "a")
        c3_sublane!(c3_required_lane, d, "b")
        h = c3_hlines(d)
        @test !th_has(h, "H8") || (println("C6 H8: ", h); false)
        @test isempty(h) || (println("C6 H lines: ", h); false)
        row = c3_dodtdd(d)
        @test row !== nothing && row[1] == "PASS" || (println("C6 dod: ", row); false)
    end

    th_testset("required sub-lane then refactor sub-lane: order does not matter", A...) do
        d = c3_repo()
        c3_sublane!(c3_required_lane, d, "b")
        c3_sublane!(c3_refactor_lane, d, "a")
        h = c3_hlines(d)
        @test isempty(h) || (println("C6 H lines (reversed): ", h); false)
    end

    th_testset("a required sub-lane's green with no red is still reported, with its sha", A...) do
        d = c3_repo()
        c3_sublane!(c3_refactor_lane, d, "a")
        g = c3_sublane!(d, "c") do d
            c3_commit!(d, IMPL, Dict("src/P.jl" => C3_PSRC(3)), "feat: g3"; trailers = ["TDD: green"])
        end
        h = c3_hlines(d)
        @test th_has(h, "H2") || th_has(h, "H6") || (println("C6 no H2/H6: ", h); false)
        @test any(l -> occursin(r"^H6", l) && occursin(first(g, 7), l), h) || (println("C6 no H6 for $(first(g, 7)): ", h); false)
        @test !th_has(h, "H8") || (println("C6 H8: ", h); false)
        row = c3_dodtdd(d)
        @test row !== nothing && row[1] == "FAIL" && occursin(r"^H[26]", row[2]) || (println("C6 dod: ", row); false)
    end

    th_testset("a direct phase-less src commit on the integration branch is H1 despite a skip sub-lane", A...) do
        d = c3_repo()
        c3_sublane!(d, "s") do d
            c3_commit!(d, LEAD, Dict{String, String}(), "chore: skip"; trailers = c3_mode("skip — spike"))
            c3_commit!(d, OTHER, Dict("src/P.jl" => C3_PSRC(4)), "feat: spike")
        end
        x = c3_commit!(d, OTHER, Dict("src/P.jl" => C3_PSRC(5)), "fix: direct on int")
        h = c3_hlines(d)
        @test any(l -> occursin(r"^H1", l) && occursin(first(x, 7), l), h) || (println("C6 no H1 for $(first(x, 7)): ", h); false)
        @test !any(l -> occursin(r"^H8", l), h) || (println("C6 H8: ", h); false)
        row = c3_dodtdd(d)
        @test row !== nothing && row[1] == "FAIL" && startswith(row[2], "H1") || (println("C6 dod: ", row); false)
    end

    th_testset("the skip sub-lane alone passes: its own segment is skip", A...) do
        d = c3_repo()
        c3_sublane!(d, "s") do d
            c3_commit!(d, LEAD, Dict{String, String}(), "chore: skip"; trailers = c3_mode("skip — spike"))
            c3_commit!(d, OTHER, Dict("src/P.jl" => C3_PSRC(4)), "feat: spike")
        end
        @test isempty(c3_hlines(d))   # control: passes today and after
    end

    th_testset("an integration-branch skip covers its direct commits, not a merged sub-lane's violation", A...) do
        d = c3_repo()
        c3_commit!(d, LEAD, Dict{String, String}(), "chore: skip"; trailers = c3_mode("skip — release fix"))
        x = c3_commit!(d, OTHER, Dict("src/P.jl" => C3_PSRC(6)), "fix: release")
        g = c3_sublane!(d, "r") do d
            c3_commit!(d, IMPL, Dict("src/P.jl" => C3_PSRC(7)), "feat: g7"; trailers = ["TDD: green"])
        end
        h = c3_hlines(d)
        @test !any(l -> occursin(first(x, 7), l), h) || (println("C6 direct commit reported: ", h); false)
        @test any(l -> occursin(r"^H6", l) && occursin(first(g, 7), l), h) || (println("C6 sub-lane violation hidden: ", h); false)
        row = c3_dodtdd(d)
        @test row !== nothing && row[1] == "FAIL" || (println("C6 dod: ", row); false)
    end
end
