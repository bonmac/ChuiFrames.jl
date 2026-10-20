# Unit tests for pivot_longer and pivot_wider (tidyr 1.3.1 behaviour, checked in R; the
# differential file compares against R directly).

@testsnippet PV begin
    using Tables
    using DataAPI: nrow
    const ⨟ = ChuiFrames.Upstream.:⨟
    col(x, n) = collect(Tables.getcolumn(x, n))
    names_of(x) = collect(Tables.columnnames(x))
    eq(a, b) = isequal(a, b)
    frame_equal = ChuiFrames.frame_equal
    T(x, n) = eltype(Tables.getcolumn(x, n))
    w = (id = [1, 2, 3], x_1 = [1.0, missing, 3.0], x_2 = [4.0, 5.0, missing], y = ["a", "b", "c"])
end

@testitem "pivot_longer: basic, row order, selector forms" tags = [:unit] setup = [PV] begin
    r = pivot_longer(startswith("x"))(w)
    @test names_of(r) == [:id, :y, :name, :value]
    @test eq(col(r, :id), [1, 1, 2, 2, 3, 3])
    @test eq(col(r, :name), ["x_1", "x_2", "x_1", "x_2", "x_1", "x_2"])
    @test eq(col(r, :value), [1.0, 4.0, missing, 5.0, 3.0, missing])
    @test T(r, :value) == Union{Missing, Float64}
    @test nonmissingtype(T(r, :name)) <: AbstractString && !(Missing <: T(r, :name))
    # the same columns through other selector forms
    for sel in ([:x_1, :x_2], r"^x", Cols(:x_1, :x_2), Between(:x_1, :x_2), Not([:id, :y]), ["x_1", "x_2"], where(Union{Missing, Float64}))
        @test frame_equal(pivot_longer(sel)(w), r)
    end
    # selection order, not data order (tidyr)
    r2 = pivot_longer([:x_2, :x_1])(w)
    @test eq(col(r2, :name)[1:2], ["x_2", "x_1"])
    # names_to / values_to as strings or symbols
    r3 = pivot_longer(r"^x"; names_to = "key", values_to = :val)(w)
    @test names_of(r3) == [:id, :y, :key, :val]
    @test_throws ArgumentError pivot_longer(:nope)(w)
    @test_throws ArgumentError pivot_longer(r"^zzz")(w)                 # selects nothing
end

@testitem "pivot_longer: values_drop_na, names_prefix, mixed types, empty" tags = [:unit] setup = [PV] begin
    r = pivot_longer(r"^x"; values_drop_na = true)(w)
    @test eq(col(r, :id), [1, 1, 2, 3])
    @test eq(col(r, :value), [1.0, 4.0, 5.0, 3.0])
    r = pivot_longer(r"^x"; names_prefix = "x_")(w)
    @test eq(col(r, :name), ["1", "2", "1", "2", "1", "2"])
    r = pivot_longer(r"^x"; names_prefix = r"^x")(w)
    @test eq(col(r, :name)[1:2], ["_1", "_2"])
    # Int + Float64: lossless union (vcat_columns), Float64 here
    r = pivot_longer([:a, :b])((id = [1], a = [1], b = [2.5]))
    @test eq(col(r, :value), [1.0, 2.5])
    # incompatible types: kept losslessly (tidyr errors; documented divergence)
    r = pivot_longer([:a, :b])((a = [1], b = ["x"]))
    @test eq(col(r, :value), Any[1, "x"])
    # empty input: zero rows, same columns and types
    e = (id = Int[], x_1 = Float64[], x_2 = Float64[])
    r = pivot_longer(r"^x")(e)
    @test nrow(r) == 0
    @test names_of(r) == [:id, :name, :value]
    @test T(r, :value) == Float64
end

