# Unit tests for the phase-2b ranking tail (plan item 3): percent_rank, cume_dist, ntile;
# slice_sample(weight_by); group_by(drop = false); arrange(locale); when_any/when_all; and the
# declared result type `c.x |> typed(T, f)` (ADR-0002 rule 11). Expected values for the ranks and
# when_any/when_all were computed with dplyr 1.2.0 (R 4.4); the differential item re-checks them.

@testsnippet RT begin
    using Tables, Statistics
    using DataAPI: nrow
    using Random: Xoshiro
    const ⨟ = ChuiFrames.Upstream.:⨟
    col(x, n) = collect(Tables.getcolumn(x, n))
    eq(a, b) = isequal(a, b)
    approx(a, b) = length(a) == length(b) && all(((x, y),) -> (ismissing(x) && ismissing(y)) || (!ismissing(x) && !ismissing(y) && (isequal(x, y) || isapprox(x, y; atol = 1.0e-12))), zip(a, b))
    # the dplyr probe vector: missing, NaN, ±0.0, ±Inf, ties
    X = (x = Union{Missing, Float64}[3.0, 1.0, missing, NaN, 1.0, -0.0, 0.0, Inf, -Inf, 2.0],)
    # a dictionary-encoded key: dictionary ["c", "b", "a", "d"], rows b, a, b
    fkey() = ChuiFrames.DictColumn(UInt8[2, 3, 2], ChuiFrames.column(["c", "b", "a", "d"]))
end

# ---------------------------------------------------------------------------------------------
# percent_rank, cume_dist, ntile

@testitem "percent_rank / cume_dist: dplyr values, missing and NaN stay missing" tags = [:unit] setup = [RT] begin
    m = missing
    r = mutate(p = percent_rank(c.x), d = cume_dist(c.x), pd = percent_rank(desc(c.x)), dd = cume_dist(desc(c.x)))(X)
    @test approx(col(r, :p), [6 / 7, 3 / 7, m, m, 3 / 7, 1 / 7, 1 / 7, 1.0, 0.0, 5 / 7])
    @test approx(col(r, :d), [0.875, 0.625, m, m, 0.625, 0.375, 0.375, 1.0, 0.125, 0.75])
    @test approx(col(r, :pd), [1 / 7, 3 / 7, m, m, 3 / 7, 5 / 7, 5 / 7, 0.0, 1.0, 2 / 7])
    @test approx(col(r, :dd), [0.25, 0.625, m, m, 0.625, 0.875, 0.875, 0.125, 1.0, 0.375])
    # one value: percent_rank is 0/0 = NaN (as dplyr), cume_dist 1
    r1 = mutate(p = percent_rank(c.v), d = cume_dist(c.v))((v = [5],))
    @test eq(col(r1, :p), [NaN]) && col(r1, :d) == [1.0]
    # all missing / empty
    @test all(ismissing, col(mutate(p = percent_rank(c.v))((v = [missing, missing],)), :p))
    @test isempty(col(mutate(p = percent_rank(c.v), d = cume_dist(c.v))((v = Float64[],)), :p))
    # Symbol argument, Bool and String values
    @test col(mutate(p = percent_rank(:v))((v = [true, false],)), :p) == [1.0, 0.0]
    @test col(mutate(d = cume_dist(c.s))((s = ["b", "a", "c", "a"],)), :d) == [0.75, 0.5, 1.0, 0.5]
end

