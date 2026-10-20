# bash_guard cases from the guard-rereview security review (factory 0.2.3). Split from
# test_hooks.jl (whose helpers hook, bash, blocked, hooks_with_roots and REF_ROOTS it uses) to
# keep both under the 400-line scripts budget of ratchets.toml.
@testset "hooks: bash_guard guard-rereview" begin
    root = realpath(mktempdir())
    @testset "bash_guard: guard-rereview bypasses (0.2.3)" begin
        # ⏎ is a newline and “ a double quote; raw strings keep $ and \ literal. All but three gave rc 0 on 0.2.2.
        nl(c) = replace(c, "⏎" => "\n", "“" => "\"")
        gb(c; hooks = TEST_HOOKS) = hook("bash_guard.sh", bash(nl(c); cwd = root), root; hooks)[1]
        cases = [
            # M1: TMPDIR reassigned without `=`; a literal $TMPDIR/... is never a relative path
            raw"unset TMPDIR; rm -rf $TMPDIR/opt", raw"unset TMPDIR && rm -rf “$TMPDIR“/Users",
            raw"printf -v TMPDIR /; rm -rf $TMPDIR/opt", raw"read TMPDIR < f; rm -rf $TMPDIR/opt",
            raw"for TMPDIR in /; do :; done; rm -rf $TMPDIR/opt", raw"rm -r $TMPDIR/../../../../opt",
            # M2: keywords, wrappers, quoted or escaped names, find -exec/-delete, xargs
            "if [ -d build ]; then rm -rf build; fi", raw"for d in build dist; do rm -rf $d; done",
            "if rm -rf /opt/x; then :; fi", "while rm -rf /opt/x; do :; done", "until rm -rf /opt/x; do :; done",
            "! rm -rf /opt/x", "else rm -rf /opt/x", "elif rm -rf /opt/x; then :; fi", "{ rm -rf /opt/x; }",
            "exec rm -rf /opt/x", "nohup rm -rf /opt/x", "timeout 5 rm -rf /opt/x", "timeout -s KILL 5 rm -rf /opt/x",
            "doas rm -rf /opt/x", "builtin rm -rf /opt/x", "caffeinate rm -rf /opt/x", "caffeinate -t 5 rm -rf /opt/x",
            "sudo -u root rm -rf /opt/x", "sudo -E -u root nice -n 5 rm -rf /opt/x",
            "xargs rm -rf /opt/x", "xargs -0 -I {} rm -rf /opt/x", "ls | xargs rm -rf",
            "find . -name node_modules -exec rm -rf {} +", raw"find . -exec true \; -exec rm -rf /opt/x \;",
            "find /opt -delete", "find /opt -name x -fprint /opt/list",
            raw"\rm -rf /opt/x", "'rm' -rf /opt/x", "\"rm\" -rf /opt/x", raw"r\m -rf /opt/x",
            raw"rm${IFS}-rf${IFS}/opt/x", raw"$RM -rf /opt/x", "`echo rm` -rf /opt/x",
            "rm -rf /private/tmp/claude-501/p/s/x `pwd`", "eval rm -rf /opt/x", "eval \"rm -rf /opt/x\"",
            "echo x | 'tee' /opt/x", raw"echo x | \tee /opt/x", "echo x | if true; then tee /opt/x; fi",
            "echo x | xargs touch /opt/x",
            # M3: a false heredoc start must not hide later lines
            "echo 'see <<EOF'⏎git reset --hard", "echo \"a <<EOF\"⏎rm -rf /opt/x", "# note <<EOF⏎rm -rf /opt/x",
            "cat <<<EOF⏎rm -rf /opt/x", raw"echo $((1<<FOO))⏎rm -rf /opt/x", raw"echo “$((1<<FOO))“⏎rm -rf /opt/x",
            "(( x<<FOO ))⏎rm -rf /opt/x", "cat <<EOF \"⏎\"; rm -rf /opt/x⏎EOF", "cat <<NEVER⏎rm -rf /opt/x",
            # m1: writes through tools that were not modelled
            "sed -i '' 's/a/b/' /opt/x", "sed -i.bak s/a/b/ /opt/x", "sed -i -e s/a/b/ /opt/x",
            "perl -pi -e 's/a/b/' /opt/x", "perl -i.bak -pe 's/a/b/' /opt/x", "cp -t /opt a",
            "cp --target-directory=/opt a", "install -t /opt a", "echo x >| /opt/x", "echo x >|/opt/x",
            raw"echo x >“$HOME“/x", "curl -o /opt/x http://e", "curl --output=/opt/x http://e",
            "wget -O /opt/x http://e", "tar -xf a.tar -C /opt", "tar xzf a.tgz --directory=/opt",
            "unzip a.zip -d /opt", "git clone x /opt/x", "git init /opt/x", "git worktree add /opt/x",
            "git worktree add -b b /opt/x", "git --git-dir /opt/x/.git commit -m m",
            "git --git-dir /opt/x/.git reset --hard", "\"git\" reset --hard", "git push \"--force\"",
            # m3: backslash-newline continuation
            "rm \\⏎-rf /opt/x", "git reset \\⏎--hard",
            # the 0.2.3 reviewer: long and late clean flags, commit -n (= --no-verify)
            "git clean --force", "git clean -d --force", "git clean -x -d -f", "git commit -nm x", "git commit -n -m x",
            "git commit -an", "git commit -m x -n",
        ]
        for c in cases
            @test gb(c) == 2 || (println("not blocked: $(nl(c))"); false)
        end
        # m2: --git-dir / --work-tree name the repository, like -C
        h = hooks_with_roots(REF_ROOTS)
        mt = expanduser("~/ro-fixture/ref-a")
        for c in (
                "git --git-dir ~/ro-fixture/ref-a/.git checkout .", "git --git-dir=$mt/.git checkout .",
                "git --work-tree=$mt checkout .", "git --work-tree $mt checkout .",
            )
            @test gb(c; hooks = h) == 2 || (println("not blocked: $c"); false)
        end
        @test gb("git --git-dir ~/ro-fixture/ref-a/.git log -1"; hooks = h) == 0
        # must not regress: the commands guard-rereview listed as passing, and more
        allow = [
            "git commit -m \"fix: don't split on ; or | in messages\"", raw"git commit -m 'it'“'“'s fine; really > ok'",
            raw"git commit -m “feat(x): add > and < handling“ -m “Body with 'quotes' and \“escapes\““",
            "git commit -m \"rm -rf build is blocked\"", "git commit -m \"mention git reset --hard in text\"",
            "git commit -m \"docs: git push needs approval\"", "git log --format='%H %s' -5", "git log --oneline | head -5",
            "git diff main...HEAD -- src/ > /dev/null", "julia -e 'println(\"a > b; c\")'",
            "julia --project=. -e 'using Pkg; Pkg.test()'", raw"julia --startup-file=no -e “x = 1 > 0 ? \“y\“ : \“n\“; println(x)“",
            "gh pr view 12 --json title,body", "gh pr list --state open", "gh api repos/o/r/pulls --jq '.[].title'",
            "gh run view 123 --log-failed", "gh issue list --label bug", "sed -n '1,20p' file.jl",
            "sed -e 's/a|b/c/g' f > out.txt", "sed -i '' -e 's/<Package>/X/g' f", "grep -E 'a|b|c' f | sort | uniq -c",
            "awk -F'|' '{print \$1 > \"/dev/stderr\"}' f", raw"echo “$(date)“ > notes.txt", "ls 2>&1 | head",
            "cmd 2>/dev/null || true", "rm -r build", "rm build/x.txt", "mkdir -p .worktrees/a && touch .worktrees/a/x",
            "find . -name '*.jl' -exec grep -l foo {} +", "echo 'a#b' ; echo \"c # d\"", raw"printf '%s\n' “it's“ > x.txt",
            "git stash push -m \"lane-a wip\"", "julia -e 'run(`ls`)'", "echo ok # don't worry", "cd /tmp && ls",
            "diff <(sort a) <(sort b)", raw"echo $((1 > 0))", "[ 1 -gt 0 ] && echo yes", "test -f a || echo no > log.txt",
            "cat ~/ro-fixture/ref-a/README.md", "rg foo ~/ro-fixture/ref-a",
            # the commit idiom, real heredocs, continuations and the new wrappers
            "git commit -m \"\$(cat <<'EOF'⏎feat: x⏎⏎rm -rf /opt/x; git reset --hard⏎EOF⏎)\"",
            "cat > notes.md <<'EOF'⏎rm -rf /⏎EOF", "cat <<-EOF⏎\tgit reset --hard⏎\tEOF", "cat <<A <<B⏎a⏎A⏎b⏎B⏎ls",
            raw"echo $((1 << 2))", "echo \"a \\⏎b\"", "ls \\⏎-la", "sed -i '' '/^#/d' f.txt", "sed -i -e '/^#/d' f.txt",
            "sed -n '/^#/p' /opt/x", "perl -ne 'print' /opt/x", "cp /opt/x ./y", "curl -sSL http://e -o out.txt",
            "tar -czf out.tgz -C src .", "tar -tf /opt/a.tar", "git clone https://github.com/o/r",
            "git clone https://github.com/o/r sub/r", "git worktree list", "find build -name '*.tmp' -delete", "find /opt -name x",
            raw"find . -type f -exec grep -l foo {} \;", "timeout 60 julia --project=. -e 1", "xargs -n1 echo < list.txt",
            "sudo -n true", "if [ -f a ]; then echo yes; fi", raw"for f in *.jl; do echo “$f“; done",
            raw"while read -r l; do echo “$l“; done < f", "echo `date` > out.txt", raw"x=$(git rev-parse HEAD) && echo “$x“",
            "nohup julia x.jl > log.txt 2>&1 &", "{ echo a; echo b; } > out.txt", "echo x >| out.txt",
            "git clean -n", "git clean --dry-run -d", "git commit -m x", "git commit -am \"fix: not -n here\"",
            "git commit -m fix-nothing", "git commit --amend --no-edit", "git commit -mrun",
        ]
        for c in allow
            @test gb(c) == 0 || (println("blocked: $(nl(c)) ", hook("bash_guard.sh", bash(nl(c); cwd = root), root)[3]); false)
        end
        @test gb("echo " * "a"^70000) == 2 && gb("echo " * "a"^60000) == 0  # > 64 KiB: could outlast the timeout
        push = Dict("FACTORY_ALLOW_PUSH" => "1")
        @test !blocked("bash_guard.sh", bash("git push --force-with-lease"), root; env = push)
        @test blocked("bash_guard.sh", bash("git push \"--force\""), root; env = push)  # 0.2.2: the quotes hid it
    end

    @testset "bash_guard: T3 paths are protected from Bash writes too (0.2.4)" begin
        # 0.2.3 gave rc 0 for all of these: T3 was guarded only for Edit/Write (write_guard)
        nl(c) = replace(c, "⏎" => "\n")
        r = realpath(mktempdir())
        mkpath(joinpath(r, "scripts/test")); write(joinpath(r, "risk.toml"), "x\n")
        lane = joinpath(r, ".worktrees/l1"); mkpath(lane); write(joinpath(lane, ".git"), "gitdir: x\n")
        # hermetic: the checkout's own list (a coordinator's seeded risk.toml) may differ from the template's
        mkpath(joinpath(r, ".claude/hooks"))
        write(
            joinpath(r, ".claude/hooks/protected-paths.txt"), "# fixture\nT3 .github/workflows/*\nT3 .claude/settings.json\nT3 .claude/hooks/*\n" *
                "T3 .agents/checks.toml\nT3 scripts/dod.jl\nT3 scripts/gen.jl\nT3 scripts/ci.jl\nT3 scripts/test/*\nT3 risk.toml\nT3 ratchets.toml\nT2 Project.toml\n"
        )
        pkg = joinpath(r, "Pkg.jl"); mkpath(joinpath(pkg, ".claude/hooks")); write(joinpath(pkg, ".git"), "gitdir: x\n")
        write(joinpath(pkg, ".claude/hooks/protected-paths.txt"), "T3 src/Secret.jl\n")      # its own list
        t3(c; env = Dict{String, String}(), cwd = r) = hook("bash_guard.sh", bash(c; cwd), r; env)
        deny = [
            "sed -i '' s/T3/T0/ risk.toml", "printf x > scripts/dod.jl", "rm scripts/test/test_dod.jl",
            "echo x >> risk.toml", "echo x | tee -a .claude/hooks/bash_guard.sh", "cp /tmp/x scripts/ci.jl",
            "mv scripts/gen.jl /tmp/", "install -m 644 /tmp/x scripts/dod.jl", "ln -sf /tmp/x ratchets.toml",
            "truncate -s 0 risk.toml", "touch .agents/checks.toml", "dd if=/dev/zero of=risk.toml count=1",
            "perl -pi -e s/a/b/ risk.toml", "sed --in-place=.bak -e s/a/b/ .github/workflows/CI.yml",
            "cat > risk.toml <<'EOF'⏎x⏎EOF", "echo x > RISK.TOML", "echo x > ./scripts/../risk.toml",
            "cd scripts && rm dod.jl", "cd scripts/test; echo x > test_dod.jl", "chmod -R 000 scripts",
            "rm -r scripts", "rm -r .github", "mv .claude /tmp/c", "rmdir scripts/test", "find . -name '*.jl' -delete",
            "find scripts -delete", "cp -r /tmp/x/. .", "cp /tmp/dod.jl scripts/", "tar -xf /tmp/a.tar -C .",
            "unzip /tmp/a.zip -d scripts", "rsync -a /tmp/x/ ./", "curl -o risk.toml http://e", "wget -O risk.toml http://e",
            "git rm risk.toml", "git mv scripts/dod.jl x.jl", "git restore risk.toml",
            "git checkout HEAD~1 -- risk.toml", "git checkout HEAD~1 risk.toml", "git -C scripts checkout -- dod.jl",
            "echo x > .worktrees/l1/risk.toml", "echo x > Pkg.jl/src/Secret.jl", "mv Pkg.jl /tmp/p",
            "FACTORY_ALLOW_T3=1 sed -i '' s/a/b/ risk.toml", "if true; then echo x > risk.toml; fi",
            "find . -name x -exec cp /tmp/y risk.toml +",
        ]
        for c in deny
            rc, _, err = t3(nl(c))
            @test (rc == 2 && (occursin("T3", err) || occursin("own T3 paths", err))) || (println("not blocked (T3): $(nl(c)) rc=$rc $err"); false)
        end
        allow = [
            "sed -i '' s/a/b/ src/A.jl", "echo x > notes.md", "rm -r build", "cat risk.toml", "cp risk.toml /tmp/x",
            "grep T3 risk.toml > /tmp/x", "mkdir -p scripts/test", "touch scripts/new_tool.jl", "git add risk.toml",
            "git checkout main", "git checkout -b feat/x", "git diff -- risk.toml", "julia scripts/gen.jl",
            "git rm build.log", "git rm -r --cached scripts", "echo x > Pkg.jl/risk.toml", "echo x > .worktrees/l1/notes.md", "cp a.txt docs/",
            "git commit -m \"git rm risk.toml\"", "git log -- scripts/dod.jl > /tmp/log",
        ]
        for c in allow
            rc, _, err = t3(c)
            @test rc == 0 || (println("blocked (T3): $c $err"); false)
        end
        # the override is the session env, as for write_guard; an inline assignment does not reach the hook
        @test t3("printf x > scripts/dod.jl"; env = Dict("FACTORY_ALLOW_T3" => "1"))[1] == 0
        @test t3("rm -r scripts"; env = Dict("FACTORY_ALLOW_T3" => "1"))[1] == 0
        # no protected-paths.txt anywhere: a write inside the repo fails closed, the rest still runs
        h = hooks_with_roots(String[]); rm(joinpath(h, "protected-paths.txt"))
        r2 = realpath(mktempdir())
        nolist(c) = hook("bash_guard.sh", bash(c; cwd = r2), r2; hooks = h)
        @test nolist("echo x > notes.md")[1] == 2 && occursin("protected-paths.txt is missing", nolist("echo x > notes.md")[3])
        @test nolist("ls -la")[1] == 0 && nolist("echo x > /tmp/f")[1] == 0
    end

    @testset "guards fail CLOSED on a payload they cannot read (0.2.4)" begin
        r = realpath(mktempdir())
        for p in ("garbage", "{\"tool_input\":", "[1,2]", "\"str\"")
            @test hook("bash_guard.sh", p, r)[1] == 2 || (println("bash_guard allowed payload $p"); false)
            @test hook("write_guard.sh", p, r)[1] == 2 || (println("write_guard allowed payload $p"); false)
        end
        @test hook("write_guard.sh", "{}", r)[1] == 2                          # no target key: cannot check
        @test hook("write_guard.sh", "{\"tool_name\":\"Write\",\"tool_input\":{\"content\":\"x\"}}", r)[1] == 2
        @test hook("write_guard.sh", write_payload("/opt/x"; key = "path"), r)[1] == 2   # 0.2.3: the `path` key was ignored
        @test hook("write_guard.sh", write_payload("$r/risk.toml"; key = "path"), r)[1] == 2
        @test hook("write_guard.sh", write_payload("$r/src/a.jl"; key = "path"), r)[1] == 0
        for p in ("{}", "{\"tool_input\":{}}", "{\"tool_input\":{\"command\":123}}", "{\"tool_input\":{\"command\":[\"rm risk.toml\"]}}")
            @test hook("bash_guard.sh", p, r)[1] == 2 || (println("bash_guard allowed payload $p"); false)   # no command string
        end
        @test hook("bash_guard.sh", "{\"tool_input\":{\"command\":\"\"}}", r)[1] == 0   # an empty command runs nothing
        @test hook("write_guard.sh", "{\"tool_input\":{\"file_path\":123}}", r)[1] == 2
        @test hook("write_guard.sh", "{\"tool_input\":{\"file_path\":[\"$r/risk.toml\"]}}", r)[1] == 2
    end

    @testset "the 0.2.4 review's bypasses (each was rc 0 before its fix)" begin
        r = realpath(mktempdir())
        mkpath(joinpath(r, ".claude/hooks")); mkpath(joinpath(r, "scripts/test"))
        write(joinpath(r, ".claude/hooks/protected-paths.txt"), "T3 .claude/settings.json\nT3 .claude/hooks/*\nT3 scripts/dod.jl\nT3 scripts/test/*\nT3 risk.toml\n")
        for f in ("risk.toml", "scripts/dod.jl", "scripts/test/t.jl", ".claude/settings.json")
            write(joinpath(r, f), "x\n")
        end
        rv(c; root = r) = hook("bash_guard.sh", bash(c; cwd = root), root)
        deny = [# M2: glob characters (the shell expands them; the guard now does too) and brace lists
            "rm risk.tom?", "rm scripts/dod.j*", "rm scripts/[d]od.jl", "rm -r scripts/tes?", "rm {risk,x}.toml",
            "printf x > risk.tom?",
            # M4: $'...' / $"..." quoting, ~+ and ~-, x->f redirects, git's -C/--git-dir, env -C, rsync, find -exec
            raw"rm $'risk.toml'", raw"rm $\"risk.toml\"", raw"printf x > $'risk.toml'", "rm ~+/risk.toml", "rm ~-/x",
            "printf x->risk.toml", "printf x-> risk.toml", "git --git-dir=.git rm risk.toml",
            "git --work-tree=. --git-dir=.git rm risk.toml", "git -C scripts -C test rm t.jl", "env -C scripts rm dod.jl",
            "rsync a scripts/dod.jl -q", "find . -name t.jl -exec rm {} +", raw"find scripts -exec cp /tmp/x {} \;",
            # M1: .git markers and .git internals; suspected: GNU names, git aliases
            "touch .git/hooks/pre-commit", "mkdir scripts/.git", "touch .claude/.git", "gsed -i s/a/b/ risk.toml",
            "grm risk.toml", "gtimeout 5 rm risk.toml", "git -c alias.nuke=rm nuke risk.toml",
            # re-verification (N1): unzip without -d and tar -x without -C extract into the cwd
            "unzip -o /tmp/a.zip", "tar -xf /tmp/a.tar", "cd scripts && unzip -o /tmp/a.zip", "tar xzf /tmp/a.tgz",
        ]
        for c in deny
            rc, _, err = rv(c)
            @test rc == 2 || (println("not blocked (review): $c rc=$rc"); false)
        end
        allow = [# m6: into a directory means DIR/<source name>; the index-only git forms touch no file
            "cp /tmp/notes.md .", "mv /tmp/notes.md .", "cp -r /tmp/docs ./docs-copy", "git restore --staged risk.toml",
            "git rm --cached scripts/test/t.jl", "rm build/*.o", "find . -name '*.jl' -exec grep -l foo {} +",
            "ls *.md > /tmp/x", "git -C scripts log -1", "unzip -o /tmp/a.zip -d build", "tar -xf /tmp/a.tar -C build",
            "cd /tmp && unzip -o a.zip", "printf '%s' 'a->b' > notes.md",
        ]
        for c in allow
            rc, _, err = rv(c)
            @test rc == 0 || (println("blocked (review): $c $err"); false)
        end
        @test rv("cp -r /tmp/scripts .")[1] == 2                               # DIR/scripts holds T3 paths
        # M1: a bare `.git` marker does not make a directory a checkout with no T3 paths (both guards)
        mkpath(joinpath(r, "scripts/.git")); write(joinpath(r, ".claude/.git"), "")
        @test rv("printf x > scripts/dod.jl")[1] == 2 && rv("printf x > .claude/settings.json")[1] == 2
        @test hook("write_guard.sh", write_payload("$r/scripts/dod.jl"), r)[1] == 2
        @test hook("write_guard.sh", write_payload("$r/.claude/settings.json"), r)[1] == 2
        # a real nested checkout is checked against its own list AND the root's
        n = joinpath(r, "Pkg.jl"); mkpath(joinpath(n, ".claude/hooks")); write(joinpath(n, ".git"), "gitdir: /x\n")
        write(joinpath(n, ".claude/hooks/protected-paths.txt"), "T3 src/Secret.jl\n")
        write(joinpath(r, ".claude/hooks/protected-paths.txt"), "T3 risk.toml\nT3 Pkg.jl/ci.yml\n")
        @test rv("echo x > Pkg.jl/src/Secret.jl")[1] == 2 && rv("echo x > Pkg.jl/ci.yml")[1] == 2 && rv("echo x > Pkg.jl/a.jl")[1] == 0
        @test hook("write_guard.sh", write_payload("$n/ci.yml"), r)[1] == 2
        # m1: write_guard with no protected-paths.txt anywhere fails closed (0.2.3: rc 0)
        h = hooks_with_roots(String[]); rm(joinpath(h, "protected-paths.txt"))
        r2 = realpath(mktempdir())
        @test hook("write_guard.sh", write_payload("$r2/risk.toml"), r2; hooks = h)[1] == 2
        @test hook("write_guard.sh", write_payload("/tmp/scratch.md"), r2; hooks = h)[1] == 0   # outside the root: no list needed
        h2 = joinpath(mktempdir(), "hooks"); cp(TEST_HOOKS, h2); rm(joinpath(h2, "_bash_guard_write.sh"))
        rc, _, err = hook("write_guard.sh", write_payload("$r2/a.jl"), r2; hooks = h2)
        @test rc == 2 && occursin("missing", err)
    end

    @testset "lane worktrees: T3 paths under .worktrees/*/ and .claude/worktrees/*/ (0.2.6)" begin
        # factory-026 item 2: `scripts/lane new y && cp .agents/factory.local.toml .worktrees/y/.agents/` was rc 0:
        # the worktree did not exist yet when the hook ran, so the path was matched against the root's globs only
        r = tmp_repo(Dict(".gitignore" => "/.worktrees/\n/.claude/worktrees/\n", "README.md" => "x\n"))
        mkpath(joinpath(r, ".claude/hooks"))
        write(joinpath(r, ".claude/hooks/protected-paths.txt"), "T3 .agents/factory.local*\nT3 scripts/dod.jl\nT3 risk.toml\n")
        rv(c; root = r, cwd = r) = hook("bash_guard.sh", bash(c; cwd), root)
        for c in (
                "scripts/lane new y && cp .agents/factory.local.toml .worktrees/y/.agents/",
                "scripts/lane new y && cp .agents/factory.local.toml .worktrees/y/.agents/factory.local.toml",
                "git worktree add .claude/worktrees/w && cp .agents/factory.local.toml .claude/worktrees/w/.agents/",
                "scripts/lane new y && echo x > .worktrees/y/scripts/dod.jl", "printf x > .worktrees/y/risk.toml",
                "cd .worktrees/y && cp ../../.agents/factory.local.toml .agents/", "mv /tmp/x .claude/worktrees/w/risk.toml",
            )
            rc, _, err = rv(c)
            @test (rc == 2 && occursin("T3", err)) || (println("not blocked (lane T3): $c rc=$rc"); false)
        end
        for c in ("scripts/lane new y && cp /tmp/notes.md .worktrees/y/docs/", "echo x > .worktrees/y/notes.md", "cp a.md .worktrees/new/")
            rc, _, err = rv(c)
            @test rc == 0 || (println("blocked (lane T3): $c $err"); false)
        end
        @test hook("write_guard.sh", write_payload("$r/.worktrees/y/.agents/factory.local.toml"), r)[1] == 2
        # item 4: a session rooted in a lane worktree may write a sibling sub-lane (`scripts/lane new` from inside a lane
        # makes <main>/.worktrees/<sub>), but its T3 paths stay protected; MAIN is read from the lane's .git file
        sh(`git -C $r worktree add -q -b feat/x $(joinpath(r, ".worktrees/x"))`)
        sh(`git -C $r worktree add -q -b feat/s $(joinpath(r, ".worktrees/s"))`)
        x, s = joinpath(r, ".worktrees/x"), joinpath(r, ".worktrees/s")
        @test hook("write_guard.sh", write_payload("$s/notes.md"), x)[1] == 0
        @test hook("write_guard.sh", write_payload("$s/scripts/dod.jl"), x)[1] == 2    # rc 0 before 0.2.6 (only /tmp allowed it)
        @test rv("echo x > risk.toml"; root = x, cwd = s)[1] == 2 && rv("echo x > notes.md"; root = x, cwd = s)[1] == 0
        # in_main: the lane worktrees and reports of MAIN are in-repo; MAIN's own files are not (both spellings)
        lib = joinpath(TEST_HOOKS, "_lib.sh")
        function inmain(p; root = x)
            script = ". '$lib'; in_main '$p' && echo \"in \$IN_MAIN\" || echo out"
            return readchomp(pipeline(addenv(`sh -c $script`, "CLAUDE_PROJECT_DIR" => root); stdin = devnull))
        end
        @test inmain("$r/.worktrees/s/a.md") == "in $r" && inmain("$r/.claude/worktrees/w/a.md") == "in $r"
        @test inmain("$r/.lanes/reports/x.md") == "in $r"
        @test inmain("$r/notes.md") == "out" && inmain("$r/.lanes/ledger.jsonl") == "out" && inmain("$r/.worktrees") == "out"
        @test inmain("$r/.worktrees/s/a.md"; root = r) == "out"                               # the main checkout's session: no MAIN
        @test inmain("/opt/x/.worktrees/s/a.md") == "out"
        # the review: MAIN is trusted only when git's record of the worktree points back at the root (a crafted .git file)
        forged = realpath(mktempdir()); write(joinpath(forged, ".git"), "gitdir: $r/.git/worktrees/x\n")
        @test inmain("$r/.worktrees/s/a.md"; root = forged) == "out"
        fake = realpath(mktempdir()); write(joinpath(fake, ".git"), "gitdir: /opt/evil/.git/worktrees/n\n")
        @test inmain("/opt/evil/.worktrees/n/a.md"; root = fake) == "out" && inmain("/opt/evil/.lanes/reports/a.md"; root = fake) == "out"
        # end to end OUTSIDE the scratch dirs (every path below /tmp or \$TMPDIR is allowed anyway): a repo under
        # this checkout's gitignored .lanes/, skipped when the checkout itself is in a scratch dir (a /tmp clone)
        nt = joinpath(ROOT, ".lanes", "nontmp-$(getpid())")
        scratch = ("/tmp/", "/private/tmp/", "/var/folders/", "/private/var/folders/", rstrip(get(ENV, "TMPDIR", "/nonexistent"), '/') * "/")
        if any(p -> startswith(nt, p), scratch)
            @info "lane-worktree write_guard tests outside /tmp skipped: this checkout is in a scratch dir ($nt)"
        else
            try
                mkpath(nt); sh(`git -C $nt init -q -b main`); sh(`git -C $nt -c user.email=t@e -c user.name=t commit -q --allow-empty -m init`)
                sh(`git -C $nt worktree add -q -b feat/x $(joinpath(nt, ".worktrees/x"))`)
                sh(`git -C $nt worktree add -q -b feat/s $(joinpath(nt, ".worktrees/s"))`)
                wg(p) = hook("write_guard.sh", write_payload(p), joinpath(nt, ".worktrees/x"))[1]
                @test wg("$nt/.worktrees/s/docs/a.md") == 0 && wg("$nt/.claude/worktrees/w/a.md") == 0   # item 4: rc 2 in 0.2.5
                @test wg("$nt/.lanes/reports/x.md") == 0                                                 # item 5: rc 2 in 0.2.5
                @test wg("$nt/notes.md") == 2 && wg("$nt/.lanes/ledger.jsonl") == 2 && wg("$nt/.worktrees/s/scripts/dod.jl") == 2
                @test hook("bash_guard.sh", bash("touch docs/a.md"; cwd = "$nt/.worktrees/s"), joinpath(nt, ".worktrees/x"))[1] == 0
                @test hook("bash_guard.sh", bash("touch ../../notes.md"; cwd = "$nt/.worktrees/s"), joinpath(nt, ".worktrees/x"))[1] == 2
            finally
                sh(`git -C $nt worktree prune`); rm(nt; recursive = true, force = true)
            end
        end
    end
end
