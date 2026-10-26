"Run hook `name` with `payload` on stdin; returns (exit code, stdout, stderr)."
function hook(name, payload, root; env = Dict{String, String}(), hooks = TEST_HOOKS)
    out, err = IOBuffer(), IOBuffer()
    cmd = addenv(`sh $(joinpath(hooks, name))`, "CLAUDE_PROJECT_DIR" => root, env...)
    p = run(pipeline(ignorestatus(cmd); stdin = IOBuffer(payload), stdout = out, stderr = err))
    return p.exitcode, String(take!(out)), String(take!(err))
end
# 0.2.4: tabs are escaped too; a raw tab is invalid JSON, which the guards now refuse (fail closed)
json(s) = replace(s, "\\" => "\\\\", "\"" => "\\\"", "\n" => "\\n", "\t" => "\\t")
bash(cmd; cwd = "") = "{\"session_id\":\"s1\",\"cwd\":\"$(json(cwd))\",\"tool_input\":{\"command\":\"$(json(cmd))\"}}"
write_payload(path; key = "file_path") = "{\"session_id\":\"s1\",\"tool_input\":{\"$key\":\"$(json(path))\"}}"
blocked(name, payload, root; kw...) = hook(name, payload, root; kw...)[1] == 2
const OUT = "/opt/factory-test-outside" # a path outside every allowed location
# fixture reference repos (never created): a ~ path, an absolute one, another ~ path
const REF_ROOTS = [
    "/tmp/ro-fixture/ref-b", "~/ro-fixture/ref-a",
    "~/ro-fixture/ref-c",
]
"A copy of the hooks with `roots` as the generated read-only-roots.txt (and roots not required, 0.2.4: hermetic in the coordinator profile too)."
function hooks_with_roots(roots; required = false, src = HOOKS)
    h = joinpath(mktempdir(), "hooks")
    cp(src, h)
    write(joinpath(h, "read-only-roots.txt"), "# test\n" * join(roots .* "\n"))
    env = joinpath(h, "limits.env")
    write(env, replace(read(env, String), r"READ_ONLY_ROOTS_REQUIRED=\d" => "READ_ONLY_ROOTS_REQUIRED=$(required ? 1 : 0)"))
    return h
end
# 0.2.5: tests run a copy, not HOOKS (its roots file is gitignored and a coordinator requires it: fail closed in CI)
const TEST_HOOKS = hooks_with_roots(String[])   # no roots, not required; a test needing roots builds its own

