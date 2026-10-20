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
    @test isequal(collect(column(Any[1, missing])), Any[1, missing])   # found by p2-engine
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
    # NaN is lossless too (review minor: `==` made NaN look lossy)
    @test column(Union{Int, Float64}[1, NaN]) isa PrimitiveColumn{Float64}
end

@testitem "columns: vcat_columns never loses integer precision" tags = [:unit] begin
    using ChuiFrames: column, vcat_columns, PrimitiveColumn, ObjectColumn
    big = 2^53 + 1
    v = vcat_columns([column([big]), column([0.5])])
    @test !(v isa PrimitiveColumn{Float64})          # was 9.007199254740992e15 (review minor)
    @test isequal(collect(v), Any[big, 0.5])
    @test vcat_columns([column([1]), column([0.5])]) isa PrimitiveColumn{Float64}
    @test isequal(collect(vcat_columns([column([1]), column(Union{Missing, Int}[missing])])), [1, missing])
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

@testitem "frame: content equality (isequal, ==, hash)" tags = [:unit] begin
    using ChuiFrames: Frame, frame_equal
    using Tables
    a = Frame(x = [1, 2], y = ["a", "b"])
    b = Frame(x = [1, 2], y = ["a", "b"])
    @test a !== b && isequal(a, b) && a == b && hash(a) == hash(b)
    # element values, not element types (as isequal on vectors and frame equality)
    @test isequal(a, Frame(x = [1.0, 2.0], y = ["a", "b"])) && hash(a) == hash(Frame(x = [1.0, 2.0], y = ["a", "b"]))
    @test !isequal(a, Frame(y = ["a", "b"], x = [1, 2]))          # names in order
    @test !isequal(a, Frame(x = [1, 2], z = ["a", "b"]))
    @test !isequal(a, Frame(x = [1, 3], y = ["a", "b"])) && a != Frame(x = [1, 3], y = ["a", "b"])
    @test !isequal(a, Frame(x = [1], y = ["a"]))
    # zero columns, different row counts
    z(n) = Frame(Symbol[], ChuiFrames.AbstractColumn[], Symbol[], nothing, n)
    @test isequal(z(2), z(2)) && !isequal(z(2), z(3)) && z(2) == z(2) && z(2) != z(3)
    # NaN, -0.0, missing: isequal as on vectors; == three-valued as on vectors
    n1, n2 = Frame(x = [NaN, 1.0]), Frame(x = [NaN, 1.0])
    @test isequal(n1, n2) && hash(n1) == hash(n2) && (n1 == n2) === false
    p, m = Frame(x = [0.0]), Frame(x = [-0.0])
    @test !isequal(p, m) && (p == m) === true
    u1, u2 = Frame(x = [missing, 1]), Frame(x = [missing, 1])
    @test isequal(u1, u2) && hash(u1) == hash(u2) && ismissing(u1 == u2)
    @test (Frame(x = [missing, 1]) == Frame(x = [missing, 2])) === false   # a definite difference wins
    @test (Frame(x = [missing], y = [1]) == Frame(x = [missing], y = [2])) === false
    @test (Frame(x = [missing]) == Frame(z = [missing])) === false        # structure first
    # grouping: same grouping columns (in order) and the same drop flag
    g = group_by(:y)(a)
    @test !isequal(g, a) && (g == a) === false && isequal(g, group_by(:y)(b)) && hash(g) == hash(group_by(:y)(b))
    @test !isequal(group_by(:x, :y)(a), group_by(:y, :x)(a))
    @test !isequal(group_by(:y; drop = false)(a), g) && (group_by(:y; drop = false)(a) == g) === false
    @test isequal(ungroup()(group_by(:y; drop = false)(a)), a)
    # nested frames compare by content (they were identity-equal before)
    d = (g = ["b", "a", "b"], x = [1.0, 2.0, 3.0], y = [10, 20, 30])
    r1, r2 = nest(data = [:x, :y])(d), nest(data = [:x, :y])(d)
    @test isequal(r1, r2) && r1 == r2 && hash(r1) == hash(r2) && frame_equal(r1, r2)
    @test !isequal(r1, nest(data = :x)(d))
    @test isequal(unique([r1, r2]), [r1])
    @test length(Set([a, b, g])) == 2 && Dict(a => 1)[b] == 1
    # a nested NaN keeps == from being true, a nested missing makes it missing
    k(v) = nest(data = [:x])((g = [1, 1], x = v))
    @test isequal(k([NaN, 1.0]), k([NaN, 1.0])) && (k([NaN, 1.0]) == k([NaN, 1.0])) === false
    @test ismissing(k([missing, 1.0]) == k([missing, 1.0]))
end

@testitem "frame: equality properties (Supposition)" tags = [:property] begin
    using ChuiFrames: Frame
    using Tables
    using Supposition, Supposition.Data
    V = Union{Missing, Float64}[NaN, -NaN, 0.0, -0.0, 1.0, missing]
    framegen = @composed function smallframe(
            n = Data.Integers(0, 2),
            x = Data.Vectors(Data.SampledFrom(V); min_size = 2, max_size = 2),
            g = Data.Vectors(Data.SampledFrom(["a", "b"]); min_size = 2, max_size = 2),
            wide = Data.Booleans(),
            grp = Data.Integers(0, 2),
        )
        xs = wide ? Union{Missing, Float64}[x[1:n]...] : Any[x[1:n]...]
        f = Frame(x = xs, g = g[1:n])
        grp == 0 ? f : group_by(:g; drop = grp == 1)(f)
    end
    # isequal implies equal hashes (pairs from a tiny domain are often equal)
    hashok(a, b) = !isequal(a, b) || hash(a) == hash(b)
    sr = @check record = false db = false max_examples = 400 hashok(framegen, framegen)
    @test Supposition.results(sr).ispass
    # isequal agrees with frame equality plus the drop flag
    agree(a, b) = isequal(a, b) == (ChuiFrames.frame_equal(a, b) && a.drop == b.drop)
    sr = @check record = false db = false max_examples = 400 agree(framegen, framegen)
    @test Supposition.results(sr).ispass
    # an ungrouped frame equals its round trip through a column table
    roundtrip(f) = (u = ungroup()(f); isequal(u, Frame(Tables.columntable(u))) && hash(u) == hash(Frame(Tables.columntable(u))))
    sr = @check record = false db = false max_examples = 300 roundtrip(framegen)
    @test Supposition.results(sr).ispass
    # == is three-valued like == on the column tables (a NamedTuple of vectors), once the
    # names, row counts, grouping columns and drop flags agree (false otherwise)
    same(a, b) = a.names == b.names && a.nrow == b.nrow && a.groups == b.groups && a.drop == b.drop
    eqok(a, b) = isequal(a == b, same(a, b) ? Tables.columntable(a) == Tables.columntable(b) : false)
    sr = @check record = false db = false max_examples = 400 eqok(framegen, framegen)
    @test Supposition.results(sr).ispass
end
