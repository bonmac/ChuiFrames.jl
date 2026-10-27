# Review cases (fixtures unexpected-pass-*.txt, letctx-*.txt; ../README.md).
# A @test_broken whose expression now holds: Test reports `Unexpected Pass` as an error.
@testitem "unexpected pass" begin
    @test_broken 1 == 1
end

# A typo inside `@testset let`: Test prints a `Context: v = 1` line before the exception.
@testitem "letctx" begin
    @testset let v = 1
        @test undefined_fnn(v) == 1
    end
end
