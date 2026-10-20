@testset "lane.jl" begin
    d = tmp_repo(Dict(".gitignore" => "/.worktrees/\nManifest.toml\n", ".agents/agent-registry.toml" => "[lanes]\nmax_open = 2\n"))
    lane(args...) = capture(() -> Lane.main([args..., "--repo", d]))
    @test lane("new", "a")[1] == 0
    @test isdir(joinpath(d, ".worktrees/a"))
    @test readchomp(`git -C $d config branch.feat/a.lane-base`) == "main"
    @test lane("new", "b", "--prefix", "fix")[1] == 0
    rc, _ = lane("new", "c")
    @test rc == 1                                                 # cap of 2 reached
    rc, out = lane("list")
    @test rc == 0 && occursin("2/2", out) && occursin("fix/b", out)
    write(joinpath(d, ".worktrees/a/new.txt"), "x")
    @test lane("remove", "a")[1] == 1                             # dirty
    sh(`git -C $(joinpath(d, ".worktrees/a")) add new.txt`)
    sh(`git -C $(joinpath(d, ".worktrees/a")) commit -q -m lane-work`)
    @test lane("remove", "a")[1] == 1                             # not merged
    sh(`git -C $d merge -q --ff-only feat/a`)
    write(joinpath(d, ".worktrees/a/Manifest.toml"), "ignored\n")
    rc, _ = lane("remove", "a")
    @test rc == 1                                                 # ignored files would be lost
    @test lane("remove", "a", "--allow-ignored")[1] == 0
    @test !isdir(joinpath(d, ".worktrees/a"))
    @test lane("new", "Bad_Name")[1] == 2
    @test lane("remove", "nope")[1] == 1
    # from inside a lane, lanes are still managed in the main checkout
    rc, out = capture(() -> Lane.main(["list", "--repo", joinpath(d, ".worktrees/b")]))
    @test rc == 0 && occursin("lanes in $d", out)
    e = tmp_repo()                                                # .worktrees/ not ignored
    @test capture(() -> Lane.main(["new", "a", "--repo", e]))[1] == 1
end

