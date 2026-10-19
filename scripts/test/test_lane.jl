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
    @test rc == 1 && fails(out) == ["changed but not reported: changelog.d/aud.md", "changed but not reported: src/A.jl",
                                    "reported but not changed: src/C.jl"]
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