@testitem "percent_rank / cume_dist: per group, static types" tags = [:unit] setup = [RT] begin
    t = (g = ["a", "b", "a", "b", "a"], v = [3, 1, 2, 2, 1])
    r = (group_by(:g) ⨟ mutate(p = percent_rank(c.v), d = cume_dist(desc(c.v))))(t)
    @test col(r, :p) == [1.0, 0.0, 0.5, 1.0, 0.0]
    @test col(r, :d) == [1 / 3, 1.0, 2 / 3, 0.5, 1.0]
    # Int argument: Float64; Float64 (may be NaN) or nullable: Union{Missing, Float64}
    @test eltype(col(mutate(p = percent_rank(c.v))(t), :p)) === Float64
    @test eltype(col(mutate(p = cume_dist(c.v))(t), :p)) === Float64
    @test eltype(col(mutate(p = percent_rank(c.v))((v = [1.0, 2.0],)), :p)) === Union{Missing, Float64}
    @test eltype(col(mutate(p = cume_dist(c.v))((v = Union{Missing, Int}[1, 2],)), :p)) === Union{Missing, Float64}
    # nodes: structural equality, printing
    @test percent_rank(c.x) == percent_rank(c.x) && percent_rank(c.x) != cume_dist(c.x)
    @test hash(cume_dist(desc(c.x))) == hash(cume_dist(desc(c.x)))
    @test sprint(show, percent_rank(c.x)) == "percent_rank(c.x)"
    @test sprint(show, cume_dist(desc(c.x))) == "cume_dist(desc(c.x))"
end

@testitem "ntile: dplyr bins, ties by row order, missing/NaN, no-x form" tags = [:unit] setup = [RT] begin
    m = missing
    r = mutate(t = ntile(c.x, 3), td = ntile(desc(c.x), 3))(X)
    @test eq(col(r, :t), [3, 2, m, m, 2, 1, 1, 3, 1, 2])
    @test eq(col(r, :td), [1, 2, m, m, 2, 2, 3, 1, 3, 1])
    v(x) = (v = x,)
    @test col(mutate(t = ntile(c.v, 3))(v(1:7)), :t) == [1, 1, 1, 2, 2, 3, 3]
    @test col(mutate(t = ntile(c.v, 5))(v(1:2)), :t) == [1, 2]                  # more tiles than rows
    @test col(mutate(t = ntile(c.v, 2))(v([1, 1, 1, 2, 2])), :t) == [1, 1, 1, 2, 2]
    @test col(mutate(t = ntile(c.v, 2))(v(["b", "a", "c"])), :t) == [1, 1, 2]
    @test col(mutate(t = ntile(c.v, 2.0))(v(1:4)), :t) == [1, 1, 2, 2]          # a whole Float is accepted
    @test all(ismissing, col(mutate(t = ntile(c.v, 2))(v([missing, missing])), :t))
    # ntile(n = k): bins of row_number(), per group
    t = (g = [1, 1, 1, 2, 2], x = [2.0, 1.0, missing, 3.0, 4.0])
    @test col((group_by(:g) ⨟ mutate(t = ntile(n = 2)))(t), :t) == [1, 1, 2, 1, 2]
    @test col(mutate(t = ntile(n = 2))(t), :t) == [1, 1, 1, 2, 2]
    @test col((group_by(:g) ⨟ mutate(t = ntile(c.x, 2)))(t), :t) |> x -> eq(x, [2, 1, missing, 1, 2])
    # n must be a positive whole number (dplyr errors)
    @test_throws ArgumentError ntile(c.x, 0)
    @test_throws ArgumentError ntile(c.x, -1)
    @test_throws ArgumentError ntile(c.x, 2.5)
    @test_throws ArgumentError ntile(c.x, missing)
    @test_throws ArgumentError ntile(n = 0)
    # static types
    @test eltype(col(mutate(t = ntile(c.v, 2))(v(1:4)), :t)) === Int
    @test eltype(col(mutate(t = ntile(n = 2))(v(1:4)), :t)) === Int
    @test eltype(col(mutate(t = ntile(c.v, 2))(v([1.0, 2.0])), :t)) === Union{Missing, Int}
    @test sprint(show, ntile(c.x, 3)) == "ntile(c.x, 3)"
    @test sprint(show, ntile(n = 3)) == "ntile(n = 3)"
    @test ntile(c.x, 3) == ntile(c.x, 3) && ntile(c.x, 3) != ntile(c.x, 4)
end