@testset "lane audit (0.2.4)" begin
    @test Lane.audit(["src/A.jl"], ["src/*"]) == String[]
    @test Lane.audit(["src/A.jl", "docs/x.md"], ["src/*"]) == ["outside owns: docs/x.md"]
    @test Lane.audit(["src/A.jl"], String[]) == ["no owned globs recorded (create the lane with --owns, or pass --owns to audit)"]
    @test Lane.audit(["src/A.jl", "src/B.jl"], ["src/*"], ["src/A.jl", "src/C.jl"]) ==
        ["changed but not reported: src/B.jl", "reported but not changed: src/C.jl"]
    d = tmp_repo(Dict(".gitignore" => "/.worktrees/\n/.lanes/\n", "src/A.jl" => "a\n", "docs/x.md" => "x\n"))
    lane(args...) = capture(() -> Lane.main([args..., "--repo", d]))
    rc, out = lane("new", "aud", "--owns", "src/*, test/a_test.jl")
    @test rc == 0 && occursin("owns: src/* test/a_test.jl changelog.d/aud.md", out)
    @test readchomp(`git -C $d config branch.feat/aud.lane-owns`) == "src/* test/a_test.jl changelog.d/aud.md"
    led = read(joinpath(d, ".lanes/ledger.jsonl"), String)
    @test occursin("\"ev\":\"lane-new\"", led) && occursin("\"owns\":[\"src/*\",\"test/a_test.jl\",\"changelog.d/aud.md\"]", led)
    @test success(pipeline(`jq -e .owns`; stdin = IOBuffer(led), stdout = devnull))
    wt = joinpath(d, ".worktrees/aud")
    fails(out) = [String(m.captures[1]) for m in eachmatch(r"\[FAIL\] (.*)", out)]
    rc, out = lane("audit", "aud")
    @test rc == 0 && occursin("0 changed", out)
    commit!(wt, Dict("src/A.jl" => "b\n", "changelog.d/aud.md" => "- fix: A\n"), "fix: A")
    rc, out = lane("audit", "aud")
    @test rc == 0 && isempty(fails(out)) && occursin("lane audit: OK", out)
    commit!(wt, Dict("docs/x.md" => "y\n"), "docs: out of scope")              # a committed change outside owns
    rc, out = lane("audit", "aud")
    @test rc == 1 && fails(out) == ["outside owns: docs/x.md"]
    sh(`git -C $wt reset -q --soft "HEAD~1"`); sh(`git -C $wt restore -q --staged docs/x.md`); sh(`git -C $wt checkout -q -- docs/x.md`)
    write(joinpath(wt, "notes.txt"), "untracked\n")                          # an untracked file counts too
    rc, out = lane("audit", "aud")
    @test rc == 1 && fails(out) == ["outside owns: notes.txt"]
    rm(joinpath(wt, "notes.txt"))
    sh(`git -C $wt mv src/A.jl src/B.jl`); sh(`git -C $wt commit -q -m mv`)  # a rename inside owns: both paths
    rc, out = lane("audit", "aud")
    @test rc == 0 && occursin("src/A.jl", out) && occursin("src/B.jl", out)
    rep = tempname()
    write(rep, "# changed files\n- `src/A.jl`\n- src/B.jl\n- changelog.d/aud.md\n")
    rc, out = lane("audit", "aud", "--reported", rep)
    @test rc == 0 && !occursin("[info] no --reported", out)
    write(rep, "src/B.jl\nsrc/C.jl\n")                                         # the report differs from the diff
    rc, out = lane("audit", "aud", "--reported", rep)
    @test rc == 1 && fails(out) == [
        "changed but not reported: changelog.d/aud.md", "changed but not reported: src/A.jl",
        "reported but not changed: src/C.jl",
    ]
    @test lane("audit", "aud", "--owns", "docs/*")[1] == 1                      # --owns overrides the recorded globs
    # the 0.2.4 review (M3): a commit reverted in the working tree, or a staged change reverted on disk
    rc, out = lane("new", "rev", "--owns", "src/*")
    wr = joinpath(d, ".worktrees/rev")
    commit!(wr, Dict("docs/x.md" => "evil\n"), "out of scope"); write(joinpath(wr, "docs/x.md"), "x\n")
    rc, out = lane("audit", "rev")
    @test rc == 1 && fails(out) == ["outside owns: docs/x.md"]
    sh(`git -C $wr reset -q --hard "HEAD~1"`)
    write(joinpath(wr, "docs/x.md"), "staged\n"); sh(`git -C $wr add docs/x.md`); write(joinpath(wr, "docs/x.md"), "x\n")
    rc, out = lane("audit", "rev")
    @test rc == 1 && fails(out) == ["outside owns: docs/x.md"]
    sh(`git -C $wr reset -q --hard`)
    commit!(wr, Dict("src/é.jl" => "u\n"), "unicode")                        # m7: non-ASCII names are not C-quoted
    rc, out = lane("audit", "rev")
    @test rc == 0 || (print(out); false)
    @test lane("remove", "rev")[1] == 1
    sh(`git -C $d config branch.feat/rev.lane-base feat/rev`)                  # the review (m7): base rewritten to itself
    rc, out = lane("audit", "rev")
    @test rc == 1 && occursin("its base is its own branch", out)
    sh(`git -C $d config branch.feat/rev.lane-base no-such-branch`)
    rc, out = lane("audit", "rev")
    @test rc == 1 && occursin("is not a commit here", out)
    sh(`git -C $d config branch.feat/rev.lane-base main`)
    @test lane("audit", "nope")[1] == 2
    rc, out = lane("new", "bare")                                               # no --owns: the audit fails closed
    @test rc == 0 && occursin("no --owns given", out)
    commit!(joinpath(d, ".worktrees/bare"), Dict("src/A.jl" => "c\n"), "x")
    rc, out = lane("audit", "bare")
    @test rc == 1 && fails(out) == ["outside owns: src/A.jl"]
    sh(`git -C $d config --unset branch.feat/bare.lane-owns`)
    rc, out = lane("audit", "bare")
    @test rc == 1 && occursin("no owned globs recorded", out)
    rc, out = withenv("JULIA_LOAD_PATH" => "/elsewhere") do                    # env hygiene: leaky variables are named
        lane("new", "envy", "--owns", "x")
    end
    @test rc == 0 && occursin("warning: JULIA_LOAD_PATH=/elsewhere", out)
end

