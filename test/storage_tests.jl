# Column types and the frame (ADR-0001 rules 1-9, 12; CF-001).

@testitem "columns: declared element types" tags = [:unit] begin
    using ChuiFrames: column, PrimitiveColumn, BoolColumn, StringColumn, BinaryColumn, ObjectColumn,
        ListColumn, StructColumn, StrView, ByteView, isnullable
    using Dates
    @test eltype(column([1, 2])) === Int64
    @test eltype(column(Union{Missing, Int}[1, 2])) === Union{Missing, Int64}   # nullable, no missing
    @test isnullable(column(Union{Missing, Int}[1, 2]))
    @test !isnullable(column([1.0]))
    @test column([true, false]) isa BoolColumn
    @test eltype(column(["a", missing])) === Union{Missing, StrView}
    @test column(["a", "bc"]) isa StringColumn
    @test eltype(column([codeunits("ab")])) === ByteView
    @test column([Date(2020)]) isa PrimitiveColumn{Date}
    @test column([:a, :b]) isa ObjectColumn{Symbol}
    @test column(Any[1, "x"]) isa ObjectColumn{Any}
    @test column([[1, 2], Int[]]) isa ListColumn
    @test column([(a = 1, b = "x")]) isa StructColumn
    @test isequal(collect(column(["a", missing, "ccc"])), ["a", missing, "ccc"])
    @test collect(column([[1, 2], Int[]])) == [[1, 2], Int[]]
    @test collect(column([(a = 1, b = "x"), (a = 2, b = "y")])) == [(a = 1, b = "x"), (a = 2, b = "y")]
end

@testitem "columns: small numeric unions promote only when lossless" tags = [:unit] begin
    using ChuiFrames: column, PrimitiveColumn, ObjectColumn
    @test column(Union{Int, Float64}[1, 2.5]) isa PrimitiveColumn{Float64}
    @test column(Union{Int, Float64}[2^53 + 1, 2.5]) isa ObjectColumn
    @test column(Union{Int8, UInt64}[Int8(-1), UInt64(1)]) isa ObjectColumn
    @test isequal(collect(column(Union{Missing, Int, Float64}[1, missing, 2.5])), [1.0, missing, 2.5])
end

@testitem "columns: zero-null-slot invariant" tags = [:unit] begin
    using ChuiFrames: column, PrimitiveColumn, BoolColumn, StringColumn, DictColumn, take
    c = PrimitiveColumn([1.5, 7.0, 3.0], BitVector([true, false, true]))
    @test c.values == [1.5, 0.0, 3.0]
    b = BoolColumn(BitVector([true, true]), BitVector([false, true]))
    @test b.values == BitVector([false, true])
    @test_throws ArgumentError StringColumn(Int32[0, 1, 2], UInt8[0x61, 0x62], BitVector([false, true]))
    d = DictColumn(UInt8[1, 2, 1], column(["x", "y"]), BitVector([true, false, true]))
    @test d.codes == UInt8[1, 0, 1]
    @test isequal(collect(d), ["x", missing, "x"])
    t = take(column(Union{Missing, Int}[5, missing, 7]), [3, 2, 0, 1])
    @test isequal(collect(t), [7, missing, missing, 5])
    @test t.values == [7, 0, 0, 5]
    s = take(column(["ab", "c"]), [2, 0])
    @test isequal(collect(s), ["c", missing])
    @test s.offsets == Int32[0, 1, 1]
end

@testitem "columns: offset widening" tags = [:unit] begin
    using ChuiFrames: widen_offsets
    o = Int32[0, 10]
    @test widen_offsets(o, 5) === o
    w = widen_offsets(Int32[0, typemax(Int32) - 1], 2)
    @test w isa Vector{Int64}
    @test w == [0, typemax(Int32) - 1]
end

@testitem "frame: Tables.jl in and out (CF-001)" tags = [:unit] begin
    using ChuiFrames: Frame, groupcols, frame_equal
    using Tables
    nt = (a = [1, 2, 3], g = ["x", "y", missing])
    f = Frame(nt)
    @test Tables.istable(typeof(f))
    @test isequal(Tables.columntable(f), (a = [1, 2, 3], g = ["x", "y", missing]))
    @test Tables.schema(f).names == (:a, :g)
    rows = collect(Tables.rows(f))
    @test length(rows) == 3 && rows[2].a == 2
    @test frame_equal(Frame(Tables.rowtable(nt)), f)
    @test groupcols(f) == Symbol[]
    @test groupcols(nt) == Symbol[]
    @test Frame(a = [1], b = ["q"]).names == [:a, :b]
    @test_throws DimensionMismatch Frame(a = [1, 2], b = [1])
    @test_throws ArgumentError Frame(42)
end
