@testset "evidence.jl (0.2.4)" begin
    summ = """
    Test Summary:  | Pass  Fail  Error  Total   Time
    factory        | 1002     1      1   1004  52.3s
      gen.jl       |  269     1           270   2.7s
    """
    @test Evidence.test_totals(summ) == Dict("pass" => 1002, "fail" => 1, "error" => 1, "broken" => 0, "total" => 1004)
    @test Evidence.test_totals("Test Summary: | Pass  Total  Time\nfactory       | 1006   1006  52.0s\n")["total"] == 1006
    blank = "Test Summary: | Pass  Fail  Error  Total  Time\nfactory       |   10            1     11  1.0s\n"   # an empty Fail column
    @test Evidence.test_totals(blank) == Dict("pass" => 10, "fail" => 0, "error" => 1, "broken" => 0, "total" => 11)
    nested = "Test Summary: | Pass  Total\ninner         |    1      1\nmore\nTest Summary: | Pass  Total\nouter         |    7      7\n"
    @test Evidence.test_totals(nested)["pass"] == 8                           # one table per top-level set: summed
    @test Evidence.test_totals("no summary here") === nothing

    d = tmp_repo(Dict(".gitignore" => "/.lanes/\n", "a.txt" => "x\n"))
    head = readchomp(`git -C $d rev-parse HEAD`)
    ev(args...) = capture(() -> Evidence.main(["--root", d, args...]))
    jl = [Base.julia_cmd().exec; "--startup-file=no"]
    rc, out = ev("tests", "--", jl..., "-e", "using Test; @testset \"t\" begin @test true; @test 1 == 1 end; println(stderr, \"to-stderr\")")
    path = joinpath(d, ".lanes/evidence/tests-$(first(head, 7)).txt")
    @test rc == 0 && isfile(path) && occursin("wrote .lanes/evidence/tests-$(first(head, 7)).txt", out)
    h = Evidence.header(path)
    @test h["head"] == head && h["dirty"] == "false" && h["exit"] == "0" && h["kind"] == "tests"
    @test parse(Float64, h["seconds"]) >= 0 && occursin("-e", h["cmd"]) && h["tests"] == "pass=2 fail=0 error=0 broken=0 total=2"
    @test occursin("to-stderr", Evidence.output(path))                       # stderr is kept with stdout
    @test isempty(read(`git -C $d status --porcelain`, String))               # .lanes/ is ignored: the tree stays clean
    write(joinpath(d, "a.txt"), "dirty\n")
    rc, out = ev("lint", "--", "sh", "-c", "echo boom; exit 3")
    @test rc == 3 && occursin("DIRTY", out)                                   # the command's exit code is evidence.jl's
    h = Evidence.header(joinpath(d, ".lanes/evidence/lint-$(first(head, 7)).txt"))
    @test h["exit"] == "3" && h["dirty"] == "true" && h["cmd"] == "sh -c echo boom; exit 3"
    @test ev("latest", "tests") == (0, ".lanes/evidence/tests-$(first(head, 7)).txt\n")
    sh(`git -C $d checkout -q -- a.txt`)
    commit!(d, Dict("b.txt" => "y\n"), "next")                                # HEAD moved: the ancestor's evidence is the latest
    @test ev("latest", "tests")[1] == 0
    sh(`git -C $d checkout -q -b other "HEAD~1"`); commit!(d, Dict("c.txt" => "z\n"), "side")
    sh(`git -C $d checkout -q main`)
    rc, _ = ev("latest", "nokind")
    @test rc == 1
    @test ev("BAD KIND", "--", "true")[1] == 2 && ev("tests")[1] == 2 && ev("latest", "--", "true")[1] == 2
    @test capture(() -> Evidence.main(["x", "--root", mktempdir(), "--", "true"]))[1] == 2   # not a git checkout
end

@testset "evidence.jl: real Julia summaries (0.2.4 review)" begin
    jl = [Base.julia_cmd().exec; "--startup-file=no"]
    two = "using Test; @testset \"A\" begin for i in 1:5; @test true; end end; @testset \"B\" begin for i in 1:3; @test true; end end"
    for color in ("no", "yes")
        out = read(ignorestatus(`$jl --color=$color -e $two`), String)
        @test Evidence.test_totals(out) == Dict("pass" => 8, "fail" => 0, "error" => 0, "broken" => 0, "total" => 8)
    end
    bad = "using Test; @testset \"A\" begin @test true; @test false; @test error(\"x\"); @test_broken false end"
    out = read(pipeline(ignorestatus(`$jl --color=no -e $bad`); stderr = devnull), String)
    @test Evidence.test_totals(out) == Dict("pass" => 1, "fail" => 1, "error" => 1, "broken" => 1, "total" => 4)
end