# ---------------------------------------------------------------------------------------------
# slice_sample(weight_by)

@testitem "slice_sample(weight_by): zero weights, n, errors as dplyr" tags = [:unit] setup = [RT] begin
    t = (x = 1:4, w = [1.0, 0.0, 2.0, 3.0])
    for seed in 1:200
        s = slice_sample(n = 3, weight_by = c.w, rng = Xoshiro(seed))(t)
        @test nrow(s) == 3 && allunique(col(s, :x)) && !(2 in col(s, :x))
    end
    for seed in 1:50   # with replacement: the zero-weight row is never drawn
        s = slice_sample(n = 20, replace = true, weight_by = :w, rng = Xoshiro(seed))(t)
        @test nrow(s) == 20 && !(2 in col(s, :x))
    end
    # Symbol and node give the same draw; prop works; an expression works
    @test col(slice_sample(n = 2, weight_by = :w, rng = Xoshiro(3))(t), :x) == col(slice_sample(n = 2, weight_by = c.w, rng = Xoshiro(3))(t), :x)
    @test nrow(slice_sample(prop = 0.5, weight_by = c.w, rng = Xoshiro(1))(t)) == 2
    @test nrow(slice_sample(n = 2, weight_by = c.w .* 2, rng = Xoshiro(1))(t)) == 2
    # dplyr (sample.int) errors: more rows than positive weights, NA/NaN/Inf, negative,
    # all-zero with replacement, non-numeric, a constant weight (size 1, not n)
    @test_throws ArgumentError slice_sample(n = 4, weight_by = c.w)(t)
    @test_throws ArgumentError slice_sample(n = 10, weight_by = c.w)(t)       # capped to 4, still too few
    @test_throws ArgumentError slice_sample(n = 2, weight_by = c.v)((x = 1:3, v = [1.0, missing, 2.0]))
    @test_throws ArgumentError slice_sample(n = 2, weight_by = c.v)((x = 1:3, v = [1.0, NaN, 2.0]))
    @test_throws ArgumentError slice_sample(n = 2, weight_by = c.v)((x = 1:3, v = [1.0, Inf, 2.0]))
    @test_throws ArgumentError slice_sample(n = 2, weight_by = c.v)((x = 1:3, v = [1.0, -1.0, 2.0]))
    @test_throws ArgumentError slice_sample(n = 2, replace = true, weight_by = c.v)((x = 1:3, v = [0, 0, 0]))
    @test_throws ArgumentError slice_sample(n = 2, weight_by = c.v)((x = 1:3, v = ["a", "b", "c"]))
    @test_throws ArgumentError slice_sample(n = 2, weight_by = lit(1.0))(t)
    @test_throws ArgumentError slice_sample(n = 1, weight_by = 1.0)
    # size 0: no draw, so no weight check (dplyr's sample_int returns integer(0) first)
    @test nrow(slice_sample(n = 0, weight_by = c.v)((x = 1:3, v = [1.0, missing, 2.0]))) == 0
    # Int and Bool weights
    @test col(slice_sample(n = 1, weight_by = c.v, rng = Xoshiro(1))((x = 1:3, v = [0, 5, 0])), :x) == [2]
    @test col(slice_sample(n = 1, weight_by = c.v, rng = Xoshiro(1))((x = 1:3, v = [false, false, true])), :x) == [3]
    @test occursin("weight_by = c.w", sprint(show, slice_sample(n = 2, weight_by = :w)))
    @test occursin("replace = true", sprint(show, slice_sample(n = 2, replace = true)))
end

