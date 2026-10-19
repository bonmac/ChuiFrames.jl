# Lane-lifecycle hooks (teammate_idle, lane_ledger, dispatch_limit, precompact, session_start) and
# the settings.json wiring. Split from test_hooks.jl in 0.2.5 to keep both under the 400-line
# `scripts/*.jl` budget once Runic-formatted; uses its helpers (hook, TEST_HOOKS, bash, ...).
@testset "hooks: lifecycle and settings.json" begin
    root = realpath(mktempdir())

    @testset "teammate_idle: first unreported idle blocked, report demanded" begin
        idle(name) = "{\"session_id\":\"s1\",\"team_name\":\"t\",\"teammate_name\":\"$name\"}"
        rc, _, err = hook("teammate_idle.sh", idle("alpha"), root)
        @test rc == 2 && occursin("report", err) && occursin("FAILED", err)
        @test hook("teammate_idle.sh", idle("alpha"), root)[1] == 0          # second idle: no loop
        @test occursin("idle-unreported", read(joinpath(root, ".lanes/ledger.jsonl"), String))
        @test hook("teammate_idle.sh", idle("beta"), root)[1] == 2
        mkpath(joinpath(root, ".lanes/reports"))
        write(joinpath(root, ".lanes/reports/gamma.md"), "report\n")
        @test hook("teammate_idle.sh", idle("gamma"), root)[1] == 0          # report on disk
        @test hook("teammate_idle.sh", "{}", root)[1] == 0
    end

    @testset "lane_ledger + dispatch_limit" begin
        ev(e, id; s = "s2") = "{\"session_id\":\"$s\",\"hook_event_name\":\"$e\",\"agent_id\":\"$id\",\"agent_type\":\"general-purpose\"}"
        spawn = "{\"session_id\":\"s2\",\"tool_name\":\"Agent\",\"tool_input\":{\"subagent_type\":\"reviewer\"}}"
        cap = Dict("FACTORY_MAX_OPEN_LANES" => "2")
        @test hook("dispatch_limit.sh", spawn, root; env = cap)[1] == 0
        hook("lane_ledger.sh", ev("SubagentStart", "a1"), root)
        hook("lane_ledger.sh", ev("SubagentStart", "a2"), root)
        hook("lane_ledger.sh", ev("SubagentStart", "x9"; s = "other"), root)   # other session
        rc, _, err = hook("dispatch_limit.sh", spawn, root; env = cap)
        @test rc == 2 && occursin("cap 2", err)
        hook("lane_ledger.sh", ev("SubagentStop", "a1"), root)
        @test hook("dispatch_limit.sh", spawn, root; env = cap)[1] == 0
        lines = readlines(joinpath(root, ".lanes/ledger.jsonl"))
        @test all(l -> success(pipeline(`jq -e .ts`; stdin = IOBuffer(l), stdout = devnull)), lines)
        @test any(l -> occursin("\"dispatch-denied\"", l), lines)
        # a resumed agent (start, stop, start) is open again; anonymous events count as starts - stops
        r2 = realpath(mktempdir())
        for (e, id) in (("SubagentStart", "a3"), ("SubagentStop", "a3"), ("SubagentStart", "a3"))
            hook("lane_ledger.sh", ev(e, id), r2)
        end
        anon(e) = "{\"session_id\":\"s2\",\"hook_event_name\":\"$e\"}"
        hook("lane_ledger.sh", anon("SubagentStart"), r2)
        hook("lane_ledger.sh", anon("SubagentStart"), r2)
        @test hook("dispatch_limit.sh", spawn, r2; env = Dict("FACTORY_MAX_OPEN_LANES" => "3"))[1] == 2
        hook("lane_ledger.sh", anon("SubagentStop"), r2)
        @test hook("dispatch_limit.sh", spawn, r2; env = Dict("FACTORY_MAX_OPEN_LANES" => "3"))[1] == 0
        # a missing session_id is stored and queried as the same value
        nosess = "{\"hook_event_name\":\"SubagentStart\",\"agent_id\":\"z1\"}"
        r3 = realpath(mktempdir())
        hook("lane_ledger.sh", nosess, r3)
        @test hook("dispatch_limit.sh", "{\"tool_input\":{}}", r3; env = Dict("FACTORY_MAX_OPEN_LANES" => "1"))[1] == 2
        # 0.2.3 (m4): a malformed or truncated ledger line is skipped; 0.2.2 counted 0 lanes (fail open)
        r4 = realpath(mktempdir())
        hook("lane_ledger.sh", ev("SubagentStart", "b1"), r4)
        hook("lane_ledger.sh", ev("SubagentStart", "b2"), r4)
        open(io -> print(io, "garbage{\n{\"ts\":\"t\",\"ev\":\"sta"), joinpath(r4, ".lanes/ledger.jsonl"), "a")
        @test hook("dispatch_limit.sh", spawn, r4; env = cap)[1] == 2
        @test hook("dispatch_limit.sh", spawn, r4; env = Dict("FACTORY_MAX_OPEN_LANES" => "3"))[1] == 0
        # default cap comes from limits.env (generated from the registry)
        @test occursin("MAX_OPEN_LANES=", read(joinpath(HOOKS, "limits.env"), String))
    end

    @testset "precompact writes a snapshot; session_start re-injects it" begin
        repo = tmp_repo()
        rc, _, _ = hook("precompact.sh", "{\"session_id\":\"s3\",\"trigger\":\"auto\"}", repo)
        snap = joinpath(repo, ".lanes/precompact.md")
        @test rc == 0 && isfile(snap)
        @test occursin("branch: main", read(snap, String)) && occursin("Preserve:", read(snap, String))
        rc, out, _ = hook("session_start.sh", "{\"source\":\"compact\"}", repo)
        @test rc == 0 && occursin("Pre-compaction snapshot", out)
        @test hook("session_start.sh", "{}", root)[1] == 0     # no snapshot: silent
    end

    @testset "a denial from a factory/template session root says so" begin
        fac = realpath(mktempdir())
        write(joinpath(fac, "MANIFEST.toml"), "version = 1\n")
        tpl = joinpath(fac, "template")
        mkpath(tpl)
        rc, _, err = hook("write_guard.sh", write_payload("$OUT/x"), tpl)
        @test rc == 2 && occursin("factory template", err) && occursin("repo root", err)
        rc, _, err = hook("write_guard.sh", write_payload("$OUT/x"), root)
        @test rc == 2 && !occursin("factory template", err)
    end

    @testset "settings.json: guards fail CLOSED when their script is missing" begin
        settings = joinpath(ROOT, ".claude/settings.json")
        cmds = readlines(pipeline(`jq -r '.hooks.PreToolUse[].hooks[].command' $settings`))
        @test length(cmds) == 3
        guards = ("bash_guard.sh", "write_guard.sh", "dispatch_limit.sh")
        @test all(g -> any(contains(g), cmds), guards)
        empty_root = realpath(mktempdir())                       # no .claude/hooks/ at all
        shells = filter(s -> Sys.which(s) !== nothing, ["sh", "bash", "zsh", "fish"])
        for c in cmds, s in shells                               # the command must not depend on the user's shell
            out, err = IOBuffer(), IOBuffer()
            p = run(pipeline(ignorestatus(addenv(`$s -c $c`, "CLAUDE_PROJECT_DIR" => empty_root)); stdin = IOBuffer("{}"), stdout = out, stderr = err))
            @test (p.exitcode == 2 && occursin("missing", String(take!(err)))) || (println("$s: $c -> $(p.exitcode)"); false)
        end
        # with the scripts present (a hermetic copy, 0.2.5) the same command runs the guard: allow, then deny
        proj = realpath(mktempdir())
        cp(dirname(TEST_HOOKS), joinpath(proj, ".claude"))
        bg = only(filter(contains("bash_guard.sh"), cmds))
        run1(payload) = run(pipeline(ignorestatus(addenv(`sh -c $bg`, "CLAUDE_PROJECT_DIR" => proj)); stdin = IOBuffer(payload), stdout = devnull, stderr = devnull)).exitcode
        @test run1(bash("ls")) == 0
        @test run1(bash("git reset --hard")) == 2
        # advisory hooks stay fail-open
        adv = readlines(pipeline(`jq -r '.hooks | to_entries[] | select(.key != "PreToolUse") | .value[].hooks[].command' $settings`))
        @test !isempty(adv) && all(c -> !occursin("exit 2", c), adv)
    end
end
