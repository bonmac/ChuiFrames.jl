# Unit tests per verb: empty frames, all-missing columns, NaN, ±0.0, one-row groups, grouped
# and ungrouped.

@testsnippet V begin
    using Tables, Statistics
    using DataAPI: nrow
    const ⨟ = ChuiFrames.Upstream.:⨟
    ct(x) = Tables.columntable(x)
    col(x, n) = collect(Tables.getcolumn(x, n))
    eq(a, b) = isequal(a, b)
    t = (g = ["b", "a", "b", "a", "c"], x = [1.0, NaN, -0.0, 0.0, missing], y = [5, 4, 3, 2, 1])
    e = (g = String[], x = Float64[], y = Int[])
end

@testitem "filter: true keeps, false/missing drop, NaN follows IEEE (rules 11-12)" tags = [:unit] setup = [V] begin
    @test eq(col(filter(c.x .> 0.5)(t), :y), [5])
    @test eq(col(filter(.!(c.x .> 0.5))(t), :y), [4, 3, 2])        # NaN kept by the negation
    @test eq(col(filter(c.x .!= 1.0)(t), :y), [4, 3, 2])           # NaN .!= 1 is true
    @test eq(col(filter(c.y .> 1, c.y .< 5)(t), :y), [4, 3, 2])    # ANDed
    @test eq(col(filter(ismissing.(c.x))(t), :y), [1])
    @test nrow(filter(c.x .> 0)(e)) == 0
    @test eq(col(filter_out(c.y .> 3)(t), :y), [3, 2, 1])
    @test eq(col(filter_out(c.x .> 0.5)(t), :y), [4, 3, 2, 1])     # missing row kept
    # grouped: per-group evaluation
    @test eq(col((group_by(:g) ⨟ filter(c.y .== maximum(c.y)))(t), :y), [5, 4, 1])
    @test groupcols(filter(c.y .> 1)(group_by(:g)(t))) == [:g]
end

@testitem "filter: non-Bool conditions (rule 11)" tags = [:unit] setup = [V] begin
    @test_throws ArgumentError filter(c.y)(t)                      # Int: plan-time error
    @test_throws ArgumentError filter(c.y)(e)                      # ... even with no rows
    @test_throws ArgumentError filter(c.y .+ 1)(t)
    @test_throws ArgumentError filter(c.x)((x = Union{Missing, Float64}[1.0],))
    # abstract type: row by row
    # (Union{Missing,Integer}, not Any: column(Any[..., missing]) is a columns.jl bug, reported)
    o = (v = Union{Missing, Integer}[true, false, missing, true],)
    @test nrow(filter(c.v)(o)) == 2
    @test_throws ArgumentError filter(c.v)((v = Any[true, 1],))
    @test_throws ArgumentError filter(c.v)((v = Union{Missing, Integer}[true, 2],))
    @test nrow(filter(c.v)((v = Any[],))) == 0                     # empty chunk never raises
    @test_throws ArgumentError filter(c.y |> v -> v)(t)            # |> results are checked row by row
    @test nrow(filter(c.y |> v -> v .> 2)(t)) == 3
    @test nrow(filter(c.flags .& 0x01 .== 0x01)((flags = UInt8[1, 2, 3],))) == 2
end

@testitem "select, rename, rename_with, relocate (rules 7, 15)" tags = [:unit] setup = [V] begin
    @test keys(ct(select(:y, :g)(t))) == (:y, :g)
    @test keys(ct(select(Not(:x))(t))) == (:g, :y)
    @test keys(ct(select(where(Number))(t))) == (:x, :y)
    @test keys(ct(select(:yy => c.y)(t))) == (:yy,)
    @test col(select(:z => c.y .* 2)(t), :z) == [10, 8, 6, 4, 2]
    @test keys(ct(select(z = c.y)(t))) == (:z,)
    @test_throws ArgumentError select(:a => :b)
    @test keys(ct(select(:y)(group_by(:g)(t)))) == (:g, :y)       # grouping columns kept
    @test keys(ct(select(:y)(e))) == (:y,)
    r = rename(G = :g)(group_by(:g)(t))
    @test keys(ct(r)) == (:G, :x, :y) && groupcols(r) == [:G]
    @test keys(ct(rename("new name" => :x)(t))) == (:g, Symbol("new name"), :y)
    @test_throws ArgumentError rename(a = :zz)(t)
    @test_throws ArgumentError rename(y = :x)(t)                   # duplicate name
    @test keys(ct(rename_with(uppercase, [:g, :y])(t))) == (:G, :x, :Y)
    @test keys(ct(relocate(:y)(t))) == (:y, :g, :x)
    @test keys(ct(relocate(:g; after = :y)(t))) == (:x, :y, :g)
    @test keys(ct(relocate(:y; before = :x)(t))) == (:g, :y, :x)
