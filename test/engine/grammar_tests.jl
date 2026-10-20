# The expression grammar (ADR-0002 rules 1-3, 7-10, 17, 18).

@testitem "grammar: c builds nodes (c.x, c[:x], c[\"a b\"])" tags = [:unit] begin
    using ChuiFrames: Col, Node, ColSet
    @test c.x isa Col && c.x.name === :x
    @test c[:x] == c.x
    @test c["a b"] == Col(Symbol("a b"))
    @test c.var"my col" == c["my col"]
    @test c[[:a, :b]] isa ColSet
    @test c[r"^x"] isa ColSet
    @test c[Not(:a)] isa ColSet
    @test propertynames(c) == ()
    @test (c.x .+ 1) isa Node
end

@testitem "grammar: broadcasting builds elementwise nodes, literal_pow is ^" tags = [:unit] begin
    using ChuiFrames: Call, Lit, Node
    n = c.x .^ 2
    @test n isa Call && n.f === (^) && n.args[2] == Lit(2)
    @test (@. c.x * 2 + 1) == ((c.x .* 2) .+ 1)
    @test ifelse.(c.x .> 0, c.x, 0) isa Call
    @test in.(c.g, Ref(Set([1, 2]))) isa Call
    @test (.!(c.b)) isa Call
    @test map(+, c.x, c.y) == Call(+, Node[c.x, c.y])
    # a fused non-node subexpression is materialized into a literal
    @test (c.x .+ (2 .* [1, 2])) == Call(+, Node[c.x, Lit([2, 4])])
end

@testitem "grammar: structural ==, isequal, hash (CF-005; ADR-0002 rule 2)" tags = [:unit] begin
    using Statistics
    @test (c.x == c.x) === true
    @test (c.x == c.y) === false
    @test ((c.x .+ 1) == (c.x .+ 1)) === true
    @test isequal(sum(c.x), sum(c.x))
    @test hash(c.x .+ 1) == hash(c.x .+ 1)
    @test hash(mean(c.x)) == hash(mean(c.x))
    @test (c.x .+ missing) == (c.x .+ missing)
    @test (c.x == missing) === false
    @test (missing == c.x) === false
    @test Dict((c.x .+ 1) => 1)[c.x .+ 1] == 1
    @test_throws MethodError c.x + 1
    @test_throws MethodError c.x > 1
    @test_throws MethodError !c.x
    # exactly three == methods with a node argument
    # (ArrowTimestamp's own == methods, ADR-0021, do not count: only those taking a node)
    ms = [
        m for m in methods(==) if m.module === ChuiFrames &&
            any(p -> p <: ChuiFrames.Node, Base.unwrap_unionall(m.sig).parameters[2:end])
    ]
    @test length(ms) == 3
end

@testitem "grammar: reductions are whole-column nodes; unsupported keywords rejected" tags = [:unit] begin
    using ChuiFrames: Reduce, Pipe, Window, SkipMiss
    using Statistics
    for n in (
            sum(c.x), prod(c.x), length(c.x), count(c.b), maximum(c.x), minimum(c.x), extrema(c.x),
            first(c.x), last(c.x), any(c.b), all(c.b), mean(c.x), median(c.x), std(c.x), var(c.x),
            quantile(c.x, 0.5), n_distinct(c.x), nth(c.x, 2), sum(abs, c.x), reduce(+, c.x),
        )
        @test n isa Reduce
    end
    @test (c.x |> sort) isa Pipe
    @test cumsum(c.x) isa Window && lag(c.x) isa Window && row_number() isa Window
    @test skipmissing(c.x) isa SkipMiss
    @test_throws ArgumentError sum(c.x; dims = 1)
    @test_throws ArgumentError sum(desc(c.x))
end

@testitem "grammar: coalesce/something guards are narrow (ADR-0002 rule 3)" tags = [:unit] begin
    @test_throws ArgumentError coalesce(c.x, 0)
    @test_throws ArgumentError something(c.x, 0)
    @test coalesce.(c.x, 0) isa ChuiFrames.Node
    # not guarded: single-argument and node-last forms, ismissing/isnothing
    @test coalesce(c.x) == c.x
    @test ismissing(c.x) === false
    @test isnothing(c.x) === false
    @test collect(skipmissing(Any[c.x, missing])) == [c.x]
end

@testitem "grammar: printing round-trips (ADR-0002 rule 18)" tags = [:unit] begin
    using Statistics
    nodes = [
        c.x, c.var"my col", c.var"end", c.x .+ 1, abs.(c.x), (c.a .> 1) .& (c.b .< 2), sum(c.x),
        mean(c.var"a b"), sum(skipmissing(c.x)), sum(abs, c.x), quantile(c.x, 0.25), nth(c.x, -1),
        cumsum(c.x), lag(c.x, 2), row_number(), row_number(desc(c.x)), n_rows(), desc(c.x),
        c.x .- mean(c.x), uppercase.(c.s), c.s .== "a", min_rank(c.x), std(c.x; corrected = false),
    ]
    m = Module()
    Core.eval(m, :(using ChuiFrames, Statistics))
    for n in nodes
        s = repr(n)
        back = Core.eval(m, Meta.parse(s))
        @test back == n
    end
    @test repr(c.var"my col") == "c.var\"my col\""
    @test repr(c.x .+ 1) == "(c.x .+ 1)"
    @test repr(sum(c.x)) == "sum(c.x)"