@testset "merge_base: the local base wins when it contains origin/<base> (0.2.6)" begin
    # factory-026 item 3: origin/main behind local main made lane audit and dod.jl count work merged locally, not pushed
    base_ref, merge_base = Lane.base_ref, Lane.merge_base                       # _common.jl, as lane.jl and dod.jl include it
    d = tmp_repo(Dict(".gitignore" => "/.worktrees/\n/.lanes/\n", "README.md" => "x\n"))
    @test base_ref(d, "main") == "main"                                         # no origin at all
    o = joinpath(mktempdir(), "origin.git")
    sh(`git clone -q --bare $d $o`); sh(`git -C $d remote add origin $o`); sh(`git -C $d fetch -q origin`)
    @test base_ref(d, "main") == "main"                                         # equal
    lane(args...) = capture(() -> Lane.main([args..., "--repo", d]))
    commit!(d, Dict("side.md" => "merged locally, not pushed\n"), "side")       # local ahead of origin/main
    @test base_ref(d, "main") == "main" && base_ref(d, "origin/main") == "origin/main"
    @test lane("new", "z", "--owns", "docs/*")[1] == 0
    wt = joinpath(d, ".worktrees/z")
    commit!(wt, Dict("docs/z.md" => "z\n"), "z")
    rc, out = lane("audit", "z")
    @test rc == 0 && !occursin("side.md", out) || (print(out); false)          # 0.2.5: FAIL outside owns: side.md
    @test merge_base(wt, "main") == readchomp(`git -C $d rev-parse main`)
    rc, out = lane("audit", "z", "--base", "origin/main")                       # --base overrides the recorded base
    @test rc == 1 && occursin("outside owns: side.md", out)
    for b in ("feat/z", "HEAD", "feat/z~0")                                     # the review: a base holding the lane's tip audits nothing
        rc, out = lane("audit", "z", "--base", b)
        @test rc == 1 && occursin("already contains the lane's tip", out) || (println("--base $b: ", out); false)
    end
    # the review: an expression or SHA is taken as given, never rewritten to origin/<expr>
    @test base_ref(wt, "HEAD~1") == "HEAD~1" && base_ref(wt, "feat/z~1") == "feat/z~1"
    @test merge_base(wt, "HEAD~1") == readchomp(`git -C $wt rev-parse "HEAD~1"`)
    sh(`git -C $d push -q origin main`); sh(`git -C $d fetch -q origin`)
    @test base_ref(d, "main") == "main"                                         # pushed: equal again
    # local behind origin (someone pushed): origin wins
    c = joinpath(mktempdir(), "c"); sh(`git clone -q $o $c`)
    sh(`git -C $c config user.email t@example.com`); sh(`git -C $c config user.name test`); sh(`git -C $c config commit.gpgsign false`)
    commit!(c, Dict("up.md" => "u\n"), "upstream"); sh(`git -C $c push -q origin main`); sh(`git -C $d fetch -q origin`)
    @test base_ref(d, "main") == "origin/main"
    # review round 2 (N1): with origin/HEAD set and origin ahead, 6fa430d rewrote HEAD~1 to origin/HEAD~1
    sh(`git -C $d remote set-head origin main`)
    @test base_ref(d, "HEAD~1") == "HEAD~1" && merge_base(d, "HEAD~1") == readchomp(`git -C $d rev-parse "HEAD~1"`)
    sh(`git -C $d branch -q -m main old`)                                       # no local main: origin
    @test base_ref(d, "main") == "origin/main" && merge_base(d, "main") !== nothing
end