end

@testitem "mutate: order, constants, removal, keep/before/after/by" tags = [:unit] setup = [V] begin
    r = mutate(z = c.y .* 2, w = c.z .+ 1)(t)
    @test col(r, :w) == [11, 9, 7, 5, 3]
    @test col(mutate(k = 1)(t), :k) == fill(1, 5)
    @test col(mutate(v = [1, 2, 3, 4, 5])(t), :v) == 1:5
    @test keys(ct(mutate(x = nothing)(t))) == (:g, :y)
    @test keys(ct(mutate(z = c.y .+ 1; keep = :used)(t))) == (:y, :z)
    @test keys(ct(mutate(z = c.y .+ 1; keep = :unused)(t))) == (:g, :x, :z)
    @test keys(ct(mutate(z = c.y .+ 1; keep = :none)(t))) == (:z,)
    @test keys(ct(mutate(z = c.y .+ 1; before = :x)(t))) == (:g, :z, :x, :y)
    @test keys(ct(mutate(z = c.y .+ 1; after = :g)(t))) == (:g, :z, :x, :y)
    r = mutate(m = mean(c.y); by = :g)(t)
    @test col(r, :m) == [4.0, 3.0, 4.0, 3.0, 1.0] && groupcols(r) == Symbol[]
    @test_throws ArgumentError mutate(m = mean(c.y); by = :g)(group_by(:g)(t))
    # grouped window and one-row groups
    r = (group_by(:g) ⨟ mutate(d = c.y .- mean(c.y), n = n_rows(), r = row_number()))(t)
    @test col(r, :d) == [1.0, 1.0, -1.0, -1.0, 0.0]
    @test col(r, :n) == [2, 2, 2, 2, 1]
    @test col(r, :r) == [1, 1, 2, 2, 1]
    @test_throws ArgumentError mutate(g = c.y)(group_by(:g)(t))   # grouping column
    @test nrow(mutate(z = c.x .+ 1)(e)) == 0
    @test nrow((group_by(:g) ⨟ mutate(z = maximum(c.x)))(e)) == 0  # no group is evaluated
    @test_throws ArgumentError mutate(z = maximum(c.x))(e)         # one empty "group": CC-007
    # all-missing column
    m = (a = [missing, missing],)
    @test eq(col(mutate(b = c.a .+ 1)(m), :b), [missing, missing])
    # CF-006 lengths
    @test col(mutate(r = c.y |> sortperm)(t), :r) == sortperm(t.y)
    @test_throws DimensionMismatch mutate(u = c.y |> unique)((y = [1, 1, 2],))
    @test col(mutate(s = c.y |> sum)(t), :s) == fill(15, 5)
end

@testitem "pull, arrange (rule 13)" tags = [:unit] setup = [V] begin
    @test collect(pull(:y)(t)) == t.y
    @test collect(pull()(t)) == t.y
    @test collect(pull(1)(t)) == t.g
    @test collect(pull(c.y .* 2)(t)) == 2 .* t.y
    x = (x = [3.0, NaN, -Inf, Inf, missing, 1.0, -0.0, 0.0], i = 1:8)
    @test col(arrange(c.x)(x), :i) == [3, 7, 8, 6, 1, 4, 2, 5]           # -0.0, 0.0 tied in input order
    @test col(arrange(desc(c.x))(x), :i) == [4, 1, 6, 7, 8, 3, 2, 5]     # NaN, missing last, input order
    @test col(arrange(desc(:x))(x), :i) == [4, 1, 6, 7, 8, 3, 2, 5]      # prototype regression 3
    s = (a = [2, 1, 2, 1], b = ["x", "y", "z", "w"])
    @test col(arrange(c.a, desc(c.b))(s), :b) == ["y", "w", "z", "x"]
    @test col(arrange(:a)(s), :b) == ["y", "w", "x", "z"]                # stable
    @test nrow(arrange(c.x)(e)) == 0
    g = arrange(c.y; by_group = true)(group_by(:g)(t))
    @test col(g, :g) == ["a", "a", "b", "b", "c"] && groupcols(g) == [:g]
end

