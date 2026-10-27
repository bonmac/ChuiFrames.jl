# Part 3 of the tdd_boundary tests (factory 0.3.0, review round 1: B1-B3, M1, M2, minors 5-7, nit 2).
# Included at the end of test_hooks_tdd2.jl; uses the helpers of test_hooks_tdd.jl and test_hooks_tdd2.jl
# (tb_topo, tb_run, tb_bash, tb_flow, tb_recs, tb_stage!, tb_cm, ...). Representation choices added here:
#
# - Pending-entry age is its mtime (B2 ruling), set with `touch -t` on everything under
#   .lanes/tdd-pending/<tool_use_id> (a file or a directory). An entry older than 11 minutes is stale.
# - A commit's place in an entry's window is its COMMITTER time, set with GIT_COMMITTER_DATE on a commit
#   made directly with git (no hooks). The window is [entry mtime - 5 s, entry mtime + 600 s].
# - The sweep writes only `tdd-commit-late {agent_id, agent_type, checkout, sha}`: never `tdd-commit`,
#   never `tdd-commit-violation`.
# - M1: the open-lane count is OPEN_LANES_JQ (.claude/hooks/_lanes.sh) over the session ledger, session s1,
#   TTL 24 h, as dispatch_limit.sh evaluates it. Both hooks run on the same payload, in both orders: the
#   harness runs them in parallel with no order.

"Unix time `secs` seconds ago."
tb_ago(secs) = floor(Int, time()) - secs
"Set the mtime of the pending entry `tu` (and anything under it) to `epoch`; false if there is no entry."
function tb_age!(t, tu, epoch)
    p = joinpath(t.S, ".lanes", "tdd-pending", tu)
    ispath(p) || return false
    sh(`find $p -exec touch -t $(Libc.strftime("%Y%m%d%H%M.%S", epoch)) '{}' '+'`)
    return true
end
"Commit `files` in `d` directly with git (no hooks) as `who`, author and committer time `epoch`; the sha."
function tb_commit_at!(d, who, files, epoch, msg...)
    tb_stage!(d, files)
    m = match(r"^(.*) <(.*)>$", who)
    ms = collect(Iterators.flatten(("-m", x) for x in msg))
    dt = "@$epoch +0000"
    sh(addenv(`git -C $d -c user.name=$(m[1]) -c user.email=$(m[2]) commit -q $ms`, "GIT_COMMITTER_DATE" => dt, "GIT_AUTHOR_DATE" => dt))
    return tb_head(d)
end
"The PostToolUse half of call `tu` (command `c`, caller `agent`), run alone."
tb_post(t, c, tu; agent = "test-writer", cwd = t.lane) = tb_run(t, tb_bash(c; agent, cwd, tu, event = "PostToolUse",
    extra = Dict("tool_response" => Dict("stdout" => "", "stderr" => ""))); name = "tdd_commit_post.sh")
tb_mentions(t, sha) = any(l -> occursin(sha, l), tb_ledger_lines(t))
"Open lanes of session s1 as dispatch_limit.sh counts them."
function tb_open_lanes(t)
    f = joinpath(t.S, ".lanes", "ledger.jsonl")
    isfile(f) || return 0
    q = ". \"\$1\"; jq -Rrn --arg s s1 --argjson ttl 86400 \"[inputs | fromjson? // empty | objects] | \$OPEN_LANES_JQ | .count\" \"\$2\""
    return parse(Int, readchomp(`sh -c $q _ $(joinpath(TB_HOOKS, "_lanes.sh")) $f`))
end