@testitem "pivot_longer: names_sep, names_pattern, .value" tags = [:unit] setup = [PV] begin
    r = pivot_longer(r"^x"; names_to = [:v, :n], names_sep = "_")(w)
    @test names_of(r) == [:id, :y, :v, :n, :value]
    @test eq(col(r, :v), fill("x", 6))
    @test eq(col(r, :n), ["1", "2", "1", "2", "1", "2"])
    r = pivot_longer(r"^x"; names_to = ["a", "b"], names_pattern = r"(.)_(.)")(w)
    @test eq(col(r, :b), ["1", "2", "1", "2", "1", "2"])
    # too few pieces become missing; too many are dropped (tidyr warns)
    t = (id = [1], a_b = [1], c = [2], d_e_f = [3])
    r = pivot_longer(Not(:id); names_to = [:p, :q], names_sep = "_")(t)
    @test eq(col(r, :p), ["a", "c", "d"])
    @test eq(col(r, :q), ["b", missing, "e"])
    @test T(r, :q) == Union{Missing, eltype(col(r, :p))}
    r = pivot_longer(Not(:id); names_to = [:p, :q], names_pattern = r"(.)_(.)")((id = [1], a_b = [1], c = [2]))
    @test eq(col(r, :p), ["a", missing])
    # `nothing` in names_to drops that part
    r = pivot_longer(Not(:id); names_to = [:p, nothing], names_sep = "_")((id = [1], a_b = [1]))
    @test names_of(r) == [:id, :p, :value]
    # .value: one value column per name part, in first-appearance order; missing combos are missing
    t = (id = [1, 2], a_1 = [1, 2], a_2 = [3, 4], b_1 = ["p", "q"])
    r = pivot_longer(Not(:id); names_to = [".value", "k"], names_sep = "_")(t)
    @test names_of(r) == [:id, :k, :a, :b]
    @test eq(col(r, :id), [1, 1, 2, 2])
    @test eq(col(r, :k), ["1", "2", "1", "2"])
    @test eq(col(r, :a), [1, 3, 2, 4])
    @test eq(col(r, :b), ["p", missing, "q", missing])
    t = (id = [1, 2], x_a = [1.0, missing], y_a = [missing, missing])
    r = pivot_longer(Not(:id); names_to = ["k", ".value"], names_sep = "_", values_drop_na = true)(t)
    @test eq(col(r, :id), [1]) && eq(col(r, :k), ["x"])
    r = pivot_longer([:x, :y]; names_to = ".value")((id = [1, 2], x = [1, 2], y = [3, 4]))
    @test names_of(r) == [:id, :x, :y]
    @test nrow(r) == 2
    @test_throws ArgumentError pivot_longer(Not(:id); names_to = [".value", ".value"], names_sep = "_")((id = [1], a_x = [1]))
    # option errors
    @test_throws ArgumentError pivot_longer(r"x"; names_to = [:a, :b])
    @test_throws ArgumentError pivot_longer(r"x"; names_to = [:a, :b], names_sep = "_", names_pattern = r"(.)(.)")
    @test_throws ArgumentError pivot_longer(Not(:id); names_to = [:a, :b], names_pattern = r"(.)")((id = [1], ab = [1]))
end

@testitem "pivot_longer: grouping and show" tags = [:unit] setup = [PV] begin
    g = group_by(:y)(w)
    r = pivot_longer(r"^x")(g)
    @test groupcols(r) == [:y]
    @test eq(col((pivot_longer(r"^x") ⨟ summarise(n = n_rows()))(g), :n), [2, 2, 2])
    # a pivoted grouping column drops out of the grouping
    r = pivot_longer([:id, :x_1])(group_by(:id)(w))
    @test groupcols(r) == Symbol[]
    @test repr(pivot_longer(r"^x"; names_to = :k)) == "pivot_longer(r\"^x\"; names_to = :k)"
    @test repr(pivot_longer(:a; names_to = [".value", :n], names_sep = "_", values_drop_na = true)) ==
        "pivot_longer(:a; names_to = [\".value\", :n], names_sep = \"_\", values_drop_na = true)"
end

@testitem "pivot_wider: basic, order, fill, prefix, sort" tags = [:unit] setup = [PV] begin
    d = (id = [2, 1, 2, 1, 3], k = ["b", "a", "a", "c", "b"], v = [1.0, 2.0, 3.0, missing, 5.0], w = ["p", "q", "r", "s", "t"])
    r = pivot_wider(names_from = :k, values_from = :v, id_cols = :id)(d)
    @test names_of(r) == [:id, :b, :a, :c]
    @test eq(col(r, :id), [2, 1, 3])
    @test eq(col(r, :b), [1.0, missing, 5.0])
    @test eq(col(r, :a), [3.0, 2.0, missing])
    @test eq(col(r, :c), [missing, missing, missing])
    @test T(r, :a) == Union{Missing, Float64}
    # default id_cols: every other column
    r = pivot_wider(names_from = :k, values_from = :v)(d)
    @test names_of(r) == [:id, :w, :b, :a, :c]
    @test nrow(r) == 5
    # names_sort, names_prefix
    @test names_of(pivot_wider(names_from = :k, values_from = :v, id_cols = :id, names_sort = true)(d)) == [:id, :a, :b, :c]
    @test names_of(pivot_wider(names_from = :k, values_from = :v, id_cols = :id, names_prefix = "k_")(d)) == [:id, :k_b, :k_a, :k_c]
    # values_fill: only the absent cells, not the existing missing
    r = pivot_wider(names_from = :k, values_from = :v, id_cols = :id, values_fill = 0.0)(d)
    @test eq(col(r, :c), [0.0, missing, 0.0])
    @test eq(col(r, :b), [1.0, 0.0, 5.0])
    # a non-nullable value column with a fill stays non-nullable
    r = pivot_wider(names_from = :k, values_from = :w, id_cols = :id, values_fill = "zz")(d)
    @test eq(col(r, :c), ["zz", "s", "zz"])
    @test !(Missing <: T(r, :c))
    r = pivot_wider(names_from = :k, values_from = :w, id_cols = :id)(d)
    @test Missing <: T(r, :c)                        # declared nullable even if no cell is absent
    # multiple values_from: {value}{sep}{prefix}{name}, value-major order
    r = pivot_wider(names_from = :k, values_from = [:v, :w], id_cols = :id)(d)
    @test names_of(r) == [:id, :v_b, :v_a, :v_c, :w_b, :w_a, :w_c]
    r = pivot_wider(names_from = :k, values_from = r"^[vw]$", id_cols = :id, names_sep = ".", names_prefix = "P")(d)
    @test names_of(r)[2:3] == Symbol.(["v.Pb", "v.Pa"])
    r = pivot_wider(names_from = :k, values_from = [:v, :w], id_cols = :id, values_fill = (v = 0.0,))(d)
    @test eq(col(r, :v_c), [0.0, missing, 0.0])
    @test eq(col(r, :w_c), [missing, "s", missing])
    # multiple names_from joined by names_sep
    r = pivot_wider(names_from = [:k, :w], values_from = :v, id_cols = :id)(d)
    @test names_of(r) == [:id, :b_p, :a_q, :a_r, :c_s, :b_t]