@testitem "group_by keys: NaN/-NaN, ±0.0, missing (ADR-0003 rule 8)" tags = [:unit] setup = [V] begin
    k = (k = [0.0, -0.0, missing, NaN, 1.0, -NaN, missing], v = 1:7)
    r = (group_by(:k) ⨟ summarise(n = n_rows(), s = sum(c.v)))(k)
    @test eq(col(r, :k), [0.0, 1.0, NaN, missing])      # 4 groups, ascending, NaN before missing
    @test col(r, :n) == [2, 1, 2, 2]
    @test col(r, :s) == [3, 5, 10, 10]
    k2 = (k = [-0.0, 0.0], v = 1:2)
    r2 = (group_by(:k) ⨟ summarise(n = n_rows()))(k2)
    @test signbit(col(r2, :k)[1])                         # first one seen is shown
    s = (a = ["x", "y", "x"], b = [2, 1, 1], v = 1:3)
    r = (group_by(:a, :b) ⨟ summarise(s = sum(c.v)))(s)
    @test col(r, :a) == ["x", "x", "y"] && col(r, :b) == [1, 2, 1] && col(r, :s) == [3, 1, 2]
    @test groupcols(r) == [:a]                            # groups = :drop_last
    gb = group_by(:a)(s)
    @test groupcols(gb) == [:a] && gb.gindex !== nothing
    @test groupcols(group_by(:b; add = true)(gb)) == [:a, :b]
    @test groupcols(ungroup()(gb)) == Symbol[]
    @test groupcols(ungroup(:a)(group_by(:a, :b)(s))) == [:b]
    @test col((group_by(:k2 => c.b .* 10) ⨟ summarise(n = n_rows()))(s), :k2) == [10, 20]
    @test_throws ArgumentError group_by(:a; drop = false)
end

@testitem "summarise: groups option, empty input, by, reframe" tags = [:unit] setup = [V] begin
    s = (a = ["x", "y", "x"], b = [2, 1, 1], v = [1, 2, 3])
    @test groupcols((group_by(:a, :b) ⨟ summarise(n = n_rows(); groups = :keep))(s)) == [:a, :b]
    @test groupcols((group_by(:a, :b) ⨟ summarise(n = n_rows(); groups = :drop))(s)) == Symbol[]
    @test groupcols((group_by(:a) ⨟ summarise(n = n_rows()))(s)) == Symbol[]
    r = summarise(n = n_rows(), s = sum(c.v), m = mean(c.v), d = c.s .* 2)(s)
    @test col(r, :n) == [3] && col(r, :s) == [6] && col(r, :m) == [2.0] && col(r, :d) == [12]   # later sees earlier
    r = summarise(n = n_rows(), s = sum(c.x))(e)                   # empty ungrouped: one row
    @test col(r, :n) == [0] && col(r, :s) == [0]
    @test_throws ArgumentError summarise(m = maximum(c.x))(e)      # CC-007 on both Julias
    @test_throws BoundsError summarise(m = first(c.x))(e)
    @test nrow((group_by(:g) ⨟ summarise(m = maximum(c.x)))(e)) == 0
    @test eq(col(summarise(m = mean(c.x))(e), :m), [NaN])
    r = summarise(s = sum(c.v); by = :a)(s)
    @test col(r, :a) == ["x", "y"] && groupcols(r) == Symbol[]
    @test_throws ArgumentError summarise(z = c.v)(s)                # 3 values in one group
    r = summarise(v = c.v |> v -> v .* 2)(s)                        # |> result is one cell (CF-006)
    @test col(r, :v) == [[2, 4, 6]]
    r = (group_by(:a) ⨟ reframe(q = quantile(c.v, [0.0, 1.0])))(s)
    @test col(r, :a) == ["x", "x", "y", "y"] && col(r, :q) == [1.0, 3.0, 2.0, 2.0] && groupcols(r) == Symbol[]
    @test col(summarize(n = n_rows())(s), :n) == [3]
    @test summarize === summarise
    # all-missing and skipmissing
    m = (a = [missing, missing],)
    @test eq(col(summarise(s = sum(c.a), t = sum(skipmissing(c.a)), n = n_distinct(c.a))(m), :s), [missing])
    @test col(summarise(t = sum(skipmissing(c.a)))(m), :t) == [0]
    @test_throws ArgumentError summarise(t = maximum(skipmissing(c.a)))(m)
    @test_throws ArgumentError mutate(z = skipmissing(c.a))(m)
end