@testset "hooks" begin
    root = realpath(mktempdir())

    @testset "bash_guard denylist" begin
        for c in (
                "git -c x=y reset --hard", "git --no-pager -C . push", "git -C . -c a=b clean -fd",
                "rm -rf build", "rm -fr build", "rm -r -f build", "git reset --hard HEAD~1",
                "git clean -fdx", "git add -A", "git add .", "git stash", "git stash pop",
                "git stash drop", "git push origin main", "git push --force origin x",
                "gh repo create x --public", "gh pr create --fill", "gh release create v1",
                "git commit --no-verify -m x", "pkill -f julia", "ls && git reset --hard",
                # review round 1 regressions
                "git -C . push", "git -C . reset --hard", "rm -r -v -f build", "rm --recursive --force build",
                "git stash -u", "git stash push", "git stash 2>&1", "gh api repos/o/r/issues -f title=x",
                "gh api --method DELETE repos/o/r", "gh workflow run ci.yml", "gh pr ready 3",
                "gh secret set X", "gh run rerun 1", "gh label create bug",
            )
            @test blocked("bash_guard.sh", bash(c), root) || (println("not blocked: $c"); false)
        end
        for c in (
                "ls -la", "git status", "git add src/a.jl", "git stash push -m tag",
                "git stash list", "git stash apply abc123", "rm -r build", "gh pr view 3",
                "julia --project -e 'using Pkg; Pkg.test()'", "git log --oneline | head",
                # review round 1 false positives
                "gh release list", "gh release view v1", "git commit -m \"docs: explain why rm -rf is blocked\"",
                "rg -- --no-verify .", "git commit -m \"move a -> /docs\"", "echo hi | tee /dev/tty",
                "cat > notes.md <<'EOF'\nmkdir /opt/homebrew/x\nrm -rf /\nEOF",
                "git commit -F- <<EOF\na -> ~/b\nEOF", "git stash show -p", "jq '.a > 1' f.json",
            )
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
        for c in (
                "echo x > $OUT/f", "echo x >> $OUT/f", "echo x 2>$OUT/err", "touch $OUT/f",
                "mkdir -p $OUT", "cp a.txt $OUT/", "mv $OUT/a b", "cat f | tee $OUT/f",
                "rm $OUT/f", "touch ~/factory-test-file", "dd if=/dev/zero of=$OUT/z count=1",
                "git -C $OUT commit -m x", "cd . && touch ../../../../../../../../../../opt/x",
                "echo hi &>$OUT/x", "echo hi &> $OUT/x", "echo>$OUT/x", "touch \$HOME/factory-x",
                "echo x > \${HOME}/.zshrc-factory-test", "cat <<EOF > $OUT/f\nbody\nEOF",
            )
            @test blocked("bash_guard.sh", bash(c; cwd = root), root) || (println("not blocked: $c"); false)
        end
        for c in (
                "cat $OUT/f", "cp $OUT/f ./copy", "grep -r x $OUT", "git -C $OUT log -1",
                "echo x > /dev/null 2>&1", "touch /tmp/factory-x", "echo x > out.txt",
                "mkdir -p sub/dir", "touch $root/inside", "ls $OUT > listing.txt",
            )
            @test !blocked("bash_guard.sh", bash(c; cwd = root), root) || (println("blocked: $c"); false)
        end
        rc, _, err = hook("bash_guard.sh", bash("touch $OUT/f"), root)
        @test rc == 2 && occursin("outside the repo root", err)
    end

    @testset "bash_guard: read-only roots allow only read-only commands" begin
        h = hooks_with_roots(REF_ROOTS)
        ro(c; cwd = root) = hook("bash_guard.sh", bash(c; cwd), root; hooks = h)
        mt = "~/ro-fixture/ref-a"
        # the 2026-10-19 incident: a lane re-synced a reference repo's .venv this way
        rc, _, err = ro("cd ~/ro-fixture/ref-a && uv run python -m pytest -q")
        @test rc == 2 && occursin("read-only reference root", err) && occursin("`uv`", err)
        for c in (
                "cd $mt && uv sync", "cd $mt; make test", "cd $mt && julia --project -e 1",
                "cd $mt && git checkout main", "cd $mt && git pull", "cd $mt && git -c x=y fetch",
                "git -C $mt checkout -b x", "git -C $mt fetch", "git -C $mt stash list",
                "make -C /tmp/ro-fixture/ref-b all", "make --directory=$mt", "make -C$mt",
                "uv --directory /tmp/ro-fixture/ref-b run x", "uv run --project $mt x",
                "uv run --directory=$mt x", "uvx --directory $mt ruff", "julia --project=$mt -e 'using Pkg; Pkg.instantiate()'",
                "cd \$HOME/ro-fixture/ref-a && python x.py", "cd \"$mt\" && npm install",
                "cd $mt/sub/dir && touch notes", "cd $mt && find . -name '*.pyc' -delete",
                "cd $mt && find . -exec rm {} +", "cd $mt && ls | xargs cat", "cd /tmp && cd $mt && sh run.sh",
                "pushd ~/ro-fixture/ref-c && Rscript a.R",
            )
            @test ro(c)[1] == 2 || (println("not blocked: $c"); false)
        end
        for c in (
                "cd $mt && ls -la && git log -3 && git status", "git -C $mt log -1", "git -C $mt --no-pager show HEAD",
                "git -C $mt diff HEAD~1", "git -C $mt blame README.md", "git -C $mt ls-files",
                "cat $mt/README.md | head -20", "rg -n foo $mt", "grep -r foo $mt/src", "find $mt -name '*.py'",
                "cd $mt && wc -l *.py && stat x && file y && tail z && less w && pwd",
                "cd $mt && cd - && ls", "cd ~/ro-fixture/ref-a-other && uv run x",
                "uv run python -c 1", "make -C sub all", "cd $mt && cd $root && uv run x",
                "git log -1 -- ~/ro-fixture/ref-a",
            )
            @test ro(c)[1] == 0 || (println("blocked: $c ", ro(c)[3]); false)
        end
        # review round 2 (0.2.0): global options before -C, cd flags, case, env -C, fd duplication
        for c in (
                "git -c a=b -C $mt commit -m x", "git --no-pager -C $mt commit", "cd -P $mt && make",
                "cd -L $mt && make", "cd ~/RO-Fixture/Ref-A && make", "env -C $mt make",
                "env FOO=1 --chdir=$mt make", "cd $mt && git log 2>&1 | head && uv sync",
            )
            @test ro(c)[1] == 2 || (println("not blocked: $c"); false)
        end
        for c in (
                "cd $mt && git log 2>&1 | head", "cd $mt && ls >&2", "cd $mt && git status 2>&- && pwd",
                "env FOO=1 ls $mt", "cd -P /tmp && make",
            )
            @test ro(c)[1] == 0 || (println("blocked: $c ", ro(c)[3]); false)
        end
        # a session whose cwd is already inside a root is restricted too
        @test ro("uv sync"; cwd = expanduser(mt))[1] == 2
        @test ro("ls"; cwd = expanduser(mt))[1] == 0
        # the package profile seeds no roots: the same commands pass. Hermetic: an empty roots file,
        # not the checkout's generated one (a coordinator checkout lists its reference repos there)
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

    @testset "bash_guard: quoted arguments are not redirects or commands (0.2.2)" begin
        # 0.2.1 read `'s/<Package>/X/g'` as a redirect to /X/g, and split commit messages at `;`
        for c in (
                "sed -i '' -e 's/<Package>/X/g' CLAUDE.md", "sed -e \"s/<a>/b/\" f", "git commit -m \"a; rm -rf x\"",
                "git commit -m 'x > /opt/y'", "grep -E '(a|b)>c' f", "awk '{print > \"/dev/stderr\"}' f",
                "git commit -m \"line one\nline; two > /opt/z\"", "echo \\> x", "jq '.[] | select(.a > 2)' f.json",
                "echo \$'a\\'; rm -rf x'", "echo \"\$(git rev-parse HEAD) > /opt/x\"", "ls # it's > /opt/x",
                "echo \${#x} && ls", "echo a#b > out.txt", "printf '%s' \"\$(printf '; rm -rf x')\"",
            )
            @test !blocked("bash_guard.sh", bash(c; cwd = root), root) || (println("blocked: $c"); false)
        end
        for c in (
                "echo \"a>b\" > $OUT/x", "touch \"$OUT/a b\"", "sed -e 's/a/b/' f > $OUT/out",
                "sed 's/x/y/' f >\"$OUT/q\"", "echo 'a;b' ; rm -rf build", "git commit -m 'x' && touch $OUT/f",
                "echo \"it's\" > $OUT/f", "git commit -m \"a\nb\" && git reset --hard",
                # review of 0.2.2 (B1): command substitution inside double quotes still runs
                "echo \"\$(rm -rf ~)\"", "echo \"\$(echo x > $OUT/foo)\"", "echo \"a\" \"\$(cd ~ && rm -rf Documents)\"",
                "echo \"`rm -rf ~`\"", "echo \"x \$(echo \"\$(touch $OUT/n)\")\"", "echo \"\$( (cd /; rm -rf x) )\"",
                # (B2): an apostrophe in a comment is not a quote
                "echo hi # it's\nrm -rf ~", "echo hi # it's\necho x > $OUT/evil", "# we don't want this\ngit reset --hard",
                # (B4): ANSI-C quoting
                "echo \$'\\'' ; rm -rf ~", "echo \$'a\\'b' > $OUT/f",
            )
            @test blocked("bash_guard.sh", bash(c; cwd = root), root) || (println("not blocked: $c"); false)
        end
        h = hooks_with_roots(REF_ROOTS)                                    # (B1) with a read-only root
        @test hook("bash_guard.sh", bash("echo \"\$(cd ~/ro-fixture/ref-a && make install)\""; cwd = root), root; hooks = h)[1] == 2
        @test hook("bash_guard.sh", bash("# don't\ncd ~/ro-fixture/ref-a && uv sync"; cwd = root), root; hooks = h)[1] == 2
    end

    @testset "bash_guard: rm -rf only on absolute scratch paths (0.2.2)" begin
        tmp = Dict("TMPDIR" => "/fake-tmpdir/T/")
        rmb(c; env = tmp) = blocked("bash_guard.sh", bash(c; cwd = root), root; env)
        u = readchomp(`id -u`)
        sc = "/private/tmp/claude-$u/proj/sess"                           # this user's session scratch
        for c in (
                "rm -rf $sc/scratchpad/x", "rm -rf /tmp/claude-$u/proj/sess/x", "rm -rf /fake-tmpdir/T/x",
                "rm -fr /private/fake-tmpdir/T/x /fake-tmpdir/T/a/../b", "rm -r -f $sc/a $sc/b", "rm -rf $sc/x/*",
            )
            @test !rmb(c) || (println("blocked: $c"); false)
        end
        # 0.2.3 (M1): no $TMPDIR form passes any more; the command shell's TMPDIR is unknowable
        for c in (
                "rm -rf \"\$TMPDIR/x\"", "rm -rf \${TMPDIR}/x", "rm -rf \"\$TMPDIR\"/x", "rm -rf \"\${TMPDIR}\"/x",
                "rm -rf \$TMPDIR/x", "rm -rf $sc/x/", "rm -rf $sc/x/.", "rm -rf $sc/{x,..}",
            )
            @test rmb(c) || (println("not blocked: $c"); false)
        end
        for c in (
                "rm -rf build", "rm -rf", "rm -rf /private/tmp/claude-$u", "rm -rf /tmp/claude-$u/",
                "rm -rf /private/tmp/claude-$u/proj", "rm -rf /private/tmp/claude-$u/proj/sess",
                "rm -rf /private/tmp/claude-$u/*/sess/x", "rm -rf /private/tmp/claude-$u/proj/*/x",
                "rm -rf /private/tmp/claude-$u/*", "rm -rf /private/tmp/claude-99999/proj/sess/x",
                "rm -rf /private/tmp/claude-*/proj/sess/x", "rm -rf $sc/x/../../../..", "rm -rf /tmp/other",
                "rm -rf \$TMPDIR", "rm -rf /fake-tmpdir/T", "rm -rf $sc/x build",
                "rm -rf \$HOME/x", "rm -rf \$X/y", "rm -rf \$(pwd)/x", "rm -rf $sc/x \$TMPDIR/..",
                # review of 0.2.2 (B3): the tracked cwd can be wrong, so relative targets never pass
                "cd $sc/x && cd && rm -rf *", "cd ~ && cd $sc/x && cd - && rm -rf *",
                "cd $sc/x && cd \"\$(git rev-parse --show-toplevel)\" && rm -rf *", "(cd $sc/x); rm -rf *",
                "pushd $sc/x && popd && rm -rf *", "cd /fake-tmpdir/T && rm -rf x",
                "TMPDIR=/Users/x; rm -rf \$TMPDIR/x", "export TMPDIR=\$HOME; rm -rf \"\$TMPDIR/Documents\"",
            )
            @test rmb(c) || (println("not blocked: $c"); false)
        end
        @test rmb("rm -rf \$TMPDIR/x"; env = Dict("TMPDIR" => ""))           # no TMPDIR: no scratch root
        @test rmb("rm -rf $root/sub"; env = Dict("TMPDIR" => dirname(root)))  # the repo is never scratch
        @test !rmb("rm -rf $(dirname(root))/other"; env = Dict("TMPDIR" => dirname(root)))
    end

    @testset "guards fail CLOSED when a sourced library is missing (0.2.2)" begin
        for lib in ("_lib.sh", "_bash_guard_lib.sh", "_read_only_roots.sh", "_bash_guard_cmd.sh", "_bash_guard_write.sh")
            h = joinpath(mktempdir(), "hooks"); cp(TEST_HOOKS, h); rm(joinpath(h, lib))
            rc, _, err = hook("bash_guard.sh", bash("ls"), root; hooks = h)
            @test rc == 2 && occursin("missing", err)
            lib == "_lib.sh" || continue
            for g in ("write_guard.sh", "dispatch_limit.sh")
                rc, _, err = hook(g, write_payload("$root/a.jl"), root; hooks = h)
                @test rc == 2 && occursin("missing", err)
            end
        end
        h = joinpath(mktempdir(), "hooks"); cp(TEST_HOOKS, h); rm(joinpath(h, "_lanes.sh"))   # 0.2.8
        rc, _, err = hook("dispatch_limit.sh", "{\"tool_input\":{\"name\":\"a\"}}", root; hooks = h)
        @test rc == 2 && occursin("_lanes.sh is missing", err)
        @test hook("lane_ledger.sh", "{\"hook_event_name\":\"SubagentStop\"}", root; hooks = h)[1] == 0   # advisory: fails open
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
        @test blocked("write_guard.sh", "{}", root)            # 0.2.4: no target key fails closed (0.2.3: rc 0)
        if IN_FACTORY # 0.2.2: the template seed (and the coordinator overlay) protect the gate itself
            gate = [
                ".agents/bodies/*", ".agents/checks.toml", ".claude/agents/*", ".codex/agents/*",
                "scripts/dod.jl", "scripts/ratchet.jl", "scripts/gen.jl", "scripts/check_docs.jl",
                "scripts/contract_usage.jl", "scripts/ci.jl", "scripts/_common.jl",
                # 0.2.4: the gate's own tests and the new gate scripts
                "scripts/test/*", "scripts/lane.jl", "scripts/lane", "scripts/bench.jl", "scripts/changelog.jl",
                "scripts/check_claims.jl", "scripts/evidence.jl",
            ]
            for f in (joinpath(ROOT, "risk.toml"), joinpath(FACTORY, "profiles/coordinator/risk.toml"))
                t3 = reduce(vcat, [p["globs"] for p in TOML.parsefile(f)["protected"] if p["tier"] == "T3"])
                @test issubset(gate, t3) || (println("$f misses ", setdiff(gate, t3)); false)
                @test !occursin("docs/adr/", read(f, String))                     # adr_dir is a profile parameter
            end
            for rel in (
                    ".agents/bodies/reviewer.md", ".agents/checks.toml", ".claude/agents/critic.md", ".agents/factory.local.toml",
                    "scripts/dod.jl", "scripts/ratchet.jl", "scripts/gen.jl", "scripts/check_docs.jl",
                    "scripts/contract_usage.jl", "scripts/ci.jl", "scripts/_common.jl", "scripts/test/test_dod.jl",
                    "scripts/test/runtests.jl", "scripts/lane.jl", "scripts/check_claims.jl",
                )
                @test blocked("write_guard.sh", write_payload("$root/$rel"), root) || (println("not blocked: $rel"); false)
            end
            @test !blocked("write_guard.sh", write_payload("$root/scripts/new_tool.jl"), root)
        end
    end

    # teammate_idle, lane_ledger, dispatch_limit, precompact, session_start, settings.json: test_hooks_lifecycle.jl

    @testset "hook start-up cost" begin
        n = 20
        t = @elapsed for _ in 1:n
            hook("bash_guard.sh", bash("git status && ls -la src"), root)
        end
        println("bash_guard.sh: $(round(1000t / n; digits = 1)) ms per call (n=$n)")
        @test t / n < 0.5
        h = hooks_with_roots(REF_ROOTS)
        c = "cd ~/ro-fixture/ref-a && git log -3 && ls -la | head && cd $root && git status && echo x > out.txt"
        t = @elapsed for _ in 1:n
            hook("bash_guard.sh", bash(c; cwd = root), root; hooks = h)
        end
        println("bash_guard.sh with 3 read-only roots, 6 segments: $(round(1000t / n; digits = 1)) ms per call (n=$n, includes spawning sh from Julia)")
        @test t / n < 0.25
        # 0.2.4: every in-root write target is matched against the T3 globs (no fork unless a path has capitals)
        c = "echo x > notes.md && sed -i '' s/a/b/ src/A.jl && cp a.txt docs/ && touch Build/x && rm -r build && mv a b"
        t = @elapsed for _ in 1:n
            hook("bash_guard.sh", bash(c; cwd = root), root)
        end
        println("bash_guard.sh with 7 in-root write targets (T3 check): $(round(1000t / n; digits = 1)) ms per call (n=$n)")
        @test t / n < 0.25
    end