@testset "merge_base without a tracking ref: origin/<b> falls back to a local <b> (0.2.7)" begin
    # factory-027 item 4: a lane saw "origin/main no longer resolves"; 0.2.6 kept the missing ref and
    # `dod.jl --base origin/main` failed with "no merge base", ratchet.jl skipped its direction check
    base_ref, merge_base = Lane.base_ref, Lane.merge_base
    d = tmp_repo(Dict(".gitignore" => "/.worktrees/\n/.lanes/\n", "README.md" => "x\n"))
    main0 = readchomp(`git -C $d rev-parse main`)
    @test base_ref(d, "origin/main") == "main" && merge_base(d, "origin/main") == main0   # no remote at all
    @test base_ref(d, "origin/nope") == "origin/nope" && merge_base(d, "origin/nope") === nothing   # no local nope either
    @test base_ref(d, "origin/") == "origin/"                                    # degenerate: never "" (HEAD)
    lane(args...) = capture(() -> Lane.main([args..., "--repo", d]))
    @test lane("new", "t", "--owns", "docs/*")[1] == 0
    wt = joinpath(d, ".worktrees/t")
    commit!(wt, Dict("docs/t.md" => "t\n"), "t")
    @test merge_base(wt, "origin/main") == main0                                 # in a lane worktree too
    rc, out = lane("audit", "t", "--base", "origin/main")
    @test rc == 0 && occursin("docs/t.md", out) || (print(out); false)           # 0.2.6: "is not a commit here"
    @test occursin("note: `origin/main` does not resolve here", out)            # review S1: the fallback is visible
    @test Lane.base_note(d, "main") === nothing && Lane.base_note(d, "origin/nope") === nothing
    @test base_ref(d, "origin/main~0") == "main~0"                               # review N1: an expression follows the rule
    # review B1: merged into the local main, `--base origin/main` (no remote) must not audit nothing and pass
    commit!(wt, Dict("src/out_of_scope.jl" => "x\n"), "outside owns")
    sh(`git -C $d merge -q --ff-only feat/t`)
    rc, out = lane("audit", "t", "--base", "origin/main")
    @test rc == 1 && occursin("already contains the lane's tip", out) || (print(out); false)   # 6e579f3: rc 0, 0 changed
    @test lane("audit", "t", "--base", main0)[1] == 1                            # an explicit base before the merge: caught
    @test occursin("outside owns: src/out_of_scope.jl", lane("audit", "t", "--base", main0)[2])
    sh(`git -C $d reset -q --hard $main0`)                                      # undo the merge for what follows
    # a remote whose tracking ref was pruned: origin/main existed, then no longer resolves
    o = joinpath(mktempdir(), "origin.git")
    sh(`git clone -q --bare $d $o`); sh(`git -C $d remote add origin $o`); sh(`git -C $d fetch -q origin`)
    @test base_ref(d, "origin/main") == "origin/main"                            # resolves: taken as given
    sh(`git -C $d update-ref -d refs/remotes/origin/main`)
    @test base_ref(d, "origin/main") == "main" && merge_base(wt, "origin/main") == main0
    @test base_ref(d, "main") == "main"                                          # the plain name: unchanged
end

@testset "lane new: the machine-local file reaches the lane (0.2.6)" begin
    # factory-026 item 1: .agents/factory.local.toml is gitignored, so a new worktree lacked it and a repo with
    # require_read_only_roots = true failed closed on every Bash call there
    d = tmp_repo(Dict(".gitignore" => "/.worktrees/\n/.lanes/\n/.agents/factory.local.toml\n/out.txt\n", "scripts/gen.jl" => "write(\"out.txt\", read(\".agents/factory.local.toml\"))\n"))
    mkpath(joinpath(d, ".agents")); write(joinpath(d, ".agents/factory.local.toml"), "[bash_guard]\nread_only_roots = [\"/x\"]\n")
    rc, out = capture(() -> Lane.main(["new", "loc", "--owns", "x", "--repo", d]))
    wt = joinpath(d, ".worktrees/loc")
    @test rc == 0 && occursin("copied .agents/factory.local.toml", out) && occursin("ran scripts/gen.jl", out)
    @test read(joinpath(wt, ".agents/factory.local.toml"), String) == read(joinpath(d, ".agents/factory.local.toml"), String)
    @test isfile(joinpath(wt, "out.txt"))                                       # gen.jl ran in the lane
    commit!(d, Dict("scripts/gen.jl" => "exit(3)\n"), "broken gen")
    rc, out = capture(() -> Lane.main(["new", "bad", "--owns", "x", "--repo", d]))
    @test rc == 0 && occursin("warning: scripts/gen.jl failed", out)            # warns; the lane exists
    rm(joinpath(d, ".agents/factory.local.toml"))
    rc, out = capture(() -> Lane.main(["new", "none", "--owns", "x", "--repo", d]))
    @test rc == 0 && !occursin("copied", out) && !isfile(joinpath(d, ".worktrees/none/.agents/factory.local.toml"))
end