@testitem "slices: head, slice_head/tail, slice, slice_min/max, slice_sample" tags = [:unit] setup = [V] begin
    gt = group_by(:g)(t)
    @test col(head(2)(t), :y) == [5, 4]
    @test col(head(-3)(t), :y) == [5, 4]
    @test col(head(2)(gt), :y) == [5, 4]                     # head ignores groups
    @test col(slice_head(n = 1)(gt), :y) == [4, 5, 1]        # per group, in group order
    @test col(slice_tail(n = 1)(gt), :y) == [2, 3, 1]
    @test col(slice_head(prop = 0.5)(gt), :y) == [4, 5]
    @test col(slice_head(n = -1)(gt), :y) == [4, 5]
    @test col(slice(2)(gt), :y) == [2, 3]
    @test col(slice(Not(1))(t), :y) == [4, 3, 2, 1]
    @test col(slice(1:2, 9)(t), :y) == [5, 4]
    @test_throws ArgumentError slice(-1)(t)
    @test col(slice_min(c.y)(gt), :y) == [2, 3, 1]
    @test col(slice_max(c.y; n = 2)(t), :y) == [5, 4]
    ties = (v = [1, 2, 2, 3], i = 1:4)
    @test col(slice_max(c.v; n = 2)(ties), :i) == [4, 2, 3]
    @test col(slice_max(c.v; n = 2, with_ties = false)(ties), :i) == [4, 2]
    @test col(slice_min(c.x; n = 3)(t), :y) == [3, 2, 5]     # NaN/missing last
    @test col(slice_min(c.x; n = 5, na_rm = true)(t), :y) == [3, 2, 5]
    @test nrow(slice_head(n = 2)(e)) == 0
    s = slice_sample(n = 3)(t)
    @test nrow(s) == 3 && allunique(col(s, :y)) && all(in(t.y), col(s, :y))
    @test nrow(slice_sample(n = 10, replace = true)(t)) == 10
    @test nrow(slice_sample(n = 1)(gt)) == 3
    using Random: Xoshiro
    @test col(slice_sample(n = 3, rng = Xoshiro(7))(t), :y) == col(slice_sample(n = 3, rng = Xoshiro(7))(t), :y)
    @test nrow(slice_sample(prop = 0.5)(t)) == 2
end

@testitem "distinct, count_by, tally, add_count" tags = [:unit] setup = [V] begin
    d = (a = [0.0, -0.0, NaN, -NaN, missing, missing, 1.0], b = 1:7)
    @test eq(col(distinct(:a)(d), :a), [0.0, NaN, missing, 1.0])
    @test col(distinct(:a; keep_all = true)(d), :b) == [1, 3, 5, 7]
    @test nrow(distinct()(d)) == 7
    @test col(distinct(:z => c.b .% 2)(d), :z) == [1, 0]
    r = count_by(:g)(t)
    @test col(r, :g) == ["a", "b", "c"] && col(r, :n) == [2, 2, 1]
    @test col(count_by(:g; sort = true)(t), :n) == [2, 2, 1]
    @test col(count_by(:g; wt = c.y)(t), :n) == [6, 8, 1]
    @test col(count_by(:g; wt = :y, name = :w)(t), :w) == [6, 8, 1]
    @test col(count_by(:g; wt = c.m)((g = [1, 1], m = [1, missing])), :n) == [1]   # na.rm like dplyr
    @test col(count_by()(t), :n) == [5]
    @test keys(ct(count_by(:g)((g = [1], n = [2])))) == (:g, :nn)
    @test groupcols(count_by(:y)(group_by(:g)(t))) == [:g]
    @test col(tally()(group_by(:g)(t)), :n) == [2, 2, 1]
    @test col(tally()(t), :n) == [5]
    r = add_count(:g)(t)
    @test col(r, :n) == [2, 2, 2, 2, 1] && nrow(r) == 5
    @test col(add_tally()(t), :n) == fill(5, 5)
    @test nrow(count_by(:g)(e)) == 0
end

@testitem "bind_rows, bind_cols, set verbs" tags = [:unit] setup = [V] begin
    a = (k = [1, 2], s = ["x", "y"])
    b = (s = ["z"], k = [3], extra = [true])
    r = bind_rows(b)(a)
    @test col(r, :k) == [1, 2, 3] && eq(col(r, :extra), [missing, missing, true])
    @test col(bind_rows(b; id = :src)(a), :src) == [1, 1, 2]
    @test col(bind_rows("other" => b; id = :src)(a), :src) == ["1", "1", "other"]
    @test nrow(bind_rows(e)(t)) == 5
    @test keys(ct(bind_cols((z = [1, 2],))(a))) == (:k, :s, :z)
    @test keys(ct(bind_cols((k = [1, 2],))(a))) == (Symbol("k...1"), :s, Symbol("k...3"))
    @test_throws DimensionMismatch bind_cols((z = [1],))(a)
    x = (v = [1.0, 2.0, 2.0, NaN, 0.0],)
    y = (v = [2.0, -NaN, 5.0, -0.0],)
    @test eq(col(union_rows(y)(x), :v), [1.0, 2.0, NaN, 0.0, 5.0])
    @test eq(col(intersect_rows(y)(x), :v), [2.0, NaN, 0.0])
    @test eq(col(setdiff_rows(y)(x), :v), [1.0])
    @test eq(col(symdiff_rows(y)(x), :v), [1.0, 5.0])
    @test col(union_all(y)(x), :v) |> length == 9
    @test_throws ArgumentError union_rows((w = [1],))(x)
