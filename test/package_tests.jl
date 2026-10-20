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
        # Parquet2's documented reader/writer API, used by ext/ChuiFramesParquet2Ext.jl (ADR-0020);
        # checked only when a test has loaded Parquet2 (e.g. `ci.jl test -- all`)
        :Dataset, :FileWriter, :ColumnStatistics, :load, :writetable!, :finalize!,
        # Parquet2's logical timestamp type, read to find a column's unit (review M1)
        :ParqDateTime,
        # ChuiFrames internals used by its own Parquet2 extension (same package, not an API)
        :DEFAULT_MORSEL, :_tryclose, :_tryrm, :column, :isnullable, :schema_types,
        :AbstractColumn, :BinaryColumn, :DictColumn, :ListColumn, :StrView, :StringColumn,
        :StructColumn, :check_writable, :conform_column, :conform_partition, :empty_frame,
        :pushed_columns, :temp_path_for, :PrimitiveColumn, :read_ipc_schema,
        # ... and its timestamp helpers (ADR-0021 rule 11)
        :_DT_MAX_MS, :_DT_MIN_MS, :_UNIX_EPOCH_MS, :_instant_ns,
        # Parquet2 INTERNALS, used on purpose by the exact timestamp path (ADR-0021 rule 11, TS-12):
        # the raw Int64 read rebuilds a `Column`/`SchemaNode` with type `ParqInt64`, and the exact
        # write adds an `encodevalue` method on the owned `ExactMs` type. The read fails closed if
        # these change; the Parquet tests pin exactness. A ★ question to the user (lead report).
        :Column, :SchemaNode, :ParqInt64, :encodevalue,
        # Dates' documented accessor (Dates manual API: `Dates.value`)
        :value,
        # DataAPI's documented metadata interface (DataAPI README, "metadata")
        :metadata,
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
