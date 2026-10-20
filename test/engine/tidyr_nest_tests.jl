# Unit tests for the tidyr nesting verbs: nest, unnest, unnest_longer, unnest_wider, pack,
# unpack (src/engine/verbs_nest.jl). Expected values were checked against tidyr 1.3.1 with
# `Rscript` (the differential item re-checks the main cases).

@testsnippet TN begin
    using Tables
    using DataAPI: nrow, ncol
    using ChuiFrames: frame_equal
    const ⨟ = ChuiFrames.Upstream.:⨟
    ct(x) = Tables.columntable(x)
    col(x, n) = collect(Tables.getcolumn(x, n))
    eq(a, b) = isequal(a, b)
    names_of(x) = collect(Tables.columnnames(x))
    # Frames have no `isequal` of their own (identity), so nested columns compare by content
    _cell(x) = x isa Frame ? ct(x) : x
    nested_eq(a, b) = names_of(a) == names_of(b) && groupcols(a) == groupcols(b) &&
        all(isequal(map(_cell, col(a, n)), map(_cell, col(b, n))) for n in names_of(a))
    d = (g = Union{Missing, String}["b", "a", "b", missing, "a"], x = Union{Missing, Float64}[1.0, 2.0, 3.0, 4.0, missing], y = [10, 20, 30, 40, 50])
    e = (g = String[], x = Float64[], y = Int[])
end

@testitem "nest: one row per key, first-appearance order, Frame elements" tags = [:unit] setup = [TN] begin
    r = nest(data = [:x, :y])(d)
    @test names_of(r) == [:g, :data]
    @test eq(col(r, :g), ["b", "a", missing])                    # first appearance (tidyr)
    @test eltype(Tables.getcolumn(r, :data)) === Frame
    @test Tables.getcolumn(r, :data) isa ChuiFrames.ObjectColumn
    d1 = Tables.getcolumn(r, :data)[1]
    @test names_of(d1) == [:x, :y] && eq(col(d1, :x), [1.0, 3.0]) && col(d1, :y) == [10, 30]
    @test eltype(Tables.getcolumn(d1, :x)) == Union{Missing, Float64}   # declared type kept
    @test nested_eq(nest(data = Not(:g))(d), r)
    @test nested_eq(nest("data" => [:x, :y])(d), r)
    @test !nested_eq(nest(data = :x)(d), r)
    # two nested columns, keys first then the nested columns in order
    r2 = nest(a = :x, b = :y)(d)
    @test names_of(r2) == [:g, :a, :b]
    @test names_of(Tables.getcolumn(r2, :a)[1]) == [:x]
    # keys keep their position order; nested columns go last
    @test names_of(nest(data = :x)((a = [1], x = [2], b = [3]))) == [:a, :b, :data]
    # names_sep strips the prefix inside
    r3 = nest(data = [:data_x, :data_y]; names_sep = "_")((g = [1, 2], data_x = [1, 2], data_y = [3, 4]))
    @test names_of(Tables.getcolumn(r3, :data)[1]) == [:x, :y]
    # by: nest everything else
    @test nested_eq(nest(by = :g)(d), r)
    @test_throws ArgumentError nest(data = :x, by = :g)
    # missing is a key
    @test nrow(Tables.getcolumn(r, :data)[3]) == 1
end

