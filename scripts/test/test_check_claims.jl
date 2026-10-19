@testset "check_claims.jl (0.2.4)" begin
    cs = CheckClaims.claims("a 6 <!-- claim: max_open=6 -->\n`<!-- claim: max_open=9 -->` example\n```\n<!-- claim: roles=1 -->\n```\nv <!-- claim: x=1 y=2 evidence=e -->\n")
    @test [(c[1], c[2]) for c in cs] == [(1, ["max_open" => "6"]), (6, ["x" => "1", "y" => "2", "evidence" => "e"])]
    reg = "version = 1\n[lanes]\nmax_open = 6\n[[agents]]\nslug = \"a\"\n[[agents]]\nslug = \"b\"\n"
    rat = "[[size]]\nglob = \".claude/hooks/*.sh\"\nmax_lines = 150\n"
    files = Dict(".gitignore" => "/.lanes/\n", ".agents/agent-registry.toml" => reg, "ratchets.toml" => rat,
                 ".factory-version" => "version = \"0.2.4\"\nprofile = \"package\"\n",
                 "HANDOFF.md" => "The lane cap is 6 <!-- claim: max_open=6 -->; 2 roles <!-- claim: roles=2 -->.\n" *
                                 "Factory 0.2.4 <!-- claim: factory_version=0.2.4 -->, hooks <= 150 lines <!-- claim: max_lines:.claude/hooks/*.sh=150 -->\n")
    d = tmp_repo(files)
    run_cc(args...) = capture(() -> CheckClaims.main([args..., "--root", d]))
    fails(out) = [String(m.captures[1]) for m in eachmatch(r"\[FAIL\] (.*)", out)]
    rc, out = run_cc()
    @test rc == 0 && occursin("OK (4 claims", out)
    # the live drift: prose and marker say 4, the registry says 6
    write(joinpath(d, "HANDOFF.md"), "The lane cap is 4 <!-- claim: max_open=4 -->\n")
    rc, out = run_cc()
    @test rc == 1 && fails(out) == ["HANDOFF.md:1: max_open=4 but the derived value is 6"]
    write(joinpath(d, "HANDOFF.md"), "The lane cap is 4 <!-- claim: max_open=6 -->\n")   # marker right, prose stale
    rc, out = run_cc()
    @test rc == 1 && fails(out) == ["HANDOFF.md:1: the text of the line does not state 6 (claimed by `max_open`)"]
    write(joinpath(d, "HANDOFF.md"), "x 16 <!-- claim: max_open=6 --> <!-- claim: bogus=1 --> <!-- claim: roles -->\n")
    rc, out = run_cc()
    @test rc == 1 && length(fails(out)) == 3 && occursin("does not state 6", out) && occursin("unknown claim key `bogus`", out) &&
          occursin("`roles` has no value", out)
    write(joinpath(d, "HANDOFF.md"), "6 <!-- Claim: max_open=6 -->\n6 <!--claim max_open=6-->\n`<!-- Claim: x -->` is an example\n")
    rc, out = run_cc()                                                         # the review: mistyped markers were ignored
    @test rc == 1 && length(fails(out)) == 2 && all(f -> occursin("malformed claim marker", f), fails(out))
    write(joinpath(d, "HANDOFF.md"), "nothing claimed\n")
    write(joinpath(d, ".agents/factory.toml"), "version = 1\n[check_claims]\nfiles = [\"HANDOFF.md\"]\nrequired = [\"max_open\"]\n")
    rc, out = run_cc()                                                         # a required key with no marker
    @test rc == 1 && fails(out) == ["required claim `max_open` ([check_claims] in .agents/factory.toml) has no marker in the configured files"]
    write(joinpath(d, "OTHER.md"), "The cap is 6 <!-- claim: max_open=6 -->\n")   # outside `files`: not counted
    @test run_cc()[1] == 1
    write(joinpath(d, ".agents/factory.toml"), "version = 1\n[check_claims]\nrequired = [\"nope\"]\n")
    rc, out = run_cc()
    @test rc == 1 && occursin("required key `nope` is unknown", out)
    write(joinpath(d, ".agents/factory.toml"), "version = 1\n[check_claims]\nfile = []\n")   # a typo is an error, not a no-op
    @test run_cc()[1] == 2
    rm(joinpath(d, ".agents/factory.toml")); rm(joinpath(d, "OTHER.md"))
    # a nested checkout (the coordinator's factory/template) is checked against its own registry
    commit!(d, Dict("factory/template/.agents/agent-registry.toml" => "version = 1\n[lanes]\nmax_open = 4\n",
                    "factory/template/CLAUDE.md" => "At most 4 lanes <!-- claim: max_open=4 -->\n"), "nested")
    rc, out = run_cc()
    @test rc == 0 || (print(out); false)
    write(joinpath(d, "factory/template/CLAUDE.md"), "At most 6 lanes <!-- claim: max_open=6 -->\n")
    rc, out = run_cc()
    @test rc == 1 && fails(out) == ["factory/template/CLAUDE.md:1: max_open=6 but the derived value is 4"]
    write(joinpath(d, "factory/template/CLAUDE.md"), "At most 4 lanes <!-- claim: max_open=4 -->\n")
    # test totals come from the evidence file for HEAD (scripts/evidence.jl)
    write(joinpath(d, "HANDOFF.md"), "Tests: 2/2 <!-- claim: tests_pass=2 tests_total=2 -->\n")
    rc, out = run_cc()
    @test rc == 0 && occursin("UNVERIFIED", out) && occursin("2 unverified", out)     # no evidence on this machine
    @test run_cc("--strict")[1] == 1
    jl = [Base.julia_cmd().exec; "--startup-file=no"]
    capture(() -> Evidence.main(["tests", "--root", d, "--", jl..., "-e", "using Test; @testset \"t\" begin @test true; @test true end"]))
    rc, out = run_cc("--strict")
    @test rc == 0 && !occursin("UNVERIFIED", out)
    write(joinpath(d, "HANDOFF.md"), "Tests: 3/3 <!-- claim: tests_pass=3 tests_total=3 -->\n")
    rc, out = run_cc()
    @test rc == 1 && length(fails(out)) == 2 && occursin("tests_pass=3 but .lanes/evidence/tests-", out)
    head7 = first(readchomp(`git -C $d rev-parse HEAD`), 7)
    write(joinpath(d, "HANDOFF.md"), "Tests: 2 <!-- claim: tests_total=2 evidence=tests-$head7 -->\n")   # a cited file
    @test run_cc("--strict")[1] == 0
    write(joinpath(d, "HANDOFF.md"), "Tests: 2 <!-- claim: tests_total=2 evidence=tests-0000000 -->\n")
    @test run_cc()[1] == 0 && run_cc("--strict")[1] == 1                      # cited but absent here: unverified
    if IN_FACTORY
        @test CheckClaims.derive(ROOT)("factory_version") == strip(read(joinpath(FACTORY, "VERSION"), String))
        @test "check_claims" in keys(CheckClaims.CONFIG_KEYS)
    end
end
