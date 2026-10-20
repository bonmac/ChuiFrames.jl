# Law tests for the upstream adapter's aggregators (CC-004 to CC-007) and ChuiFrames' own
# aggregators built on the protocol (user decision R8 option A): the same laws ChuiCore's will
# pass, so the switch (ADR-0014 rule 3) cannot change results.

@testsnippet AggLaws begin
    using Statistics
    using ChuiFrames: Upstream, SkipMissingAgg, NDistinct, Holistic
    const UP = Upstream
    const ε = sqrt(eps(Float64))
    acc(agg, x) = () -> UP.partial(agg, UP.init(agg), x)
    function R(agg, chunks)
        a = acc(agg, chunks[1])()
        for x in chunks[2:end]
            a = UP.combine(agg, a, acc(agg, x)())
        end
        return UP.final(agg, a)
    end
    fl(v) = [Float64(x) for x in v if !ismissing(x) && x isa Real]
    # CC-004's tolerance table
    function τ(name, v)
        w = fl(v)
        isempty(w) && return 0.0
        name === :sum ? ε * sum(abs, w) :
            name === :mean ? ε * sum(abs, w) / length(w) :
            name === :var ? ε * mean(abs2, w) :
            name === :std ? sqrt(ε * mean(abs2, w)) : 0.0
    end
    approxeq(r1, r2, t) = isequal(r1, r2) ||
        (r1 isa AbstractFloat && r2 isa AbstractFloat && isapprox(r1, r2; atol = t, rtol = ε)) ||
        (r1 isa Tuple && r2 isa Tuple && length(r1) == length(r2) && all(approxeq(a, b, t) for (a, b) in zip(r1, r2)))
    # three-way splits, each including an empty chunk
    splits(v) = (
        n = length(v); [
            [v, eltype(v)[], eltype(v)[]], [v[1:min(1, n)], eltype(v)[], v[(min(1, n) + 1):n]],
            [eltype(v)[], v[1:div(n, 2)], v[(div(n, 2) + 1):n]], [v[1:div(n, 3)], v[(div(n, 3) + 1):(2 * div(n, 3))], v[(2 * div(n, 3) + 1):n]],
        ]
    )
    # (name, aggregator, Base reference, samples)
    const FV = [[1.0, 1.0e16, -1.0e16], [0.1, 0.2, 0.3, 0.4, 0.5], [3.0, -1.5, 2.25, 8.0, -0.0, 0.0], fill(0.1, 10)]
    const IV = [[1, 2, 3, 4, 5, 6], [typemax(Int) ÷ 2, typemax(Int) ÷ 2, 7], [-3, 9, 0]]
    const BV = [[true, false, true], [false, false], [true, true, true, false]]
    const CASES = [
        (:sum, UP.Sum(), sum, [FV; IV]),
        (:prod, UP.Prod(), prod, [[1.5, 2.0, -3.0], [1, 2, 3, 4]]),
        (:count, UP.Count(), length, [FV; IV; BV]),
        (:counttrue, UP.CountTrue(), count, BV),
        (:any, UP.AnyM(), any, BV),
        (:all, UP.AllM(), all, BV),
        (:max, UP.Max(), maximum, [FV; IV]),
        (:min, UP.Min(), minimum, [FV; IV]),
        (:extrema, UP.Extrema(), extrema, [FV; IV]),
        (:first, UP.First(), first, [FV; IV]),
        (:last, UP.Last(), last, [FV; IV]),
        (:mean, UP.Mean(), mean, [FV; IV]),
        (:var, UP.Moments(std = false), var, FV),
        (:std, UP.Moments(std = true), std, FV),
        (:reduce, UP.ReduceM(+), v -> reduce(+, v), IV),
        (:mapm, UP.MapM(abs2, UP.Sum()), v -> sum(abs2, v), IV),
        (:skipsum, SkipMissingAgg(UP.Sum()), v -> sum(skipmissing(v)), [[1, missing, 3], [missing, 2.5, 4.0, missing]]),
        (:skipmax, SkipMissingAgg(UP.Max()), v -> maximum(skipmissing(v)), [[1, missing, 3], [missing, 2.5]]),
        (:skipmean, SkipMissingAgg(UP.Mean()), v -> mean(skipmissing(v)), [[1, missing, 3], [missing, 2.5, 4.0]]),
        (:ndistinct, NDistinct(), v -> length(unique(v)), [[1, 1, 2, missing], ["a", "b", "a"]]),
        (:median, Holistic(median, "median"), median, [FV; IV]),
    ]
    tname(name) = name in (:skipsum,) ? :sum : name in (:skipmean,) ? :mean : name