end

@testitem "pivot_wider: duplicates, values_fn, missing names, empty, numbers" tags = [:unit] setup = [PV] begin
    dd = (id = [1, 1, 2], k = ["a", "a", "a"], v = [1, 2, 3])
    err = try
        pivot_wider(names_from = :k, values_from = :v)(dd)
        nothing
    catch e
        e
    end
    @test err isa ArgumentError && occursin("values_fn", err.msg)
    r = pivot_wider(names_from = :k, values_from = :v, values_fn = sum)(dd)
    @test eq(col(r, :a), [3, 3])
    r = pivot_wider(names_from = :k, values_from = :v, values_fn = length)(dd)
    @test eq(col(r, :a), [2, 1])
    r = pivot_wider(names_from = :k, values_from = :v, values_fn = (v = maximum,))(dd)
    @test eq(col(r, :a), [2, 3])
    r = pivot_wider(names_from = :k, values_from = :v, values_fn = v -> sum(v) / length(v), values_fill = 0.0)((id = [1, 1, 2], k = ["a", "a", "b"], v = [1, 2, 3]))
    @test eq(col(r, :a), [1.5, 0.0]) && eq(col(r, :b), [0.0, 3.0])
    # missing in names_from is named "NA"; sorts last with names_sort
    dn = (k = ["b", "a", missing], v = [1, 2, 3])
    @test names_of(pivot_wider(names_from = :k, values_from = :v)(dn)) == [:b, :a, :NA]
    @test names_of(pivot_wider(names_from = :k, values_from = :v, names_sort = true)(dn)) == [:a, :b, :NA]
    # several names_from columns with a missing part (regression: joining String "NA" with
    # StrView parts hit a StringViews `write` ambiguity on Julia 1.13)
    r = pivot_wider(names_from = [:k, :j], values_from = :v)((id = [1, 1], k = Union{Missing, String}[missing, "a"], j = Union{Missing, String}["x", missing], v = [1, 2]))
    @test names_of(r) == [:id, :NA_x, :a_NA]
    # missing in id columns is one id
    r = pivot_wider(names_from = :k, values_from = :v)((id = [missing, 1, missing], k = ["a", "a", "b"], v = [1, 2, 3]))
    @test eq(col(r, :id), [missing, 1])
    @test eq(col(r, :b), [3, missing])
    # numeric names use Julia's `string` (R writes 10, Julia 10.0; documented)
    r = pivot_wider(names_from = :k, values_from = :v)((id = [1, 1], k = [2.5, 10.0], v = [1, 2]))
    @test names_of(r) == [:id, Symbol("2.5"), Symbol("10.0")]
    # empty input: only the id columns
    r = pivot_wider(names_from = :k, values_from = :v, id_cols = :id)((id = Int[], k = String[], v = Float64[]))
    @test names_of(r) == [:id] && nrow(r) == 0
    # no id columns: one row
    r = pivot_wider(names_from = :k, values_from = :v)((k = ["x", "y"], v = [1, 2]))
    @test nrow(r) == 1 && eq(col(r, :y), [2])
    @test_throws ArgumentError pivot_wider(names_from = :nope, values_from = :v)((k = ["x"], v = [1]))
    @test_throws ArgumentError pivot_wider(names_from = :k, values_from = :v)((id = [1], k = ["id"], v = [1]))   # name clash
end

@testitem "pivot_wider: grouping and show" tags = [:unit] setup = [PV] begin
    d = (id = [2, 1, 2], k = ["b", "a", "a"], v = [1, 2, 3])
    r = pivot_wider(names_from = :k, values_from = :v)(group_by(:id)(d))
    @test groupcols(r) == [:id]
    @test eq(col(r, :id), [2, 1])                    # first appearance, not group order
    r = pivot_wider(names_from = :k, values_from = :v)(group_by(:k)(d))
    @test groupcols(r) == Symbol[]                   # the grouping column became names
    @test occursin("pivot_wider", repr(pivot_wider(names_from = :k, values_from = :v)))
    # round trip
    w = (id = [1, 2], a = [1, 2], b = [3, 4])
    @test frame_equal(
        (pivot_longer([:a, :b]) ⨟ pivot_wider(values_fill = 0))(w),
        Frame(id = [1, 2], a = [1, 2], b = [3, 4]),
    )
end
