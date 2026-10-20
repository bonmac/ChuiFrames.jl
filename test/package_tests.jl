@testitem "module loads" tags = [:unit] begin
    @test ChuiFrames isa Module
    @test nameof(ChuiFrames) == :ChuiFrames
end

@testitem "Aqua" tags = [:quality] begin
    using Aqua
    Aqua.test_all(ChuiFrames)
end

@testitem "ExplicitImports" tags = [:quality] begin
    using ExplicitImports
    @test check_no_implicit_imports(ChuiFrames) === nothing
    @test check_no_stale_explicit_imports(ChuiFrames) === nothing
    @test check_all_qualified_accesses_via_owners(ChuiFrames) === nothing
    @test check_all_explicit_imports_via_owners(ChuiFrames) === nothing
    # ADR-0006/0007: the *_are_public checks need Base.ispublic (Julia >= 1.11).
    if VERSION >= v"1.11"
        @test check_all_qualified_accesses_are_public(ChuiFrames) === nothing
        @test check_all_explicit_imports_are_public(ChuiFrames) === nothing
    end
end