@testitem "slice_sample(weight_by): per group, frequency sanity check" tags = [:unit] setup = [RT] begin
    t = (g = ["a", "a", "a", "b", "b"], x = 1:5, w = [0.0, 1.0, 1.0, 1.0, 0.0])
    for seed in 1:50
        s = (group_by(:g) ⨟ slice_sample(n = 1, weight_by = c.w, rng = Xoshiro(seed)))(t)
        @test col(s, :g) == ["a", "b"] && col(s, :x)[2] == 4 && col(s, :x)[1] in (2, 3)
    end
    # weights need not sum to 1: P(x = 2) = 3/4
    f = (x = 1:2, w = [1.0, 3.0])
    s = slice_sample(n = 40_000, replace = true, weight_by = c.w, rng = Xoshiro(2026))(f)
    p = count(==(2), col(s, :x)) / 40_000
    @test abs(p - 0.75) < 0.01
    # without replacement, first draws follow the weights too: P(first = 2) = 3/4
    firsts = [col(slice_sample(n = 2, weight_by = c.w, rng = Xoshiro(k))(f), :x)[1] for k in 1:4000]
    @test abs(count(==(2), firsts) / 4000 - 0.75) < 0.03
    # a group whose weights are all zero cannot give a row
    @test_throws ArgumentError (group_by(:g) ⨟ slice_sample(n = 1, weight_by = c.v))((g = ["a", "b"], v = [1.0, 0.0]))
end

# ---------------------------------------------------------------------------------------------
# group_by(drop = false)

@testitem "group_by(drop = false): empty levels of a dictionary key" tags = [:unit] setup = [RT] begin
    df = Frame((f = fkey(), g = [1.0, 2.0, 1.0], x = [1.0, 2.0, 3.0]))
    gd = group_by(:f; drop = false)(df)
    @test ChuiFrames.ngroups(gd.gindex) == 4
    # groups in CF-008's isless order of the key values (dplyr: level order c, b, a, d)
    r = summarise(n = n_rows(), s = sum(c.x), m = mean(c.x))(gd)
    @test col(r, :f) == ["a", "b", "c", "d"]
    @test col(r, :n) == [1, 2, 0, 0] && col(r, :s) == [2.0, 4.0, 0.0, 0.0]
    @test eq(col(r, :m), [2.0, 2.0, NaN, NaN])
    @test eltype(col(r, :n)) === Int
    @test Tables.getcolumn(r, :f) isa ChuiFrames.DictColumn   # the key column stays dictionary-encoded
    @test_throws ArgumentError summarise(mx = maximum(c.x))(gd)   # CC-007 (dplyr warns, gives -Inf)
    @test col(reframe(n = n_rows())(gd), :n) == [1, 2, 0, 0]
    # default drop = true: only observed levels
    @test col((group_by(:f) ⨟ summarise(n = n_rows()))(df), :n) == [1, 2]
    # mutate and windows on a frame with empty groups (empty groups give no rows)
    m = mutate(s = sum(c.x), r = row_number(), mx = maximum(c.x))(gd)
    @test col(m, :s) == [4.0, 2.0, 4.0] && col(m, :r) == [1, 1, 2] && col(m, :mx) == [3.0, 2.0, 3.0]
    @test ChuiFrames.ngroups(m.gindex) == 4                 # mutate keeps the index
    @test col(summarise(n = n_rows())(m), :n) == [1, 2, 0, 0]
    @test col(slice_head(n = 1)(gd), :x) == [2.0, 1.0]
    @test nrow(slice_sample(n = 1, rng = Xoshiro(1))(gd)) == 2
    @test nrow(slice_min(c.x)(gd)) == 2
    @test col(filter(c.x .> 1)(gd), :x) == [2.0, 3.0]
    @test occursin("[4]", sprint(show, MIME("text/plain"), gd))
    @test sprint(show, group_by(:f; drop = false)) == "group_by(:f; drop = false)"
    # dplyr keeps the empty groups after filter (the drop flag is a grouped_df attribute); here
    # the flag is not stored on the Frame yet, so filter rebuilds the index with drop = true
    @test_broken col((filter(c.x .> 1) ⨟ summarise(n = n_rows()))(gd), :n) == [1, 1, 0, 0]
end

