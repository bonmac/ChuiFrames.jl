# Typed per-group accumulators of the lazy hash-aggregate sink against the aggregator protocol
# (phase-4 spec §2.3, plan task 4; CC-004 to CC-007), the simple-aggregate recogniser (§2.1), and
# eager grouped `summarise` bitwise equal to the per-group protocol call (critic M5).

@testsnippet ACC begin
    using Statistics
    using Random: Xoshiro, rand
    const CF = ChuiFrames
    const UP = ChuiFrames.Upstream
    # Fold `v` (group ids `gid`, groups 1:ng) through the sink's accumulators: one run per morsel
    # (the rows split at `cuts`), each merged into the global accumulator in order, then final.
    function sinkfold(agg, v::AbstractVector, gid::Vector{Int}, ng::Int, cuts)
        T = eltype(v)
        glob = CF._newacc(agg, T)
        CF._grow!(glob, ng)
        bounds = [0; collect(cuts); length(v)]
        for k in 1:(length(bounds) - 1)
            rows = (bounds[k] + 1):bounds[k + 1]
            # local ids in first-seen order within the morsel, as a run's KeyTable gives them
            loc = Dict{Int, Int}()
            lids = Int[get!(loc, gid[r], length(loc) + 1) for r in rows]
            run = CF._newacc(agg, T)
            CF._grow!(run, length(loc))
            CF._fold!(run, lids, agg isa CF._NRowsAgg ? nothing : v[rows])
            back = zeros(Int, length(loc))
            for (g, l) in loc
                back[l] = g
            end
            CF._mergeinto!(glob, back, run, collect(1:length(loc)))
        end
        return [CF._finalvalue(glob, g) for g in 1:ng]
    end
    # the eager per-group protocol call (ev(::Reduce) of src/engine/interpreter.jl)
    proto(agg, v) = UP.aggregate(agg, UP.Map(identity), (v,))
    function outcome(f)
        try
            return (:ok, f())
        catch err
            return (:err, typeof(err))
        end
    end
    exact(a, b) = isequal(a, b) && typeof(a) == typeof(b)
    close_enough(a, b; rtol) = exact(a, b) || (a isa AbstractFloat && b isa AbstractFloat && typeof(a) == typeof(b) && isapprox(a, b; rtol, nans = true))
    # compare the sink with the protocol on every group, for several morsel splits
    function agrees(agg, v, gid, ng; rtol = 0.0)
        n = length(v)
        for cuts in ([], [1], [n ÷ 2], 1:2:(n - 1), 1:(n - 1))
            cuts = [c for c in cuts if 0 < c < n]
            s = outcome(() -> sinkfold(agg, v, gid, ng, cuts))
            es = [outcome(() -> proto(agg, v[findall(==(g), gid)])) for g in 1:ng]
            # the sink raises exactly when some group's protocol call raises
            s[1] === :err && (any(e -> e[1] === :err, es) ? continue : return false)
            for g in 1:ng
                e = es[g]
                e[1] === :err && return false
                same = rtol == 0 ? exact(s[2][g], e[2]) : close_enough(s[2][g], e[2]; rtol)
                same || return false
            end
        end
        return true
    end
end

