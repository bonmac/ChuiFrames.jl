"Run hook `name` with `payload` on stdin; returns (exit code, stdout, stderr)."
function hook(name, payload, root; env = Dict{String, String}(), hooks = HOOKS)
    out, err = IOBuffer(), IOBuffer()
    cmd = addenv(`sh $(joinpath(hooks, name))`, "CLAUDE_PROJECT_DIR" => root, env...)
    p = run(pipeline(ignorestatus(cmd); stdin = IOBuffer(payload), stdout = out, stderr = err))
    return p.exitcode, String(take!(out)), String(take!(err))
end
json(s) = replace(s, "\\" => "\\\\", "\"" => "\\\"", "\n" => "\\n")
bash(cmd; cwd = "") = "{\"session_id\":\"s1\",\"cwd\":\"$(json(cwd))\",\"tool_input\":{\"command\":\"$(json(cmd))\"}}"
write_payload(path; key = "file_path") = "{\"session_id\":\"s1\",\"tool_input\":{\"$key\":\"$(json(path))\"}}"
blocked(name, payload, root; kw...) = hook(name, payload, root; kw...)[1] == 2
const OUT = "/opt/factory-test-outside" # a path outside every allowed location
# the coordinator profile's reference repos (factory/profiles/coordinator/.agents/factory.toml)
const REF_ROOTS = ["~/reference-project-a", "~/reference-project-b",
                   "~/reference-project-c"]
"A copy of the hooks with `roots` as the generated read-only-roots.txt."
function hooks_with_roots(roots)
    h = joinpath(mktempdir(), "hooks")
    cp(HOOKS, h)
    write(joinpath(h, "read-only-roots.txt"), "# test\n" * join(roots .* "\n"))
    return h
end