@testitem "group_by(drop = false): several keys, missing, non-dictionary keys" tags = [:unit] setup = [RT] begin
    df = Frame((f = fkey(), g = [1.0, 2.0, 1.0], x = [1.0, 2.0, 3.0]))
    # dictionary key first: an empty level has `missing` for the later non-dictionary key
    r = (group_by(:f, :g; drop = false) ⨟ summarise(n = n_rows()))(df)
    @test col(r, :f) == ["a", "b", "c", "d"] && eq(col(r, :g), [2.0, 1.0, missing, missing]) && col(r, :n) == [1, 2, 0, 0]
    # non-dictionary key first: every level within each observed value
    r = (group_by(:g, :f; drop = false) ⨟ summarise(n = n_rows()))(df)
    @test col(r, :g) == [1.0, 1.0, 1.0, 1.0, 2.0, 2.0, 2.0, 2.0]
    @test col(r, :f) == ["a", "b", "c", "d", "a", "b", "c", "d"]
    @test col(r, :n) == [0, 2, 0, 0, 1, 0, 0, 0]
    @test groupcols(r) == [:g]
    # two dictionary keys: an empty first level crosses every level of the second
    h = ChuiFrames.DictColumn(UInt8[1, 1, 1], ChuiFrames.column(["x", "y"]))
    r = (group_by(:f, :h; drop = false) ⨟ summarise(n = n_rows(); groups = :drop))(Frame((f = fkey(), h = h)))
    @test col(r, :f) == ["a", "a", "b", "b", "c", "c", "d", "d"] && col(r, :h) == repeat(["x", "y"], 4)
    @test col(r, :n) == [1, 0, 2, 0, 0, 0, 0, 0]
    # an observed missing key is kept (last); missing is not added for empty prefixes
    fm = ChuiFrames.DictColumn(UInt8[2, 0], ChuiFrames.column(["a", "b"]), BitVector([true, false]))
    r = (group_by(:f; drop = false) ⨟ summarise(n = n_rows()))(Frame((f = fm,)))
    @test eq(col(r, :f), ["a", "b", missing]) && col(r, :n) == [0, 1, 1]
    # non-dictionary keys: a no-op (dplyr's .drop = FALSE keeps only factor levels)
    s = (a = ["x", "y", "x"], v = [1, 2, 3])
    @test col((group_by(:a; drop = false) ⨟ summarise(n = n_rows()))(s), :n) == [2, 1]
    # zero rows: one empty group per level
    z = Frame((f = ChuiFrames.DictColumn(UInt8[], ChuiFrames.column(["p", "q"])), x = Float64[]))
    r = (group_by(:f; drop = false) ⨟ summarise(n = n_rows(), s = sum(c.x)))(z)
    @test col(r, :f) == ["p", "q"] && col(r, :n) == [0, 0] && col(r, :s) == [0.0, 0.0]
    @test isempty(col(mutate(y = c.x .+ 1, r = row_number())(group_by(:f; drop = false)(z)), :y))
    # add = true keeps drop
    r = (group_by(:g) ⨟ group_by(:f; add = true, drop = false) ⨟ summarise(n = n_rows()))(df)
    @test length(col(r, :n)) == 8
end

@testitem "rowcodes: zero key columns give one code per row (lead, from tidyr-nest)" tags = [:unit] setup = [RT] begin
    rc = ChuiFrames.rowcodes
    @test rc(AbstractVector[], 3) == ([1, 1, 1], [1])
    @test rc(AbstractVector[], 0) == (Int[], Int[])
    @test rc(AbstractVector[[2, 1, 2]], 3) == rc(AbstractVector[[2, 1, 2]]) == ([1, 2, 1], [1, 2])
    @test_throws DimensionMismatch rc(AbstractVector[[1, 2]], 3)
end

# ---------------------------------------------------------------------------------------------
# arrange(locale)