@testitem "accumulators equal the protocol on Int8, Int32, Bool, Float32 (and Int, Float64, missing)" tags = [:unit] setup = [ACC] begin
    rng = Xoshiro(7)
    n = 23
    gid = [rand(rng, 1:4) for _ in 1:n]
    gid[1:4] = 1:4                                   # every group present
    cols = Any[
        Int8[rand(rng, Int8(-100):Int8(100)) for _ in 1:n],
        Int32[rand(rng, Int32(-10^9):Int32(10^9)) for _ in 1:n],
        Bool[rand(rng, Bool) for _ in 1:n],
        Float32[rand(rng, Float32[-0.0, 0.0, 1.5, -2.25, NaN32, 3.0]) for _ in 1:n],
        Int[rand(rng, -5:5) for _ in 1:n],
        Union{Missing, Float64}[rand(rng, Union{Missing, Float64}[missing, -0.0, 0.0, 2.5, NaN, Inf]) for _ in 1:n],
        Union{Missing, Int}[rand(rng, Union{Missing, Int}[missing, 1, 2, -3]) for _ in 1:n],
    ]
    exact_aggs = Any[
        UP.Sum(), UP.Prod(), UP.Max(), UP.Min(), UP.Extrema(), UP.First(), UP.Last(), UP.Count(),
        CF.SkipMissingAgg(UP.Sum()), CF.SkipMissingAgg(UP.Max()), CF.SkipMissingAgg(UP.First()),
        CF.SkipMissingAgg(UP.Count()), UP.ReduceM(+), UP.MapM(abs, UP.Sum()), UP.MapM(x -> x > 0, UP.CountTrue()),
    ]
    float_aggs = Any[UP.Mean(), CF.Spread(UP.Moments(false, true)), CF.Spread(UP.Moments(true, false)), CF.SkipMissingAgg(UP.Mean())]
    for v in cols
        T = eltype(v)
        isfloat = nonmissingtype(T) <: AbstractFloat
        for agg in exact_aggs
            # float sums associate differently per morsel (CC-004 tolerance); the rest is exact
            tol = isfloat && (agg isa UP.Sum || agg isa UP.Prod || agg isa CF.SkipMissingAgg{UP.Sum} || agg isa UP.ReduceM || agg isa UP.MapM) ?
                (nonmissingtype(T) === Float32 ? 1.0e-5 : 1.0e-12) : 0.0
            @test agrees(agg, v, gid, 4; rtol = tol)
        end
        for agg in float_aggs
            @test agrees(agg, v, gid, 4; rtol = nonmissingtype(T) === Float32 ? 1.0e-5 : 1.0e-12)
        end
        nonmissingtype(T) === Bool && for agg in (UP.CountTrue(), UP.AnyM(), UP.AllM())
            @test agrees(agg, v, gid, 4)
        end
    end
    # the widened sum type of Base (`add_sum`): Int8, Int32, Bool give Int; Float32 stays
    @test sinkfold(UP.Sum(), Int8[100, 100], [1, 1], 1, [1])[1] === 200
    @test sinkfold(UP.Sum(), Int32[1, 2], [1, 1], 1, [])[1] === 3
    @test sinkfold(UP.Sum(), Bool[true, true, false], [1, 1, 1], 1, [2])[1] === 2
    @test sinkfold(UP.Sum(), Float32[1, 2], [1, 1], 1, [1])[1] === 3.0f0
    # an empty group: the protocol's neutral or its error (CC-006, CC-007)
    @test sinkfold(UP.Sum(), Int8[], Int[], 1, [])[1] === sum(Int8[]) === 0
    @test sinkfold(UP.Prod(), Int[], Int[], 1, [])[1] === 1
    @test isnan(sinkfold(UP.Mean(), Float64[], Int[], 1, [])[1])
    @test ismissing(sinkfold(CF.Spread(UP.Moments(false, true)), Float64[], Int[], 1, [])[1])
    @test sinkfold(UP.Count(), Int[], Int[], 1, [])[1] === 0
    @test_throws ArgumentError sinkfold(UP.Max(), Int[], Int[], 1, [])
    @test_throws BoundsError sinkfold(UP.First(), Int[], Int[], 1, [])
    @test sinkfold(CF._NRowsAgg(), Int[1, 2, 3], [1, 2, 1], 2, [1]) == [2, 1]
    # strings: first/last/min/max exact, reduce(*) in row order across morsels
    s = ["b", "a", "c", "d", "e"]
    sg = [1, 2, 1, 2, 1]
    for agg in (UP.First(), UP.Last(), UP.Max(), UP.Min(), UP.ReduceM(*))
        @test agrees(agg, s, sg, 2)
    end
    @test sinkfold(UP.ReduceM(*), s, sg, 2, [1, 3]) == ["bce", "ad"]
    # non-Bool data in any/count raise, as the protocol does
    @test_throws TypeError sinkfold(UP.AnyM(), [1, 2], [1, 1], 1, [])
    @test outcome(() -> sinkfold(UP.CountTrue(), [1, 2], [1, 1], 1, []))[1] === :err
end

@testitem "accumulators: Mean over typemax(Int) across morsels does not overflow (N4)" tags = [:unit] setup = [ACC] begin
    v = fill(typemax(Int), 4)
    for cuts in ([], [1], [2], [1, 2, 3])
        m = sinkfold(UP.Mean(), v, [1, 1, 1, 1], 1, cuts)[1]
        @test m isa Float64
        @test isapprox(m, float(typemax(Int)); rtol = 1.0e-12)
        @test isapprox(m, mean(v); rtol = 1.0e-12)
    end
    @test CF._newacc(UP.Mean(), Int) isa CF._MeanAcc{Float64}
    @test CF._newacc(UP.Mean(), Union{Missing, Int32}) isa CF._MeanAcc{Union{Missing, Float64}}
    @test CF._newacc(UP.Sum(), Int8) isa CF._FoldAcc{UP.Sum, Int}
    @test CF._newacc(UP.Sum(), Float32) isa CF._FoldAcc{UP.Sum, Float32}
    @test CF._newacc(UP.Sum(), Union{Missing, Bool}) isa CF._FoldAcc{UP.Sum, Union{Missing, Int}}
    # Vector{Any} only for MapM and ReduceM
    @test CF._newacc(UP.ReduceM(*), String) isa CF._ProtoAcc
    @test CF._newacc(UP.MapM(abs, UP.Sum()), Int) isa CF._ProtoAcc
end