@testitem "nest: grouped input, empty input" tags = [:unit] setup = [TN] begin
    g = group_by(:g)(d)
    r = nest()(g)
    @test names_of(r) == [:g, :data]
    @test groupcols(r) == [:g]
    @test eq(col(r, :g), ["b", "a", missing])                    # tidyr keeps first appearance
    @test names_of(Tables.getcolumn(r, :data)[1]) == [:x, :y]
    @test !isgrouped(Tables.getcolumn(r, :data)[1])
    # grouped, explicit spec: the other columns are keys
    rr = nest(data = :y)(group_by(:x)(d))
    @test names_of(rr) == [:g, :x, :data] && nrow(rr) == 5 && groupcols(rr) == [:x]
    # a grouping column cannot be nested
    @test_throws ArgumentError nest(data = :g)(g)
    # empty
    r0 = nest(data = [:x, :y])(e)
    @test nrow(r0) == 0 && names_of(r0) == [:g, :data] && eltype(Tables.getcolumn(r0, :data)) === Frame
    @test nrow(nest()(group_by(:g)(e))) == 0
    # ungrouped nest() nests every column
    a = nest()((x = [1, 2],))
    @test nrow(a) == 1 && names_of(a) == [:data] && col(Tables.getcolumn(a, :data)[1], :x) == [1, 2]
    @test_throws ArgumentError nest(data = :zz)(d)
    @test sprint(show, nest(data = [:x, :y])) == "nest(data = [:x, :y])"
end

@testitem "unnest: frames and vectors, keep_empty, names_sep, mixed types" tags = [:unit] setup = [TN] begin
    r = nest(data = [:x, :y])(d)
    u = unnest(:data)(r)
    @test names_of(u) == [:g, :x, :y]
    @test eq(col(u, :g), ["b", "b", "a", "a", missing])
    @test eq(col(u, :x), [1.0, 3.0, 2.0, missing, 4.0])
    @test col(u, :y) == [10, 30, 20, 50, 40]
    @test eltype(Tables.getcolumn(u, :y)) === Int
    # grouped round trip keeps the grouping
    ug = unnest(:data)(nest()(group_by(:g)(d)))
    @test groupcols(ug) == [:g]
    # inner columns spliced at the nested column's position
    t = (a = [1], data = [Frame(x = [1], y = [2])], b = [3])
    @test names_of(unnest(:data)(t)) == [:a, :x, :y, :b]
    # keep_empty: empty frames and missing elements
    dd = (g = [1, 2, 3], data = Any[Frame(x = [1, 2]), Frame(x = Int[]), missing])
    @test col(unnest(:data)(dd), :g) == [1, 1]
    k = unnest(:data; keep_empty = true)(dd)
    @test col(k, :g) == [1, 1, 2, 3] && eq(col(k, :x), [1, 2, missing, missing])
    # list of vectors
    lv = (g = [1, 2, 3], v = [[1, 2], Int[], [3]])
    @test col(unnest(:v)(lv), :g) == [1, 1, 3] && col(unnest(:v)(lv), :v) == [1, 2, 3]
    @test eltype(Tables.getcolumn(unnest(:v)(lv), :v)) === Int
    @test eq(col(unnest(:v; keep_empty = true)(lv), :v), [1, 2, missing, 3])
    # names_sep
    ns = (g = [1, 2], data = [Frame(x = [1.0], y = [2.0]), Frame(x = [3.0], y = [4.0])])
    @test names_of(unnest(:data; names_sep = "_")(ns)) == [:g, :data_x, :data_y]
    # mixed types: lossless promotion, missing columns filled
    mt = (g = [1, 2], data = [Frame(x = [1]), Frame(x = [2.5])])
    @test eltype(Tables.getcolumn(unnest(:data)(mt), :x)) === Float64
    dc = unnest(:data)((g = [1, 2], data = [Frame(x = [1]), Frame(y = [2.5])]))
    @test names_of(dc) == [:g, :x, :y] && eq(col(dc, :x), [1, missing]) && eq(col(dc, :y), [missing, 2.5])
    # Tables.jl tables as elements
    @test col(unnest(:data)((g = [1], data = [(x = [1, 2],)])), :x) == [1, 2]
    # two columns in parallel, size-1 and missing recycle
    two = unnest(:a, :b)((g = [1, 2], a = [[1, 2], [3]], b = [["x"], ["y", "z"]]))
    @test col(two, :a) == [1, 2, 3, 3] && col(two, :b) == ["x", "x", "y", "z"]
    nr = unnest(:a, :b)((g = [1, 2], a = [[1, 2], [3]], b = Union{Missing, Vector{String}}[missing, ["y"]]))
    @test eq(col(nr, :b), [missing, missing, "y"])
    @test_throws ArgumentError unnest(:a, :b)((g = [1], a = [[1, 2]], b = [[1, 2, 3]]))
    # list column (Arrow layout) input
    lc = Frame(g = [1, 2], v = ChuiFrames.column([[1, 2], [3]]))
    @test Tables.getcolumn(lc, :v) isa ChuiFrames.ListColumn
    @test col(unnest(:v)(lc), :v) == [1, 2, 3]