@testitem "arrange(locale): C (codepoint) order only" tags = [:unit] setup = [RT] begin
    s = (s = Union{Missing, String}["b", "B", "a", "A", "é", "e", "Z", "z", "_", "1", missing],)
    want = ["1", "A", "B", "Z", "_", "a", "b", "e", "z", "é", missing]   # dplyr 1.2.0, .locale = "C"
    @test eq(col(arrange(c.s)(s), :s), want)
    @test eq(col(arrange(c.s; locale = "C")(s), :s), want)
    @test eq(col(arrange(c.s; locale = nothing)(s), :s), want)
    @test eq(col(arrange(desc(c.s); locale = "C")(s), :s), ["é", "z", "e", "b", "a", "_", "Z", "B", "A", "1", missing])
    err = try
        arrange(c.s; locale = "en")
        nothing
    catch e
        e
    end
    @test err isa ArgumentError && occursin("locale", err.msg) && occursin("\"C\"", err.msg)
    @test_throws ArgumentError arrange(c.s; locale = "en_US")
    @test sprint(show, arrange(c.s; locale = "C")) == "arrange(c.s; locale = \"C\")"
    @test sprint(show, arrange(c.s)) == "arrange(c.s)"
end

# ---------------------------------------------------------------------------------------------
# when_any / when_all

@testitem "when_any / when_all: Kleene logic, na_rm, errors" tags = [:unit] setup = [RT] begin
    m = missing
    t = (
        a = Union{Missing, Bool}[true, true, true, false, false, false, m, m, m],
        b = Union{Missing, Bool}[true, false, m, true, false, m, true, false, m],
    )
    r = mutate(an = when_any(c.a, c.b), al = when_all(c.a, c.b), anr = when_any(c.a, c.b; na_rm = true), alr = when_all(c.a, c.b; na_rm = true))(t)
    @test eq(col(r, :an), [true, true, true, true, false, m, true, m, m])
    @test eq(col(r, :al), [true, false, m, false, false, false, m, false, m])
    @test col(r, :anr) == [true, true, true, true, false, false, true, false, false]
    @test col(r, :alr) == [true, false, true, false, false, false, true, false, true]
    @test eltype(col(r, :anr)) === Bool && eltype(col(r, :an)) === Union{Missing, Bool}
    # Bool columns: Bool result; one argument; expressions; filter
    u = (x = [1, 2, 3, 4], y = [4, 3, 2, 1])
    r = mutate(z = when_any(c.x .> 3, c.y .> 3), w = when_all(c.x .> 1))(u)
    @test col(r, :z) == [true, false, false, true] && col(r, :w) == [false, true, true, true]
    @test eltype(col(r, :z)) === Bool
    @test col(filter(when_all(c.x .> 1, c.y .> 1))(u), :x) == [2, 3]
    @test col((group_by(:y) ⨟ filter(when_any(c.x .== 1, c.x .== 4)))(u), :x) == [1, 4]
    # scalars broadcast (dplyr requires equal sizes: a documented divergence)
    @test col(mutate(z = when_any(c.x .> 3, false))(u), :z) == [false, false, false, true]
    # errors: zero arguments, non-logical values (dplyr errors on both: logical(0) fits no rows)
    @test_throws ArgumentError when_any()
    @test_throws ArgumentError when_all()
    @test_throws ArgumentError mutate(z = when_any(c.x, c.y))(u)
    # vectors
    @test eq(when_any([true, false, missing], [false, false, false]), [true, false, missing])
    @test when_all([true, missing]; na_rm = true) == [true, true]
    @test_throws ArgumentError when_any([true, false], [true])
    # nodes: printing, equality, keep = :used
    @test sprint(show, when_any(c.a, c.b)) == "when_any(c.a, c.b)"
    @test sprint(show, when_all(c.a, c.b; na_rm = true)) == "when_all(c.a, c.b; na_rm = true)"
    @test when_any(c.a, c.b) == when_any(c.a, c.b) && when_any(c.a, c.b) != when_all(c.a, c.b)
    @test when_any(c.a) != when_any(c.a; na_rm = true)
    @test hash(when_all(c.a, c.b)) == hash(when_all(c.a, c.b))
    @test ChuiFrames.columnnames(mutate(z = when_any(c.x .> 1); keep = :used)(Frame(u))) == [:x, :z]