end

@testitem "window helpers: lag/lead/cum*/ranks/consecutive_id/case_when/between/na_if/nth" tags = [:unit] setup = [V] begin
    w = (g = [1, 1, 1, 2, 2], v = [30, 10, 10, 20, missing])
    r = mutate(
        l = lag(c.v), d = lead(c.v, 1; default = 0), s = cumsum(c.v), p = cumprod(c.v),
        m = cummean(c.v), a = accumulate(max, c.v)
    )(w)
    @test eq(col(r, :l), [missing, 30, 10, 10, 20])
    @test eq(col(r, :d), [10, 10, 20, missing, 0])
    @test eq(col(r, :s), [30, 40, 50, 70, missing])
    @test eq(col(r, :m), [30.0, 20.0, 50 / 3, 17.5, missing])
    gr = (group_by(:g) ⨟ mutate(l = lag(c.v), s = cumsum(c.v), r = row_number()))(w)
    @test eq(col(gr, :l), [missing, 30, 10, missing, 20])
    @test eq(col(gr, :s), [30, 40, 50, 20, missing])
    rk = (x = [30, 10, 10, 20],)
    @test col(mutate(r = min_rank(c.x))(rk), :r) == [4, 1, 1, 3]
    @test col(mutate(r = dense_rank(c.x))(rk), :r) == [3, 1, 1, 2]
    @test col(mutate(r = row_number(c.x))(rk), :r) == [4, 1, 2, 3]
    @test col(mutate(r = min_rank(desc(c.x)))(rk), :r) == [1, 3, 3, 2]
    fx = (x = [3.0, NaN, -Inf, Inf, missing, 1.0, -0.0, 0.0],)
    @test eq(col(mutate(r = row_number(c.x))(fx), :r), [5, missing, 1, 6, missing, 4, 2, 3])
    @test eq(col(mutate(r = min_rank(c.x))(fx), :r), [5, missing, 1, 6, missing, 4, 2, 2])
    @test col(mutate(i = consecutive_id(c.x))((x = [1, 1, 2, 2, 1, NaN, -NaN],)), :i) == [1, 1, 2, 2, 3, 4, 4]
    cw = (x = [3.0, NaN, missing, 0.5],)
    @test col(mutate(k = case_when((c.x .> 1) => "big", (c.x .<= 1) => "small"; default = "other"))(cw), :k) ==
        ["big", "other", "other", "small"]
    @test eq(col(mutate(k = case_when((c.x .> 1) => c.x))(cw), :k), [3.0, missing, missing, missing])
    @test eq(col(mutate(b = between(c.x, 0, 1))(cw), :b), [false, false, missing, true])
    @test eq(col(mutate(b = between.(c.x, 0, 1))(cw), :b), [false, false, missing, true])
    @test eq(col(mutate(n = na_if(c.x, 0.5))(cw), :n), [3.0, NaN, missing, missing])
    @test eq(col(summarise(a = nth(c.x, 1), b = nth(c.x, -1), z = nth(c.x, 9))(cw), :z), [missing])
    @test col(summarise(n = n_distinct(c.x))((x = [1, 1, 2, missing],)), :n) == [3]
    @test n_distinct([0.0, -0.0, NaN, -NaN]) == 2
end

@testitem "steps are values; printing; reserved keywords; mixing" tags = [:unit] setup = [V] begin
    p = filter(c.y .> 1) ⨟ group_by(:g) ⨟ summarise(m = mean(c.y))
    @test repr(p) == "filter((c.y .> 1)) ⨟ group_by(:g) ⨟ summarise(m = mean(c.y))"
    @test repr(mutate("a b" => c.y .+ 1)) == "mutate(\"a b\" => (c.y .+ 1))"
    @test eq(ct(p(t)), ct(t |> p))
    @test_throws ArgumentError mutate(across(:y, v -> v .+ 1); z = c.y)
    @test_throws ArgumentError summarise(across(:y, sum); n = n_rows())
    @test_throws ArgumentError mutate(1)
    @test_throws ArgumentError mutate(z = c.y; keep = :bogus)
end