@testitem "accumulators widen to a new input type, keeping their states" tags = [:unit] setup = [ACC] begin
    for agg in (UP.Sum(), UP.Mean(), UP.First(), UP.Last(), UP.Max(), CF.Spread(UP.Moments(false, true)))
        a = CF._newacc(agg, Int)
        CF._grow!(a, 2)
        CF._fold!(a, [1, 2, 1], [1, 2, 3])
        @test CF._accepts(a, Int) && !CF._accepts(a, Union{Missing, Int})
        b = CF._widen(a, Union{Missing, Int})
        @test CF._accepts(b, Union{Missing, Int})
        CF._fold!(b, [2], Union{Missing, Int}[5])
        @test isequal(CF._finalvalue(b, 1), proto(agg, [1, 3]))
        @test isequal(CF._finalvalue(b, 2), proto(agg, [2, 5]))
        c = CF._widen(b, Float64)                     # no common concrete type: Any states
        CF._fold!(c, [1], [0.5])
        @test isapprox(CF._finalvalue(c, 1), proto(agg, Any[1, 3, 0.5]); nans = true)
    end
end

@testitem "simple-aggregate recogniser (phase-4 spec §2.1)" tags = [:unit] setup = [ACC] begin
    ok(x) = CF._simple_aggregate(x) isa Tuple
    why(x) = CF._simple_aggregate(x)
    for x in (
            sum(c.x), prod(c.x), mean(c.x), maximum(c.x), minimum(c.x), extrema(c.x), count(c.b), length(c.x),
            any(c.b), all(c.b), first(c.x), last(c.x), reduce(*, c.s), mapreduce(abs, +, c.x), sum(abs, c.x),
            var(c.x), std(c.x; corrected = false), sum(skipmissing(c.x)), mean(skipmissing(c.x)), n_rows(),
        )
        @test ok(x)
    end
    @test CF._simple_aggregate(sum(c.x)) == (UP.Sum(), :x)
    @test CF._simple_aggregate(n_rows()) == (CF._NRowsAgg(), nothing)
    @test why(median(c.x)) == "not a simple aggregate: `median`"
    @test why(quantile(c.x, 0.5)) == "not a simple aggregate: `quantile`"
    @test why(n_distinct(c.x)) == "not a simple aggregate: `n_distinct`"
    @test why(nth(c.x, 2)) == "not a simple aggregate: `nth`"
    @test startswith(why(sum(c.x) .+ 1), "not a simple aggregate: ")
    @test startswith(why(sum(c.x .* 2)), "not a simple aggregate: ")
    @test startswith(why(c.x |> sum), "not a simple aggregate: ")
    @test startswith(why(lit(1)), "not a simple aggregate: ")
end

@testitem "eager grouped summarise equals the per-group protocol call bitwise (critic M5)" tags = [:unit] setup = [ACC] begin
    rng = Xoshiro(11)
    n = 400
    g = [rand(rng, ["a", "b", "c", "d"]) for _ in 1:n]
    x = Union{Missing, Float64}[rand(rng) < 0.05 ? missing : randn(rng) * 10.0^rand(rng, -3:6) for _ in 1:n]
    y = Float32[randn(rng) for _ in 1:n]
    i = Int8[rand(rng, Int8) for _ in 1:n]
    f = Frame(g = g, x = x, y = y, i = i)
    out = summarise(
        s = sum(skipmissing(c.x)), m = mean(skipmissing(c.x)), v = var(skipmissing(c.x)), sy = sum(c.y),
        my = mean(c.y), sd = std(c.y), si = sum(c.i), p = prod(c.y), mx = maximum(c.y),
    )(group_by(:g)(f))
    # phase 3's per-group call: the group's rows in row order, the aggregator protocol on a view
    for (k, key) in enumerate(sort(unique(g)))
        rows = findall(==(key), g)
        e(agg, col) = proto(agg, view(CF.getcol(f, col), rows))
        @test out.columns[2][k] === e(CF.SkipMissingAgg(UP.Sum()), :x)
        @test out.columns[3][k] === e(CF.SkipMissingAgg(UP.Mean()), :x)
        @test out.columns[4][k] === e(CF.SkipMissingAgg(CF.Spread(UP.Moments(false, true))), :x)
        @test out.columns[5][k] === Float32(e(UP.Sum(), :y))
        @test out.columns[6][k] === Float64(e(UP.Mean(), :y))
        @test out.columns[7][k] === Float64(e(CF.Spread(UP.Moments(true, true)), :y))
        @test out.columns[8][k] === e(UP.Sum(), :i)
        @test out.columns[9][k] === Float32(e(UP.Prod(), :y))
        @test out.columns[10][k] === e(UP.Max(), :y)
        # and the Base call itself on the same values in the same order
        @test out.columns[8][k] === sum(i[rows])
        @test out.columns[10][k] === maximum(y[rows])
    end
end