end

# ---------------------------------------------------------------------------------------------
# typed(T, f): the declared result type of `c.x |> f` (ADR-0002 rule 11)

@testitem "typed(T, f): plan-time predicate type, checked results" tags = [:unit] setup = [RT] begin
    t = (s = ["abc", "xyz", "bar"], x = [1, 2, 3], y = [1.5, 2.5, 3.5])
    hasa(v) = occursin.("a", v)
    p = c.s |> typed(Bool, hasa)
    @test p isa ChuiFrames.Pipe
    @test ChuiFrames.static_type(p, ChuiFrames.SelectCtx(Frame(t))) === Bool
    @test col(filter(p)(t), :s) == ["abc", "bar"]
    # without the declaration the type is unknown (Any): checked row by row
    @test ChuiFrames.static_type(c.s |> hasa, ChuiFrames.SelectCtx(Frame(t))) === Any
    # a declared non-Bool predicate fails at plan time, even with no rows
    @test_throws ArgumentError filter(c.x |> typed(Int, identity))(t)
    @test_throws ArgumentError filter(c.x |> typed(Int, identity))((x = Int[],))
    # mutate / summarise: the column type is the declared one
    r = mutate(z = c.y |> typed(Float64, v -> v .* 2))(t)
    @test col(r, :z) == [3.0, 5.0, 7.0] && eltype(col(r, :z)) === Float64
    r = mutate(z = c.x |> typed(Union{Missing, Int}, v -> [missing; v[2:end]]))(t)
    @test eq(col(r, :z), [missing, 2, 3]) && eltype(col(r, :z)) === Union{Missing, Int}
    r = (group_by(:s) ⨟ summarise(m = c.y |> typed(Float64, mean)))(t)
    @test col(r, :m) == [1.5, 3.5, 2.5] && eltype(col(r, :m)) === Float64
    @test col(mutate(m = c.x |> typed(Int, sum))(t), :m) == [6, 6, 6]   # a scalar in a column
    # results are checked, never converted
    err = try
        mutate(z = c.x |> typed(Float64, identity))(t)
        nothing
    catch e
        e
    end
    @test err isa ArgumentError && occursin("Float64", err.msg) && occursin("Int64", err.msg) && occursin("c.x", err.msg)
    @test_throws ArgumentError summarise(m = c.x |> typed(Int, mean))(t)
    @test_throws ArgumentError mutate(m = c.x |> typed(Int, mean))(t)
    @test_throws ArgumentError filter(c.x |> typed(Bool, v -> Int.(v .> 1)))(t)
    @test_throws ArgumentError typed(1, identity)
    # the wrapper: callable, printed as typed(T, f), structural equality
    tf = typed(Int, sum)
    @test tf isa ChuiFrames.Typed{Int}
    @test tf([1, 2]) == 3
    @test_throws ArgumentError tf([1.5])
    @test sprint(show, tf) == "typed(Int64, sum)"
    @test sprint(show, c.x |> typed(Int, sum)) == "(c.x |> typed(Int64, sum))"
    @test (c.x |> typed(Int, sum)) == (c.x |> typed(Int, sum))
    @test hash(c.x |> typed(Int, sum)) == hash(c.x |> typed(Int, sum))
    @test (c.x |> typed(Int, sum)) != (c.x |> typed(Float64, sum))
    @test (c.x |> typed(Int, sum)) != (c.x |> sum)
    # empty input: the declared type still gives the column type
    @test eltype(col(mutate(z = c.y |> typed(Float64, v -> v .* 2))((y = Float64[],)), :z)) === Float64
    @test eltype(col((group_by(:g) ⨟ mutate(z = c.y |> typed(Float64, v -> v .* 2)))((g = String[], y = Float64[])), :z)) === Float64
end