@testset "tdd hooks review round 1 (0.3.0)" begin
    twb(t, c) = tb_bash(c; cwd = t.lane)

    # ---- B1: brace expansion and ~ in a test-writer's Bash words ----
    @testset "B1 test-writer brace expansion into src denied" begin
        t = tb_topo(); L = t.lane
        @test isfile("$L/src/P.jl") && isfile("$L/test/t.jl")   # precondition
        for c in ("cat test/{..,.}/src/P.jl", "cat $L/test/{../src/P.jl,t.jl}", "head -n 5 test/{../src/P.jl,x}",
                "grep -n secret test/{../src,.}", "ls test/{..,.}/src", "cat test/t.jl}", "cat test/{t.jl}")
            @test tb_no(t, twb(t, c))
        end
        @test tb_no(t, twb(t, "cat ~/.claude/projects/-coord/abc.jsonl"))
        @test tb_no(t, twb(t, "ls ~"))
        for c in ("cat test/t.jl", "head -n 5 test/t.jl", "grep -n f test/t.jl", "ls test")
            @test tb_ok(t, twb(t, c))
        end
    end
    @testset "B1 test-writer brace expansion through git diff and git add denied" begin
        t = tb_topo(); L = t.lane
        for c in ("git diff -- test/{../src,x}", "git -C $L diff -- test/{../src/P.jl,t.jl}", "git add test/{../src/P.jl,t.jl}")
            @test tb_no(t, twb(t, c))
        end
        @test tb_ok(t, twb(t, "git diff -- test/t.jl"))
        @test tb_ok(t, twb(t, "git add test/t.jl"))
    end

    # ---- B2: pending entries are bounded to their call ----
    @testset "B2 never-run lead entry does not misattribute the implementer's commit" begin
        t = tb_topo(); L = t.lane
        T = tb_ago(20 * 60)
        lc, tl = "git -C $L commit -q -m lead3", tb_tu()
        @test tb_run(t, tb_bash(lc; agent = nothing, cwd = L, tu = tl)).rc == 0   # allowed, then never run (bash_guard denied it)
        tb_stage!(L, Dict("src/P.jl" => "module P\nf(x) = 2x\nend\n"))
        ic, ti = tb_cm(L; author = TB_IMPL, phase = "green"), tb_tu()
        @test tb_run(t, tb_bash(ic; agent = "implementer", cwd = L, tu = ti)).rc == 0
        sha = tb_commit_at!(L, TB_IMPL, Dict{String, String}(), T + 30, "feat: f doubles", "TDD: green")
        @test tb_age!(t, tl, T) && tb_age!(t, ti, T + 25)
        post = tb_post(t, ic, ti; agent = "implementer")
        @test tb_ok(t, tb_bash("ls"; agent = nothing, cwd = L))   # a later call sweeps the lead's entry
        @test isempty(tb_recs(t, "tdd-commit-violation"))
        @test !occursin("violation", post.err)
        @test any(r -> get(r, "sha", "") == sha && get(r, "agent_type", "") == "implementer", tb_recs(t, "tdd-commit"))
        @test !any(r -> get(r, "sha", "") == sha && get(r, "agent_type", "") != "implementer", tb_recs(t, "tdd-commit"))
        @test !ispath(joinpath(t.S, ".lanes", "tdd-pending", tl))
    end
    @testset "B2 cancelled test-writer entry then a lead commit: no violation" begin
        t = tb_topo(); L = t.lane
        T = tb_ago(20 * 60)
        tw = tb_tu()
        tb_stage!(L, Dict("test/t2.jl" => "x\n"))
        @test tb_run(t, tb_bash(tb_cm(L); cwd = L, tu = tw)).rc == 0   # cancelled: no commit, no post
        tb_git(L, "reset", "-q")
        lc, tl = "git -C $L commit -q -m lead2", tb_tu()
        @test tb_run(t, tb_bash(lc; agent = nothing, cwd = L, tu = tl)).rc == 0
        sha = tb_commit_at!(L, "test <t@example.com>", Dict("docs/n.md" => "n\n"), T + 120, "docs: n")
        @test tb_age!(t, tw, T) && tb_age!(t, tl, T + 118)
        tb_post(t, lc, tl; agent = nothing)
        @test tb_ok(t, tb_bash("ls"; agent = nothing, cwd = L))
        @test isempty(tb_recs(t, "tdd-commit-violation"))
        @test !any(r -> get(r, "sha", "") == sha && get(r, "agent_type", "") == "test-writer", tb_recs(t, "tdd-commit"))
        @test !ispath(joinpath(t.S, ".lanes", "tdd-pending", tw))
    end
    @testset "B2 forged commit in a stale test-writer window gets no tdd-commit; audit E5 fails it" begin
        t = tb_topo(); L = t.lane
        T = tb_ago(20 * 60)
        tw = tb_tu()
        @test tb_run(t, tb_bash(tb_cm(L); cwd = L, tu = tw)).rc == 0   # a test-writer call that never ran
        @test tb_age!(t, tw, T)
        sha = tb_commit_at!(L, TB_TW, Dict("test/y_tests.jl" => "@testitem \"y\" begin\n    @test false\nend\n"), T + 60, "forged", "TDD: red")
        @test tb_ok(t, tb_bash("ls"; agent = nothing, cwd = L))   # the sweep
        @test !any(r -> get(r, "sha", "") == sha, tb_recs(t, "tdd-commit"))
        @test isempty(tb_recs(t, "tdd-commit-violation"))
        out = read(pipeline(ignorestatus(`$JULIA $(joinpath(SCRIPTS, "tdd.jl")) audit --root $L --base main`); stderr = devnull), String)
        e5 = filter(l -> startswith(l, "E5 $(first(sha, 7))"), split(out, '\n'))
        @test !isempty(e5)
        @test any(l -> occursin("late", l), e5)
    end
    @testset "B2 sweep records only in-window commits, as tdd-commit-late" begin
        t = tb_topo(); L = t.lane
        T = tb_ago(20 * 60)
        tw = tb_tu()
        @test tb_run(t, tb_bash(tb_cm(L); cwd = L, tu = tw)).rc == 0
        @test tb_age!(t, tw, T)
        early = tb_commit_at!(L, TB_TW, Dict("test/a.jl" => "a\n"), T - 100, "test: a", "TDD: red")
        inwin = tb_commit_at!(L, TB_TW, Dict("test/b.jl" => "b\n"), T + 60, "test: b", "TDD: red")
        late = tb_commit_at!(L, TB_TW, Dict("test/c.jl" => "c\n"), T + 700, "test: c", "TDD: red")
        @test tb_ok(t, tb_bash("ls"; agent = nothing, cwd = L))
        @test !tb_mentions(t, early) && !tb_mentions(t, late)
        lr = tb_recs(t, "tdd-commit-late")
        @test any(r -> get(r, "sha", "") == inwin && get(r, "agent_type", "") == "test-writer" &&
            haskey(r, "agent_id") && tb_canon(get(r, "checkout", "")) == tb_canon(L), lr)
        @test isempty(tb_recs(t, "tdd-commit")) && isempty(tb_recs(t, "tdd-commit-violation"))
        @test !ispath(joinpath(t.S, ".lanes", "tdd-pending", tw))
    end
    @testset "B2 an entry is stale after 11 minutes" begin
        t = tb_topo(); L = t.lane
        a, b = tb_tu(), tb_tu()
        @test tb_run(t, tb_bash(tb_cm(L); cwd = L, tu = a)).rc == 0
        @test tb_run(t, tb_bash(tb_cm(L); cwd = L, tu = b)).rc == 0
        @test tb_age!(t, a, tb_ago(12 * 60)) && tb_age!(t, b, tb_ago(10 * 60))
        @test tb_ok(t, tb_bash("ls"; agent = nothing, cwd = L))
        @test !ispath(joinpath(t.S, ".lanes", "tdd-pending", a))   # 12 min: swept
        @test ispath(joinpath(t.S, ".lanes", "tdd-pending", b))    # 10 min: kept
    end
    @testset "B2 post hook ignores a commit outside its call's window" begin
        t = tb_topo(); L = t.lane
        c, tu = tb_cm(L), tb_tu()
        @test tb_run(t, tb_bash(c; cwd = L, tu)).rc == 0
        old = tb_commit_at!(L, TB_TW, Dict("test/o.jl" => "o\n"), tb_ago(3600), "test: o", "TDD: red")
        tb_post(t, c, tu)
        @test !any(r -> get(r, "sha", "") == old, tb_recs(t, "tdd-commit"))
        tb_write!(L, Dict("test/n.jl" => "n\n"))
        f = tb_flow(t, "git -C $L add test/n.jl && " * tb_cm(L))   # control: a commit the call makes now
        @test f.pre.rc == 0 && f.ran
        @test any(r -> get(r, "sha", "") == tb_head(L) && get(r, "agent_type", "") == "test-writer", tb_recs(t, "tdd-commit"))
    end

    # ---- B3: first parent only ----
    @testset "B3 lead merge commit of main records only the merge" begin
        t = tb_topo(); L, P = t.lane, t.pkg
        rs = tb_commit_at!(P, TB_TW, Dict("test/m_tests.jl" => "@testitem \"m\" begin end\n"), tb_ago(60), "test: m", "TDD: red")
        gs = tb_commit_at!(P, TB_IMPL, Dict("src/m.jl" => "m() = 1\n"), tb_ago(30), "feat: m", "TDD: green")
        tb_git(L, "merge", "-q", "--no-ff", "--no-commit", "main")
        f = tb_flow(t, "git -C $L commit -q -m merge-main"; agent = nothing)
        ms = tb_head(L)
        @test f.pre.rc == 0 && f.ran && ms != gs
        @test isempty(tb_recs(t, "tdd-commit-violation"))
        @test all(r -> get(r, "sha", "") == ms, tb_recs(t, "tdd-commit"))
        @test !tb_mentions(t, rs) && !tb_mentions(t, gs)
    end

    # ---- M1: a dispatch tdd_boundary denies is not an open lane ----
    tb_disp3(L, head; lane = "lane1") = tb_pay("Agent", Dict{String, Any}("subagent_type" => "test-writer", "description" => "tw",
        "prompt" => "<!-- tdd-brief role=test-writer lane=$lane checkout=$L head=$head -->\n## Task\n$(tb_tu())\n"); cwd = "/")
    both(t, p, order) = [tb_run(t, p; name = n) for n in order]
    for order in (("dispatch_limit.sh", "tdd_boundary.sh"), ("tdd_boundary.sh", "dispatch_limit.sh"))
        @testset "M1 denied tdd dispatch leaves no open lane ($(order[1]) first)" begin
            t = tb_topo(); L = t.lane
            old = tb_head(L)
            tb_commit_as!(L, TB_TW, Dict("test/t2.jl" => "x\n"), "test: t2", "TDD: red")
            for _ in 1:3
                p = tb_disp3(L, old)   # stale head=
                @test any(r -> r.rc == 2, both(t, p, order))
            end
            @test tb_open_lanes(t) == 0
            r = both(t, tb_disp3(L, tb_head(L)), order)   # a valid dispatch still counts
            @test all(x -> x.rc == 0, r)
            @test tb_open_lanes(t) == 1
        end
    end

    # ---- M2: a planted .git does not move the checkout root ----
    @testset "M2 test-writer Write of a .git path denied" begin
        t = tb_topo(); L = t.lane
        @test tb_no(t, tb_write("$L/test/.git"))
        @test tb_no(t, tb_write("$L/test/sub/.git/config"; tool = "Edit"))
        @test tb_no(t, tb_write("$L/test/.git"; agent = "implementer"))
        @test tb_ok(t, tb_write("$L/test/x_tests.jl"))
    end
    @testset "M2 planted test/.git file does not move the checkout root" begin
        for content in ("", "gitdir: /nonexistent/.git/worktrees/x\n")
            t = tb_topo(); L = t.lane
            tb_write!(L, Dict("test/.git" => content, "test/scripts/tdd.jl" => "print(read(\"../src/P.jl\", String))\n"))
            @test tb_no(t, tb_write("$L/test/x_tests.jl"; agent = "implementer"))
            @test tb_no(t, tb_bash("echo y > test/x_tests.jl"; agent = "implementer", cwd = L))
            @test tb_no(t, twb(t, "julia test/scripts/tdd.jl red"))
            @test tb_ok(t, twb(t, "julia scripts/tdd.jl red"))
            @test tb_ok(t, tb_write("$L/src/P.jl"; tool = "Edit", agent = "implementer"))
        end
    end

    # ---- minors ----
    @testset "Minor 5 test-writer commit message file outside the read allowlist denied" begin
        t = tb_topo(); L = t.lane
        tb_write!(L, Dict("test/msg.txt" => "test: x\n\nTDD: red\n"))
        tb_stage!(L, Dict("test/t2.jl" => "x\n"))
        cm(o) = "git -C $L commit -q --author \"$TB_TW\" $o"
        for o in ("-F src/P.jl", "-Fsrc/P.jl", "--file=src/P.jl", "--file src/P.jl", "-t src/P.jl", "--template=src/P.jl",
                "-F $(t.home)/.claude/projects/-coord/abc.jsonl")
            @test tb_run(t, twb(t, cm(o))).rc == 2   # §0.5 or §0.6: either section may own it
        end
        @test tb_ok(t, twb(t, cm("-F -")))
        @test tb_ok(t, twb(t, cm("-F test/msg.txt")))
    end
    @testset "Minor 6 lead echo mentioning git commit allowed" begin
        t = tb_topo(); L = t.lane
        @test tb_ok(t, tb_bash("echo run git commit later"; agent = nothing, cwd = L))
        @test tb_ok(t, tb_bash("printf '%s\\n' git commit"; agent = nothing, cwd = L))
        tb_stage!(L, Dict("docs/n.md" => "n\n"))   # control: a real commit behind env is still guarded
        @test tb_no(t, tb_bash("env GIT_AUTHOR_NAME=test-writer GIT_AUTHOR_EMAIL=test-writer@factory.invalid git -C $L commit -q -m x"; agent = nothing, cwd = L), "§0.5")
    end
    @testset "Minor 7 tdd-mode in prose allowed; a TDD-Mode trailer line denied" begin
        t = tb_topo(); L = t.lane
        tb_stage!(L, Dict("test/t2.jl" => "x\n"))
        @test tb_no(t, twb(t, "git -C $L commit -q -m x -m \"TDD-Mode: skip — r\" --author \"$TB_TW\""), "§0.5")
        @test tb_no(t, twb(t, "git -C $L commit -q -m x -m \"tdd-mode: skip — r\" --author \"$TB_TW\""), "§0.5")
        f = tb_flow(t, "git -C $L commit -q -m \"test: red for the tdd-mode parser\" -m \"TDD: red\" --author \"$TB_TW\"")
        @test f.pre.rc == 0 && f.ran
        @test any(r -> get(r, "sha", "") == tb_head(L) && get(r, "agent_type", "") == "test-writer", tb_recs(t, "tdd-commit"))
        @test isempty(tb_recs(t, "tdd-commit-violation"))
    end
    @testset "Nit 2 dispatch with lane= not the checkout's lane denied" begin
        t = tb_topo(); L = t.lane
        @test tb_no(t, tb_disp3(L, tb_head(L); lane = "lane2"))
        @test tb_no(t, tb_disp3(L, tb_head(L); lane = "other"))
        @test tb_ok(t, tb_disp3(L, tb_head(L)))
    end

    # ---- B1b: an implementer Bash write target with { or } is denied (brace expansion can reach test/) ----
    @testset "B1b implementer brace-expansion write into test/ denied" begin
        t = tb_topo(); L = t.lane
        imb(c) = tb_bash(c; agent = "implementer", cwd = L)
        for c in ("echo x | tee src/{..,zz}/test/x_tests.jl", "cp src/P.jl src/{../test/x_tests.jl,b.jl}",
                "echo y > src/{..,.}/test/x_tests.jl")
            @test tb_no(t, imb(c))
        end
        @test tb_ok(t, imb("echo x | tee src/b.jl"))
        @test tb_ok(t, imb("cp src/P.jl src/b.jl"))
        @test tb_ok(t, tb_bash("echo x | tee src/{a,b}.jl"; agent = nothing, cwd = L))   # the lead is unaffected
    end

    # ---- review round 2 ----
    # R2-B1: a role caller's raw Bash command containing $' or $" is denied (bash and zsh expand the escapes).
    @testset "R2-B1 ANSI-C or locale quoting denied for role callers" begin
        t = tb_topo(); L = t.lane
        @test isfile("$L/src/P.jl") && isfile("$L/test/t.jl")   # precondition
        for c in (raw"cat test/$'\x2e\x2e'/src/P.jl", raw"cat test/$'\056\056'/src/P.jl",
                raw"grep -rn secret test/$'\x2e\x2e'/src", "cat test/\$\"t.jl\"")
            @test tb_no(t, twb(t, c))
        end
        @test tb_no(t, tb_bash(raw"cp src/P.jl $'\x74est'/x_tests.jl"; agent = "implementer", cwd = L))
        @test tb_ok(t, twb(t, "cat test/t.jl"))
        @test tb_ok(t, tb_bash(raw"printf $'a\tb\n'"; agent = nothing, cwd = L))   # the lead is unaffected
    end

    # R2-M1: the role-write .git component check ignores case; only an entry named exactly .git marks a checkout.
    @testset "R2-M1 .GIT case variant neither writable nor a checkout marker" begin
        t = tb_topo(); L = t.lane
        @test tb_no(t, tb_write("$L/test/.GIT/HEAD"))
        @test tb_no(t, tb_write("$L/test/.Git/config"; tool = "Edit"))
        probe = mktempdir(); mkpath(joinpath(probe, "x", ".GIT"))
        ci = isdir(joinpath(probe, "x", ".git"))   # case-insensitive filesystem: .GIT aliases .git
        @info "R2-M1 filesystem case-insensitive: $ci"
        mkpath(joinpath(L, "test", ".GIT"))   # planted directly, as the reviewer's probe does
        tb_write!(L, Dict("test/scripts/tdd.jl" => "print(read(\"../src/P.jl\", String))\n"))
        @test tb_no(t, tb_write("$L/test/x_tests.jl"; agent = "implementer"))
        @test tb_no(t, twb(t, "julia test/scripts/tdd.jl red"))
    end

    # ---- review round 3 ----
    # R3-B1: segments() drops heredoc bodies, and bash expands $(…) and `…` in an unquoted body. RULING: a
    # test-writer's raw Bash command containing $, a backquote or << anywhere is denied; others keep heredocs.
    @testset "R3-B1 test-writer heredoc denied; implementer and lead heredoc commit forms unaffected" begin
        t = tb_topo(); L = t.lane
        @test isfile("$L/src/P.jl") && isfile("$L/test/t.jl")   # precondition
        for c in ("cat <<EOF\n\$(cat src/P.jl)\nEOF", "cat <<EOF\n`cat src/P.jl`\nEOF",
                "cat <<'EOF'\nplain\nEOF", "cat <<<plain")
            @test tb_no(t, twb(t, c))
            r = tb_run(t, twb(t, c))   # the deny says how to commit instead: a message in plain quotes
            @test r.rc == 2 && occursin(r"plain quotes|-m \"", r.err)
        end
        @test tb_ok(t, twb(t, "cat test/t.jl"))
        @test tb_ok(t, tb_bash("cat <<EOF\nhello\nEOF"; agent = nothing, cwd = L))   # the lead is unaffected
        @test tb_ok(t, tb_bash("git log --oneline <<EOF\nx\nEOF"; agent = nothing, cwd = L))
        @test tb_ok(t, tb_bash("cat <<EOF\nhello\nEOF"; agent = "implementer", cwd = L))   # the implementer too
    end
    @testset "R3-B1 test-writer normal commands still pass" begin
        t = tb_topo(); L = t.lane
        for c in ("julia scripts/tdd.jl red", "cd $L && julia scripts/tdd.jl green",
                "julia scripts/ci.jl test -- \"item=h doubles\"", "git add test/t.jl")
            @test tb_ok(t, twb(t, c))
        end
        tb_stage!(L, Dict("test/t.jl" => "@testitem \"h doubles\" begin\n    @test false\nend\n"))   # test/ only
        r = tb_run(t, twb(t, "git commit --author \"$TB_TW\" -m \"test: h doubles\" -m \"TDD: red\""))
        @test r.rc == 0
    end
end