end

@testitem "grammar: selectors resolve (ADR-0002 rule 7)" tags = [:unit] begin
    using ChuiFrames: resolve, SelectCtx
    ctx = SelectCtx([:a, :x1, :x2, :s, :g], Type[Int, Float64, Union{Missing, Float64}, String, String], [:g])
    nm(sel) = ctx.names[resolve(sel, ctx)]
    @test nm(:a) == [:a]
    @test nm("s") == [:s]
    @test nm([:s, :a]) == [:s, :a]
    @test nm(r"^x") == [:x1, :x2]
    @test nm(startswith("x")) == [:x1, :x2]
    @test nm(where(Number)) == [:a, :x1, :x2]
    @test nm(where(T -> T <: AbstractString)) == [:s, :g]
    @test nm(Cols(:s, r"^x")) == [:s, :x1, :x2]
    @test nm(Between(:x1, :s)) == [:x1, :x2, :s]
    @test nm(All()) == ctx.names
    @test nm(Not(:a)) == [:x1, :x2, :s, :g]
    @test nm(Not([:a, :g])) == [:x1, :x2, :s]
    @test nm(everything()) == ctx.names
    @test nm(last_col()) == [:g]
    @test nm(last_col(1)) == [:s]
    @test nm(any_of([:z, :a])) == [:a]
    @test nm(group_cols()) == [:g]
    @test nm(c[[:a, :s]]) == [:a, :s]
    @test nm(2:3) == [:x1, :x2]
    @test_throws ArgumentError nm(:zz)
    @test_throws ArgumentError nm(each(round))
    # DataAPI/InvertedIndices bindings are re-exported, not redefined
    @test Cols === ChuiFrames.DataAPI.Cols && Between === ChuiFrames.DataAPI.Between && All === ChuiFrames.DataAPI.All
    @test Not === ChuiFrames.InvertedIndices.Not
end

@testitem "grammar: lints warn and can be silenced (ADR-0002 rule 17)" tags = [:unit] begin
    ChuiFrames._reset_lints!()
    @test_logs (:warn, r"chained comparison") (c.a .> 1 .& c.b .< 2)
    @test_logs (:warn, r"missing") (c.x .== missing)
    @test_logs (:warn, r"bare Bool") mutate(z = true)
    @test_logs mutate(z = lit(true))
    @test_logs (c.flags .& 0x04)                          # a bitmask is not linted
    @test_logs (:warn, r"elementwise") mutate(s = cumsum.(c.x))((x = [1, 2],))
    ChuiFrames.lints(false)
    @test_logs (c.x .== missing)
    ChuiFrames.lints(true)
end

@testitem "grammar: across/each/if_any/if_all (ADR-0002 rule 8)" tags = [:unit] begin
    using Tables, Statistics
    using DataAPI: nrow
    t = (g = [1, 1, 2], a = [1.5, 2.5, 3.5], b = [10.0, 20.0, 30.0], s = ["x", "y", "z"])
    r = Tables.columntable(mutate(across(where(AbstractFloat), each(round)))(t))
    @test r.a == round.(t.a) && r.b == t.b
    r = Tables.columntable(summarise(across([:a, :b], (mean, maximum)))(t))
    @test keys(r) == (:a_mean, :a_maximum, :b_mean, :b_maximum)
    @test r.a_mean == [mean(t.a)]
    r = Tables.columntable(summarise(across([:a], (m = mean,); names = "{fn}_of_{col}"))(t))
    @test keys(r) == (:m_of_a,)
    r = Tables.columntable(summarise(across(where(Number), v -> sum(v)))(group_by(:g)(t)))
    @test keys(r) == (:g, :a, :b)        # grouping columns are never selected
    @test r.a == [4.0, 3.5]
    @test_throws ArgumentError mutate(across(:a, string))(t)          # constant result
    @test_throws ArgumentError filter(if_any([:a], v -> isequal(v, 1)))(t)
    @test Tables.columntable(filter(if_any([:a, :b], v -> v .> 25))(t)).a == [3.5]
    @test Tables.columntable(filter(if_all([:a, :b], v -> v .> 2))(t)).a == [2.5, 3.5]
    @test nrow(filter(if_all(r"^zz", v -> v .> 0))(t)) == 3     # empty selection: true
    @test nrow(filter(if_any(r"^zz", v -> v .> 0))(t)) == 0     # empty selection: false
end