end

@testitem "CC-004 aggregator protocol: laws 1-4" tags = [:laws] setup = [AggLaws] begin
    for (name, agg, base, samples) in CASES, v in samples
        t = τ(tname(name), v)
        whole = R(agg, [v])
        # law 4: agreement with Base (values only)
        @test approxeq(whole, base(v), t)
        # law 1: split invariance, three-way splits incl. empty chunks
        for sp in splits(v)
            @test approxeq(R(agg, sp), whole, t)
        end
        # law 2: an empty partition is an identity on both sides
        E = acc(agg, eltype(v)[])
        A = acc(agg, v)
        @test approxeq(UP.final(agg, UP.combine(agg, E(), A())), UP.final(agg, A()), t)
        @test approxeq(UP.final(agg, UP.combine(agg, A(), E())), UP.final(agg, A()), t)
        # law 3: chunk concatenation through Iterators.flatten
        k = div(length(v), 2)
        x, y = v[1:k], v[(k + 1):end]
        @test approxeq(
            UP.final(agg, UP.partial(agg, acc(agg, x)(), y)),
            UP.final(agg, UP.partial(agg, UP.init(agg), Iterators.flatten((x, y)))), t
        )
    end
end

@testitem "CC-004 tolerance counterexamples and init freshness" tags = [:laws] setup = [AggLaws] begin
    v1 = [1.0, 1.0e16, -1.0e16]
    @test R(UP.Sum(), [v1[1:1], v1[2:3]]) == 1.0           # the split really differs ...
    @test approxeq(R(UP.Sum(), [v1[1:1], v1[2:3]]), sum(v1), τ(:sum, v1))   # ... within τ
    v2 = fill(0.1, 10)
    @test approxeq(R(UP.Moments(), [v2[1:1], v2[2:10]]), var(v2), τ(:var, v2))
    @test approxeq(R(UP.Moments(), [v2[1:3], v2[4:10]]), var(v2), τ(:var, v2))
    @test approxeq(R(UP.Moments(std = true), [v2[1:3], v2[4:10]]), std(v2), τ(:std, v2))
    # two init calls never alias: mutating one through partial leaves the other unchanged
    for agg in (UP.Sum(), UP.Mean(), UP.Max(), UP.First(), NDistinct(), Holistic(median, "median"), UP.Moments())
        a, b = UP.init(agg), UP.init(agg)
        a = UP.partial(agg, a, [1.0, 2.0])
        b2 = UP.partial(agg, b, [5.0])
        @test isequal(UP.final(agg, b2), UP.final(agg, UP.partial(agg, UP.init(agg), [5.0])))
    end
end

@testitem "CC-005 iscommutative" tags = [:laws] setup = [AggLaws] begin
    expected = Dict(
        :sum => true, :prod => true, :count => true, :counttrue => true, :any => true,
        :all => true, :max => true, :min => true, :extrema => true, :first => false, :last => false,
        :mean => true, :var => true, :std => true, :reduce => false, :mapm => true,
        :skipsum => true, :skipmax => true, :skipmean => true, :ndistinct => true, :median => false
    )
    for (name, agg, base, samples) in CASES
        @test UP.iscommutative(agg) == expected[name]
        UP.iscommutative(agg) || continue
        for v in samples
            k = div(length(v), 2)
            x, y = v[1:k], v[(k + 1):end]
            @test approxeq(
                UP.final(agg, UP.combine(agg, acc(agg, x)(), acc(agg, y)())),
                UP.final(agg, UP.combine(agg, acc(agg, y)(), acc(agg, x)())), τ(tname(name), v)
            )
        end
    end
    struct MyAgg <: UP.Aggregator end
    @test UP.iscommutative(MyAgg()) == false
    @test UP.iscommutative(UP.ReduceM(+; commutative = true))
end

