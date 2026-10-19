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
