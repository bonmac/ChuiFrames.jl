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
        :schema, :Schema, :partitions, :Scan, :columntable, :rowtable, :rowcount, :Partitioner,
        # Tables.Scan's pushdown vocabulary (Tables 1.14 docs; LC-10, ADR-0004 rule 1)
        :Col, :ScanExpr, :filtermask, :resolve,
        # Arrow.jl's documented writer API (ADR-0010; the adapter is its only caller)
        :write, :append, :Writer,
        # Arrow.jl storage types for Date32/Timestamp(ms), so no JuliaLang.* extension type is
        # written. NOT documented by Arrow.jl: revisit with ADR-0010's Arrow.jl 3.0 trigger.
        :DATE, :DATETIME,
        # Dates' documented abstract type (Dates manual, "Dates.AbstractDateTime")
        :AbstractDateTime,
        # DataAPI generics (README: "functions to be extended")
        :refarray, :refpool, :refvalue, :nrow, :ncol,
        # DataAPI selector types, re-exported as the same bindings (ADR-0002 rule 7)
        :Cols, :Between, :All,
        # Base broadcasting interface (manual: "Customizing broadcasting"), the c.x capture
        # mechanism of ADR-0002 rule 1, and `literal_pow` (rule 1's `.^` normalisation, GR-02)
        :broadcasted, :broadcastable, :Broadcasted, :BroadcastStyle, :Unknown, :literal_pow,
    )
    if VERSION >= v"1.11"
        @test check_all_qualified_accesses_are_public(ChuiFrames; ignore = INTERFACE) === nothing
        @test check_all_explicit_imports_are_public(ChuiFrames; ignore = INTERFACE) === nothing
    end
end