@testset "hooks" begin
    root = realpath(mktempdir())

    @testset "bash_guard denylist" begin
        for c in ("git -c x=y reset --hard", "git --no-pager -C . push", "git -C . -c a=b clean -fd",
                  "rm -rf build", "rm -fr build", "rm -r -f build", "git reset --hard HEAD~1",
                  "git clean -fdx", "git add -A", "git add .", "git stash", "git stash pop",
                  "git stash drop", "git push origin main", "git push --force origin x",
                  "gh repo create x --public", "gh pr create --fill", "gh release create v1",
                  "git commit --no-verify -m x", "pkill -f julia", "ls && git reset --hard",
                  # review round 1 regressions
                  "git -C . push", "git -C . reset --hard", "rm -r -v -f build", "rm --recursive --force build",
                  "git stash -u", "git stash push", "git stash 2>&1", "gh api repos/o/r/issues -f title=x",
                  "gh api --method DELETE repos/o/r", "gh workflow run ci.yml", "gh pr ready 3",
                  "gh secret set X", "gh run rerun 1", "gh label create bug")
            @test blocked("bash_guard.sh", bash(c), root) || (println("not blocked: $c"); false)
        end
        for c in ("ls -la", "git status", "git add src/a.jl", "git stash push -m tag",
                  "git stash list", "git stash apply abc123", "rm -r build", "gh pr view 3",
                  "julia --project -e 'using Pkg; Pkg.test()'", "git log --oneline | head",
                  # review round 1 false positives
                  "gh release list", "gh release view v1", "git commit -m \"docs: explain why rm -rf is blocked\"",
                  "rg -- --no-verify .", "git commit -m \"move a -> /docs\"", "echo hi | tee /dev/tty",
                  "cat > notes.md <<'EOF'\nmkdir /opt/homebrew/x\nrm -rf /\nEOF",
                  "git commit -F- <<EOF\na -> ~/b\nEOF", "git stash show -p", "jq '.a > 1' f.json")
            @test !blocked("bash_guard.sh", bash(c), root) || (println("blocked: $c"); false)
        end
        allow = Dict("FACTORY_ALLOW_PUSH" => "1")
        @test !blocked("bash_guard.sh", bash("git push origin feat/x"), root; env = allow)
        @test !blocked("bash_guard.sh", bash("git push --force-with-lease origin x"), root; env = allow)
        @test blocked("bash_guard.sh", bash("git push --force origin x"), root; env = allow)
        # an inline assignment does not reach the hook's environment
        @test blocked("bash_guard.sh", bash("FACTORY_ALLOW_PUSH=1 git push"), root)
        @test !blocked("bash_guard.sh", bash("gh pr create --fill"), root; env = Dict("FACTORY_ALLOW_OUTWARD" => "1"))
    end

    @testset "bash_guard: no writes outside the repo root" begin
        for c in ("echo x > $OUT/f", "echo x >> $OUT/f", "echo x 2>$OUT/err", "touch $OUT/f",
                  "mkdir -p $OUT", "cp a.txt $OUT/", "mv $OUT/a b", "cat f | tee $OUT/f",
                  "rm $OUT/f", "touch ~/factory-test-file", "dd if=/dev/zero of=$OUT/z count=1",
                  "git -C $OUT commit -m x", "cd . && touch ../../../../../../../../../../opt/x",
                  "echo hi &>$OUT/x", "echo hi &> $OUT/x", "echo>$OUT/x", "touch \$HOME/factory-x",
                  "echo x > \${HOME}/.zshrc-factory-test", "cat <<EOF > $OUT/f\nbody\nEOF")
            @test blocked("bash_guard.sh", bash(c; cwd = root), root) || (println("not blocked: $c"); false)
        end
        for c in ("cat $OUT/f", "cp $OUT/f ./copy", "grep -r x $OUT", "git -C $OUT log -1",
                  "echo x > /dev/null 2>&1", "touch /tmp/factory-x", "echo x > out.txt",
                  "mkdir -p sub/dir", "touch $root/inside", "ls $OUT > listing.txt")
            @test !blocked("bash_guard.sh", bash(c; cwd = root), root) || (println("blocked: $c"); false)
        end
        rc, _, err = hook("bash_guard.sh", bash("touch $OUT/f"), root)
        @test rc == 2 && occursin("outside the repo root", err)
    end

    @testset "bash_guard: read-only roots allow only read-only commands" begin
        h = hooks_with_roots(REF_ROOTS)
        ro(c; cwd = root) = hook("bash_guard.sh", bash(c; cwd), root; hooks = h)
        mt = "~/reference-project-b"
        # the 2026-10-19 incident: a lane re-synced reference-project-b's .venv this way
        rc, _, err = ro("cd ~/reference-project-b && uv run python -m pytest -q")
        @test rc == 2 && occursin("read-only reference root", err) && occursin("`uv`", err)
        for c in ("cd $mt && uv sync", "cd $mt; make test", "cd $mt && julia --project -e 1",
                  "cd $mt && git checkout main", "cd $mt && git pull", "cd $mt && git -c x=y fetch",
                  "git -C $mt checkout -b x", "git -C $mt fetch", "git -C $mt stash list",
                  "make -C ~/reference-project-a all", "make --directory=$mt", "make -C$mt",
                  "uv --directory ~/reference-project-a run x", "uv run --project $mt x",
                  "uv run --directory=$mt x", "uvx --directory $mt ruff", "julia --project=$mt -e 'using Pkg; Pkg.instantiate()'",
                  "cd \$HOME/reference-project-b && python x.py", "cd \"$mt\" && npm install",
                  "cd $mt/sub/dir && touch notes", "cd $mt && find . -name '*.pyc' -delete",
                  "cd $mt && find . -exec rm {} +", "cd $mt && ls | xargs cat", "cd /tmp && cd $mt && sh run.sh",
                  "pushd ~/reference-project-c && Rscript a.R")
            @test ro(c)[1] == 2 || (println("not blocked: $c"); false)
        end
        for c in ("cd $mt && ls -la && git log -3 && git status", "git -C $mt log -1", "git -C $mt --no-pager show HEAD",
                  "git -C $mt diff HEAD~1", "git -C $mt blame README.md", "git -C $mt ls-files",
                  "cat $mt/README.md | head -20", "rg -n foo $mt", "grep -r foo $mt/src", "find $mt -name '*.py'",
                  "cd $mt && wc -l *.py && stat x && file y && tail z && less w && pwd",
                  "cd $mt && cd - && ls", "cd ~/reference-project-b-other && uv run x",
                  "uv run python -c 1", "make -C sub all", "cd $mt && cd $root && uv run x",
                  "git log -1 -- ~/reference-project-b")
            @test ro(c)[1] == 0 || (println("blocked: $c ", ro(c)[3]); false)
        end
        # review round 2 (0.2.0): global options before -C, cd flags, case, env -C, fd duplication
        for c in ("git -c a=b -C $mt commit -m x", "git --no-pager -C $mt commit", "cd -P $mt && make",
                  "cd -L $mt && make", "cd ~/Reference-Project-B && make", "env -C $mt make",
                  "env FOO=1 --chdir=$mt make", "cd $mt && git log 2>&1 | head && uv sync")
            @test ro(c)[1] == 2 || (println("not blocked: $c"); false)
        end
        for c in ("cd $mt && git log 2>&1 | head", "cd $mt && ls >&2", "cd $mt && git status 2>&- && pwd",
                  "env FOO=1 ls $mt", "cd -P /tmp && make")
            @test ro(c)[1] == 0 || (println("blocked: $c ", ro(c)[3]); false)
        end
        # a session whose cwd is already inside a root is restricted too
        @test ro("uv sync"; cwd = expanduser(mt))[1] == 2
        @test ro("ls"; cwd = expanduser(mt))[1] == 0
        # the package profile seeds no roots: the same commands pass. Hermetic: an empty roots file,
        # not the checkout's generated one (a coordinator checkout lists reference-project-b there)
        @test !blocked("bash_guard.sh", bash("cd $mt && uv run x"), root; hooks = hooks_with_roots(String[]))
    end

    @testset "bash_guard: cd is tracked for writes outside the root" begin
        @test blocked("bash_guard.sh", bash("cd $OUT && touch f"; cwd = root), root)
        @test blocked("bash_guard.sh", bash("cd /opt; echo x > f"; cwd = root), root)
        @test blocked("bash_guard.sh", bash("git -c a=b -C $OUT commit -m x"; cwd = root), root)
        @test blocked("bash_guard.sh", bash("echo hi &>$OUT/x; ls"; cwd = root), root)
        @test !blocked("bash_guard.sh", bash("julia x.jl 2>&1 | tail"; cwd = root), root)
        @test !blocked("bash_guard.sh", bash("cd /tmp && touch factory-x"; cwd = root), root)
        @test !blocked("bash_guard.sh", bash("cd $root/sub && touch f"; cwd = root), root)
    end

    @testset "write_guard" begin
        @test blocked("write_guard.sh", write_payload("$OUT/x.jl"), root)
        @test blocked("write_guard.sh", write_payload(expanduser("~/x.md")), root)
        @test !blocked("write_guard.sh", write_payload("$root/src/A.jl"), root)
        @test !blocked("write_guard.sh", write_payload("/tmp/scratch.md"), root)
        @test !blocked("write_guard.sh", write_payload("$root/Project.toml"), root)            # T2: dod.jl
        rc, _, err = hook("write_guard.sh", write_payload("$root/.github/workflows/CI.yml"), root)
        @test rc == 2 && occursin("T3", err)
        @test blocked("write_guard.sh", write_payload("$root/.claude/hooks/bash_guard.sh"), root)
        @test blocked("write_guard.sh", write_payload("$root/risk.toml"), root)
        @test blocked("write_guard.sh", write_payload("$root/RISK.toml"), root)            # APFS is case-insensitive
        @test blocked("write_guard.sh", write_payload("$root/.Claude/Settings.json"), root)
        @test blocked("write_guard.sh", write_payload("$root/a.ipynb/../risk.toml"; key = "notebook_path"), root)
        @test !blocked("write_guard.sh", write_payload("$root/risk.toml"), root; env = Dict("FACTORY_ALLOW_T3" => "1"))
        # a worktree lane: matched relative to the lane's checkout
        lane = joinpath(root, ".worktrees", "l1")
        mkpath(lane)
        write(joinpath(lane, ".git"), "gitdir: elsewhere\n")
        @test blocked("write_guard.sh", write_payload("$lane/.github/workflows/CI.yml"), root)
        @test !blocked("write_guard.sh", write_payload("$lane/src/A.jl"), root)
        @test !blocked("write_guard.sh", "{}", root)
    end

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
        # with the scripts present the same command runs the guard (allow, then deny)
        bg = only(filter(contains("bash_guard.sh"), cmds))
        run1(payload) = run(pipeline(ignorestatus(addenv(`sh -c $bg`, "CLAUDE_PROJECT_DIR" => ROOT)); stdin = IOBuffer(payload), stdout = devnull, stderr = devnull)).exitcode
        @test run1(bash("ls")) == 0
        @test run1(bash("git reset --hard")) == 2
        # advisory hooks stay fail-open
        adv = readlines(pipeline(`jq -r '.hooks | to_entries[] | select(.key != "PreToolUse") | .value[].hooks[].command' $settings`))
        @test !isempty(adv) && all(c -> !occursin("exit 2", c), adv)
    end

    @testset "hook start-up cost" begin
        n = 20
        t = @elapsed for _ in 1:n
            hook("bash_guard.sh", bash("git status && ls -la src"), root)
        end
        println("bash_guard.sh: $(round(1000t / n; digits = 1)) ms per call (n=$n)")
        @test t / n < 0.5
        h = hooks_with_roots(REF_ROOTS)
        c = "cd ~/reference-project-b && git log -3 && ls -la | head && cd $root && git status && echo x > out.txt"
        t = @elapsed for _ in 1:n
            hook("bash_guard.sh", bash(c; cwd = root), root; hooks = h)
        end
        println("bash_guard.sh with 3 read-only roots, 6 segments: $(round(1000t / n; digits = 1)) ms per call (n=$n, includes spawning sh from Julia)")
        @test t / n < 0.25
    end
end

@testset "hook payloads in these tests are valid JSON" begin
    for p in (bash("a\nb \"q\" \\x"), write_payload("/x\ny"))
        @test success(pipeline(`jq -e .tool_input`; stdin = IOBuffer(p), stdout = devnull))
    end
end