end

@testset "hook payloads in these tests are valid JSON" begin
    for p in (bash("a\nb \"q\" \\x"), write_payload("/x\ny"))
        @test success(pipeline(`jq -e .tool_input`; stdin = IOBuffer(p), stdout = devnull))
    end
end

@testset "hooks: helpers" begin
    @testset "sandbox helpers are hermetic in a host that requires read-only roots (0.2.4)" begin
        # a coordinator checkout sets require_read_only_roots = true: 0.2.3's helpers copied that
        # setting and two tests failed there (861 pass / 2 fail). Build such a host and use it.
        host = gen_sandbox_noroots()
        write(joinpath(host, ".agents/factory.toml"), "version = 1\n[bash_guard]\nread_only_roots = []\nrequire_read_only_roots = true\n")
        capture(() -> Gen.write_all(host))
        @test occursin("READ_ONLY_ROOTS_REQUIRED=1", read(joinpath(host, ".claude/hooks/limits.env"), String))
        @test occursin("READ_ONLY_ROOTS_REQUIRED=0", Gen.outputs(gen_sandbox_noroots(host))[".claude/hooks/limits.env"])
        hh = joinpath(host, ".claude/hooks")
        r = realpath(mktempdir())
        c = bash("cd ~/ro-fixture/ref-a && uv run x")
        @test hook("bash_guard.sh", c, r; hooks = hh)[1] == 2               # the host itself fails closed (no roots)
        @test hook("bash_guard.sh", c, r; hooks = hooks_with_roots(String[]; src = hh))[1] == 0
        @test hook("bash_guard.sh", c, r; hooks = hooks_with_roots(String[]; src = hh, required = true))[1] == 2
    end
end