end

@testitem "unnest: empty input keeps the keys (prototype bug 6)" tags = [:unit] setup = [TN] begin
    r0 = nest(data = [:x, :y])(e)
    u0 = unnest(:data)(r0)
    @test nrow(u0) == 0
    @test :g in names_of(u0)                                     # keys survive (tidyr: g, data <???>)
    @test eltype(Tables.getcolumn(u0, :g)) <: AbstractString     # the declared string type
    l0 = unnest(:v)(Frame(g = Int[], v = ChuiFrames.column(Vector{Int}[])))
    @test names_of(l0) == [:g, :v] && eltype(Tables.getcolumn(l0, :v)) === Int   # declared child type
    @test_throws ArgumentError unnest(:g)(d)                     # not a list or table column
end

@testitem "unnest_longer: vectors, names, indices, keep_empty" tags = [:unit] setup = [TN] begin
    lv = (g = [1, 2, 3, 4], v = Union{Missing, Vector{Int}}[[1, 2], Int[], missing, [3]])
    u = unnest_longer(:v)(lv)
    @test col(u, :g) == [1, 1, 4] && col(u, :v) == [1, 2, 3]
    @test eltype(Tables.getcolumn(u, :v)) === Int
    k = unnest_longer(:v; keep_empty = true)(lv)
    @test col(k, :g) == [1, 1, 2, 3, 4] && eq(col(k, :v), [1, 2, missing, missing, 3])
    i = unnest_longer(:v; values_to = :val, indices_to = :i)(lv)
    @test names_of(i) == [:g, :val, :i] && col(i, :i) == [1, 2, 1]
    # named elements: NamedTuples and Dicts give a `<col>_id` column of names
    nt = unnest_longer(:v)((g = [1, 2], v = Any[(a = 1.0, b = 2.0), (c = 3.0,)]))
    @test names_of(nt) == [:g, :v, :v_id] && col(nt, :v_id) == ["a", "b", "c"] && col(nt, :v) == [1.0, 2.0, 3.0]
    dc = unnest_longer(:v)((g = [1], v = [Dict("a" => 1)]))
    @test col(dc, :v_id) == ["a"] && col(dc, :v) == [1]
    # a struct column (NamedTuple elements)
    sc = unnest_longer(:v)((g = [1, 2], v = [(a = 1, b = 2), (a = 3, b = 4)]))
    @test col(sc, :v) == [1, 2, 3, 4] && col(sc, :v_id) == ["a", "b", "a", "b"]
    # mixed types across rows
    @test eltype(Tables.getcolumn(unnest_longer(:v)((g = [1, 2], v = Any[[1], [2.5]])), :v)) === Float64
    # empty input keeps the declared type
    z = unnest_longer(:v)(Frame(g = Int[], v = ChuiFrames.column(Vector{Int}[])))
    @test nrow(z) == 0 && eltype(Tables.getcolumn(z, :v)) === Int
    @test_throws ArgumentError unnest_longer([:g, :v])(lv)
    @test groupcols(unnest_longer(:v)(group_by(:g)(lv))) == [:g]
end

