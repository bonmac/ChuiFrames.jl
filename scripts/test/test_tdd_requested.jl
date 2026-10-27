# Tests for `requested` in scripts/_tdd_classify.jl (factory 0.3.0, plan Task 3; spec §3.3), moved
# out of test_tdd.jl for its 400-line budget. Included by test_tdd.jl INSIDE its testset
# "_tdd_classify.jl (0.3.0)", so it uses that file's host (TC, tdd_testset) and representation choices.

tdd_testset("requested: setup-module change adds must_pass items") do
    a0 = """
    @testmodule Shared begin
        const base = 1
    end

    @testitem "uses shared" setup = [Shared] begin
        @test Shared.base == 1
    end

    @testitem "other" begin
        @test true
    end

    @testitem "target" begin
        @test 1 == 1
    end
    """
    b0 = """
    @testitem "far user" setup = [Shared] begin
        @test Shared.base >= 1
    end

    @testitem "far other" begin
        @test true
    end
    """
    d = tmp_repo(Dict("test/a_tests.jl" => a0, "test/b_tests.jl" => b0, "src/X.jl" => "module X end\n"))
    a1 = replace(a0, "const base = 1" => "const base = 2", "@test 1 == 1" => "@test 1 == 2") * """

        @testitem "added" begin
            @test false
        end
        """
    commit!(d, Dict("test/a_tests.jl" => a1), "test: red for target\n\nTDD: red")
    r = TC.requested(d, "HEAD")
    @test keys(r) == (:red, :must_pass)
    @test sort([s.name for s in r.red]) == ["added", "target"]          # touched and added items
    @test sort([s.name for s in r.must_pass]) == ["far user", "uses shared"]   # unchanged, setup names Shared
    t = only(filter(s -> s.name == "target", r.red))
    @test t.file == "test/a_tests.jl" && t.first == 13
    @test only(filter(s -> s.name == "far user", r.must_pass)).file == "test/b_tests.jl"
    # a red commit that changes only an item, no module: nothing must pass
    commit!(d, Dict("test/b_tests.jl" => replace(b0, "@test true" => "@test 2 > 1")), "test: red\n\nTDD: red")
    r = TC.requested(d, "HEAD")
    @test [s.name for s in r.red] == ["far other"] && isempty(r.must_pass)
end
