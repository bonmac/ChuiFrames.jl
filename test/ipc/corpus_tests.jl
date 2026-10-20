# The phase-2 spike gate (ADR-0001 rule 10): ChuiFrames' own IPC reader on files written by
# pyarrow 26.0.0, Polars 2.0.0 and R arrow 23.0.1.1, checked against pyarrow's dumps.

@testitem "ipc gate: Polars file, stream and compat-oldest (LC-04, variadic buffers)" tags = [:unit, :ipc] setup = [IPCCorpus] begin
    using ChuiFrames: StringColumn, getcol
    for case in ("polars_file", "polars_stream", "polars_oldest")
        t, _ = IPCCorpus.checkcase(case)
        @test getcol(t, :a) isa StringColumn   # Utf8View converted to the offsets layout (rule 3)
    end
end

@testitem "ipc gate: Polars compressed and multi-batch files" tags = [:unit, :ipc] setup = [IPCCorpus] begin
    for case in ("polars_lz4", "polars_zstd")
        IPCCorpus.checkcase(case)
    end
    _, batches = IPCCorpus.checkcase("polars_multibatch")
    @test length(batches) > 1
end

@testitem "ipc gate: two Utf8View columns plus BinaryView (ST-03)" tags = [:unit, :ipc] setup = [IPCCorpus] begin
    using ChuiFrames: StringColumn, BinaryColumn, getcol
    for case in ("st03_two_views", "st03_two_views_stream")
        t, _ = IPCCorpus.checkcase(case)
        @test getcol(t, :v1) isa StringColumn
        @test getcol(t, :v2) isa StringColumn
        @test getcol(t, :bv) isa BinaryColumn
    end
end

@testitem "ipc gate: sliced dictionary batch length from the message (ST-04)" tags = [:unit, :ipc] setup = [IPCCorpus] begin
    using ChuiFrames: DictColumn, getcol, nrows
    for case in ("st04_sliced_dict", "st04_sliced_dict_stream")
        t, _ = IPCCorpus.checkcase(case)
        @test nrows(t) == 4
        @test getcol(t, :d) isa DictColumn
    end
end

@testitem "ipc gate: replacement dictionaries per batch (#610)" tags = [:unit, :ipc] setup = [IPCCorpus] begin
    using ChuiFrames: DictColumn, getcol
    t, batches = IPCCorpus.checkcase("dict_replacement_stream")
    @test all(b -> getcol(b, :d) isa DictColumn, batches)
    d = getcol(t, :d)
    @test d isa DictColumn                 # one unified dictionary across the batches
    @test sort!(String.(collect(d.dict))) == ["k", "l", "m", "p", "q", "x", "y"]
end

@testitem "ipc gate: delta dictionaries (really isDelta in the bytes)" tags = [:unit, :ipc] setup = [IPCCorpus] begin
    using ChuiFrames: DictColumn, getcol, ipc_messages
    msgs = ipc_messages(IPCCorpus.casepath("dict_delta_stream"))
    dicts = filter(m -> m.kind === :dictionary, msgs)
    @test length(dicts) == 3
    @test [m.isdelta for m in dicts] == [false, true, true]
    t, batches = IPCCorpus.checkcase("dict_delta_stream")
    @test getcol(t, :d) isa DictColumn
    @test String.(collect(getcol(t, :d).dict)) == ["x", "y", "z", "w", "v"]
end

@testitem "ipc gate: duplicate dictionary entries and a null entry" tags = [:unit, :ipc] setup = [IPCCorpus] begin
    using ChuiFrames: getcol
    t, _ = IPCCorpus.checkcase("dict_dups_nullentry")
    d = getcol(t, :d)
    @test String.(collect(d.dict)) == ["a", "b"]     # deduplicated (rule 5)
    @test d.codes == UInt8[1, 1, 0, 2, 1]            # index -> null entry folded into validity
    @test d.validity == BitVector([true, true, false, true, true])
end

@testitem "ipc gate: pyarrow LZ4 and Zstd files and streams" tags = [:unit, :ipc] setup = [IPCCorpus] begin
    for case in ("pyarrow_lz4", "pyarrow_zstd", "pyarrow_lz4_stream", "pyarrow_zstd_stream")
        IPCCorpus.checkcase(case)
    end
    @test length(IPCCorpus.checkcase("pyarrow_zstd_stream")[2]) == 4   # 1000 rows in chunks of 300
end

@testitem "ipc gate: every supported type, file and stream" tags = [:unit, :ipc] setup = [IPCCorpus] begin
    using ChuiFrames: getcol, PrimitiveColumn, BoolColumn, StringColumn, BinaryColumn, ListColumn, StructColumn
    using Dates: Date, DateTime
    for case in ("alltypes", "alltypes_stream")
        t, batches = IPCCorpus.checkcase(case)
        @test length(batches) == 2
        @test getcol(t, :b) isa BoolColumn
        @test getcol(t, :ls) isa StringColumn{<:Any, Int64}
        @test getcol(t, :s) isa StringColumn{<:Any, Int32}
        @test getcol(t, :lbin) isa BinaryColumn{<:Any, Int64}
        @test getcol(t, :lst) isa ListColumn
        @test getcol(t, :llst) isa ListColumn{<:Any, Int64}
        @test getcol(t, :st) isa StructColumn
        @test eltype(getcol(t, :d32)) === Union{Missing, Date}
        @test eltype(getcol(t, :tsms)) === Union{Missing, DateTime}
        @test getcol(t, :u64)[1] === typemax(UInt64)
    end
end

@testitem "ipc gate: empty file, zero-length batch, non-nullable fields" tags = [:unit, :ipc] setup = [IPCCorpus] begin
    using ChuiFrames: read_ipc, read_ipc_batches, read_ipc_schema, getcol, nrows, StrView
    p = IPCCorpus.casepath("empty")
    @test read_ipc_batches(p) == []
    t = read_ipc(p)
    @test nrows(t) == 0
    @test eltype(getcol(t, :x)) === Union{Missing, Int64}
    @test eltype(getcol(t, :s)) === Union{Missing, StrView}
    @test collect(read_ipc_schema(p).types) == [Union{Missing, Int64}, Union{Missing, StrView}]
    IPCCorpus.checkcase("empty")
    t, batches = IPCCorpus.checkcase("nonnull_zero_batch")
    @test eltype(getcol(t, :x)) === Int64                  # non-nullable -> T
    @test eltype(getcol(t, :y)) === Union{Missing, Float64}
    @test nrows.(batches) == [2, 0, 1]
end

@testitem "ipc gate: files written by R arrow (feather and stream)" tags = [:unit, :ipc] setup = [IPCCorpus] begin
    for case in ("r_feather", "r_stream")
        IPCCorpus.checkcase(case)
    end
end
