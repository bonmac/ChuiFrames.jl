@testitem "assert" begin
    @test g(1) == 3
end

@testitem "stub in test" begin
    @test f(1) == 2
end

@testitem "stub outside test" begin
    y = f(1)
    @test y == 2
end

@testitem "typo" begin
    @test gg(1) == 2
end

@testitem "typo outside" begin
    y = gg(1)
    @test y == 2
end

@testitem "helper" begin
    include("helpers.jl")
    @test helper_check(1) == 1
end

@testitem "passes" begin
    @test g(1) == 2
end

@testitem "throws wrong" begin
    @test_throws ArgumentError f(1)
end

@testitem "throws typo" begin
    @test_throws ArgumentError gg(1)
end

@testitem "new method on existing g" begin
    @test g("a") == "a1"
end

@testitem "nested" begin
    @testset "inner" begin
        @test g(1) == 5
    end
end