@testitem "CC-006 empty input (same type on every Julia)" tags = [:laws] setup = [AggLaws] begin
    e = Float64[]
    fin(agg) = UP.final(agg, UP.init(agg))
    for (agg, base) in (
            (UP.Sum(), sum), (UP.Prod(), prod), (UP.Count(), length), (UP.CountTrue(), count),
            (UP.AnyM(), any), (UP.AllM(), all), (UP.Mean(), mean), (UP.Moments(), var),
            (UP.Moments(std = true), std), (SkipMissingAgg(UP.Sum()), v -> sum(skipmissing(v))),
            (NDistinct(), v -> length(unique(v))),
        )
        @test isequal(fin(agg), base(base === count || base === any || base === all ? Bool[] : e))
    end
    for agg in (UP.Max(), UP.Min(), UP.Extrema(), UP.ReduceM(max), SkipMissingAgg(UP.Max()), Holistic(median, "median"))
        @test_throws ArgumentError fin(agg)
    end
    for (agg, base) in ((UP.Max(), maximum), (UP.Min(), minimum), (UP.Extrema(), extrema))
        @test_throws Exception base(e)   # Base: MethodError on 1.10, ArgumentError on 1.13
    end
    @test_throws BoundsError fin(UP.First())
    @test_throws BoundsError fin(UP.Last())
    @test UP.final(UP.ReduceM(+; neutral = 0), UP.init(UP.ReduceM(+; neutral = 0))) == 0
    # law 2 of CC-004 with an empty partition on each side, for Max and First
    for agg in (UP.Max(), UP.First())
        E = acc(agg, e)
        A = acc(agg, [2.0, 1.0])
        @test UP.final(agg, UP.combine(agg, E(), A())) == UP.final(agg, A()) == UP.final(agg, UP.combine(agg, A(), E()))
    end
    # the Moments "no value yet" state: no NaN leaks from an empty side (E-36)
    @test UP.final(UP.Moments(), UP.combine(UP.Moments(), acc(UP.Moments(), e)(), acc(UP.Moments(), [1.0, 2.0])())) == 0.5
end

@testitem "CC-007 built-in classification and Mean overflow" tags = [:laws] setup = [AggLaws] begin
    big = [typemax(Int), typemax(Int)]
    @test R(UP.Mean(), [big]) ≈ Float64(typemax(Int))
    @test R(UP.Mean(), [big[1:1], big[2:2]]) ≈ mean(big)
    @test R(UP.Mean(), [[1, 2]]) isa AbstractFloat
    @test_throws TypeError R(UP.CountTrue(), [[1, 2]])        # Bool only, like Base
    @test_throws TypeError R(UP.AnyM(), [[1]])
    @test isequal(R(UP.AnyM(), [[missing, false]]), any([missing, false]))
    @test R(UP.AnyM(), [[missing, true]]) === true
    @test isequal(R(UP.Max(), [[1, missing, 3]]), maximum([1, missing, 3]))   # missing propagates
    m = UP.MapM(abs2, UP.Sum())
    @test UP.final(m, UP.partial(m, UP.init(m), [1, -2, 3])) == sum(abs2, [1, -2, 3])
    @test UP.neutral(UP.Sum()) == UP.init(UP.Sum())
    @test_throws ArgumentError UP.neutral(UP.Max())
    # ReduceM keeps order for a non-commutative op (string concatenation)
    @test R(UP.ReduceM(*), [["a", "b"], String[], ["c"]]) == "abc"
end

@testitem "transducers: isstateless fail-closed, foldxl, Take, ⨟" tags = [:unit] begin
    using ChuiFrames: Upstream
    const UP = Upstream
    @test UP.isstateless(UP.Map(identity)) && UP.isstateless(UP.Filter(iseven)) && UP.isstateless(UP.MapCat(x -> (x, x)))
    @test !UP.isstateless(UP.Take(2))
    @test !UP.isstateless(UP.:⨟(UP.Map(identity), UP.Take(2)))
    struct Other end
    @test !UP.isstateless(Other())
    xf = UP.:⨟(UP.Filter(isodd), UP.Map(x -> 10x))
    @test UP.foldxl(push!, xf, 1:6; init = Int[]) == [10, 30, 50]
    @test UP.foldxl(push!, UP.:⨟(UP.MapCat(x -> (x, x)), UP.Take(3)), 1:10; init = Int[]) == [1, 1, 2]
    @test UP.aggregate(UP.Sum(), UP.Filter(iseven), ([1, 2], Int[], [4, 5])) == 6
    @test UP.opcompose === UP.:⨟
    @test (UP.:⨟(x -> x + 1, x -> 2x))(3) == 8
end