@testitem "unnest_wider: names, names_sep, unnamed vectors, missing" tags = [:unit] setup = [TN] begin
    w = unnest_wider(:v)((g = [1, 2], v = Any[(a = 1.0, b = 2.0), (a = 3.0,)]))
    @test names_of(w) == [:g, :a, :b] && col(w, :a) == [1.0, 3.0] && eq(col(w, :b), [2.0, missing])
    @test eltype(Tables.getcolumn(w, :b)) == Union{Missing, Float64}
    @test names_of(unnest_wider(:v; names_sep = "_")((g = [1, 2], v = Any[(a = 1.0, b = 2.0), (a = 3.0,)]))) == [:g, :v_a, :v_b]
    # unnamed vectors need names_sep (tidyr errors without it), then col_1, col_2
    uv = (g = [1, 2], v = [[1, 2], [3]])
    @test_throws ArgumentError unnest_wider(:v)(uv)
    u = unnest_wider(:v; names_sep = "_")(uv)
    @test names_of(u) == [:g, :v_1, :v_2] && col(u, :v_1) == [1, 3] && eq(col(u, :v_2), [2, missing])
    # missing elements give missing rows; mixed value types; Dict elements
    m = unnest_wider(:v)((g = [1, 2, 3], v = Any[(a = 1.0, b = "x"), missing, Dict(:b => "y", :c => true)]))
    @test names_of(m) == [:g, :a, :b, :c]
    @test eq(col(m, :a), [1.0, missing, missing]) && eq(col(m, :b), ["x", missing, "y"]) && eq(col(m, :c), [missing, missing, true])
    # struct column input, including a null parent
    s = Frame(g = [1, 2], v = ChuiFrames.column(Union{Missing, NamedTuple{(:a, :b), Tuple{Int, Int}}}[(a = 1, b = 3), missing]))
    sw = unnest_wider(:v)(s)
    @test names_of(sw) == [:g, :a, :b] && eq(col(sw, :a), [1, missing])
    # clashes with existing names
    @test_throws ArgumentError unnest_wider(:v)((a = [1], v = [(a = 2,)]))
    # empty: the column is dropped (no names known), as tidyr
    @test names_of(unnest_wider(:v)((g = Int[], v = Any[]))) == [:g]
end

@testitem "pack and unpack" tags = [:unit] setup = [TN] begin
    p = pack(xy = [:x, :y])(d)
    @test names_of(p) == [:g, :xy]
    sc = Tables.getcolumn(p, :xy)
    @test sc isa ChuiFrames.StructColumn
    @test eq(sc[5], (x = missing, y = 50))
    @test names_of(pack(xy = [:x, :y])((a = [1], x = [2], b = [3], y = [4]))) == [:a, :b, :xy]
    @test keys(Tables.getcolumn(pack(xy = [:xy_x, :xy_y]; names_sep = "_")((g = [1], xy_x = [1], xy_y = [2])), :xy)[1]) == (:x, :y)
    up = unpack(:xy)(p)
    @test frame_equal(up, Frame(d))
    @test names_of(unpack(:xy; names_sep = "_")(p)) == [:g, :xy_x, :xy_y]
    # grouped
    gp = pack(xy = [:x, :y])(group_by(:g)(d))
    @test groupcols(gp) == [:g]
    @test_throws ArgumentError pack(gg = :g)(group_by(:g)(d))
    # empty
    p0 = pack(xy = [:x, :y])(e)
    @test nrow(p0) == 0 && eltype(Tables.getcolumn(p0, :xy)) == NamedTuple{(:x, :y), Tuple{Float64, Int}}
    @test names_of(unpack(:xy)(p0)) == [:g, :x, :y]
    # a null struct parent unpacks to missing children
    s = Frame(g = [1, 2], v = ChuiFrames.column(Union{Missing, NamedTuple{(:a,), Tuple{Int}}}[(a = 1,), missing]))
    @test eq(col(unpack(:v)(s), :a), [1, missing])
    @test_throws ArgumentError unpack(:g)(d)                     # not a struct column
    @test_throws ArgumentError unpack(:xy)(Frame(x = [1], xy = ChuiFrames.column([(x = 1,)])))  # duplicate name
end
