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
    # Tables.jl and DataAPI do not mark their documented interface functions `public`; extending
    # them is the purpose of ADR-0006/0007 (CF-001), so exactly these names are allowed.
    # Every name added here needs the upstream doc page that documents it as interface.
    INTERFACE = (
        # Tables.jl interface (docs: "Implementing the Interface"; Tables.Scan, Tables 1.14)
        :istable, :columnaccess, :rowaccess, :columns, :rows, :columnnames, :getcolumn,
        :schema, :Schema, :partitions, :Scan, :columntable, :rowtable,
        # DataAPI generics (README: "functions to be extended")
        :refarray, :refpool, :refvalue, :nrow, :ncol,
    )
    if VERSION >= v"1.11"
        @test check_all_qualified_accesses_are_public(ChuiFrames; ignore = INTERFACE) === nothing
        @test check_all_explicit_imports_are_public(ChuiFrames; ignore = INTERFACE) === nothing
    end
end
