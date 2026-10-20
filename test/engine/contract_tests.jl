# The chui-frames contract entries the eager path allows (CF-001 to CF-007, CF-009, CF-010,
# CF-017). These are ChuiFrames' own unit items; the coordinator's :contract items run in
# test/contracts/ against released versions.

@testsnippet CF begin
    using Tables, Statistics
    using ChuiFrames: frame_equal
    const ⨟ = ChuiFrames.Upstream.:⨟
    ct(x) = Tables.columntable(x)
    col(x, n) = collect(Tables.getcolumn(x, n))
    rowtable(nt) = [NamedTuple{keys(nt)}(Tuple(v[i] for v in values(nt))) for i in 1:length(first(nt))]
end

@testitem "CF-001 Tables.jl guarantee" tags = [:unit] setup = [CF] begin
    t = (a = [1, 2, 3], g = ["x", "y", "x"], f = [1.5, missing, 2.5])
    f = filter(c.a .> 1)(t)
    @test Tables.istable(typeof(f))
    @test isequal(ct(Tables.rows(f) |> Tables.columntable), ct(f))
    @test ct(f).a == [2, 3]
    r = rowtable(t)
    verbs = [
        filter(c.a .> 1), mutate(b = c.a .* 2), select(:g, :a), arrange(desc(c.a)), group_by(:g),
        summarise(s = sum(c.a)), group_by(:g) ⨟ summarise(m = mean(c.a)), head(2), distinct(:g),
        count_by(:g), rename(h = :g), slice_max(c.a), relocate(:f), union_rows(t), bind_rows(t),
    ]
    for v in verbs
        @test frame_equal(v(t), v(r))
        @test v(t) isa Frame
    end
end

@testitem "CF-002 deferred column" tags = [:unit] setup = [CF] begin
    e = c.mass ./ c.len
    @test !(c.x isa Vector) && !((c.x .+ 1) isa Vector) && !(sum(c.x) isa Vector)
    p1 = mutate(ratio = e)
    @test col(p1((mass = [2.0, 3.0], len = [1.0, 2.0])), :ratio) == [2.0, 1.5]
    @test col(p1((mass = [8.0], len = [4.0])), :ratio) == [2.0]
    p2 = filter(e .> 0.5)
    @test col(p2((mass = [1.0, 3.0], len = [4.0, 2.0])), :mass) == [3.0]
end

@testitem "CF-003 dots elementwise" tags = [:unit] setup = [CF] begin
    t = (x = [1, -2, 3, 4], y = [10, 20, 30, 40], g = [1, 2, 1, 2])
    set = Set([1, 3])
    cases = [
        (abs.(c.x) .+ c.y, abs.(t.x) .+ t.y),
        ((+).(c.x, 1), (+).(t.x, 1)),
        ((@. c.x * 2 + 1), (@. t.x * 2 + 1)),
        (ifelse.(c.x .> 0, c.x, 0), ifelse.(t.x .> 0, t.x, 0)),
        (in.(c.x, Ref(set)), in.(t.x, Ref(set))),
        (c.x .^ 3, t.x .^ 3),
        (string.(c.x, "_", c.y), string.(t.x, "_", t.y)),
    ]
    for (n, want) in cases
        @test col(mutate(z = n)(t), :z) == want
        @test col((group_by(:g) ⨟ mutate(z = n))(t), :z) == want
    end
end

@testitem "CF-004 plain calls reduce" tags = [:unit] setup = [CF] begin
    t = (g = ["a", "b", "a", "b", "a"], x = [1.0, 2.0, 4.0, 8.0, 0.5], b = [true, false, true, true, false])
    reds = [
        (sum(c.x), sum), (prod(c.x), prod), (length(c.x), length), (maximum(c.x), maximum),
        (minimum(c.x), minimum), (extrema(c.x), extrema), (first(c.x), first), (last(c.x), last),
        (mean(c.x), mean), (median(c.x), median), (std(c.x), std), (var(c.x), var),
    ]
    for (n, f) in reds
        got = col(summarise(r = n)(t), :r)[1]
        @test got isa Tuple ? got == f(t.x) : got ≈ f(t.x)
        r = (group_by(:g) ⨟ summarise(r = n))(t)
        for (k, g) in enumerate(["a", "b"])
            v = t.x[t.g .== g]
            got = col(r, :r)[k]
            @test got isa Tuple ? got == f(v) : got ≈ f(v)
        end
    end
    for (n, f) in ((count(c.b), count), (any(c.b), any), (all(c.b), all))
        @test col(summarise(r = n)(t), :r) == [f(t.b)]
    end
    @test_throws TypeError summarise(r = count(c.x))(t)          # count errors on non-Bool, like Base
    @test col((group_by(:g) ⨟ mutate(d = c.x .- mean(c.x)))(t), :d) ≈
        [1.0 - 11 / 6, -3.0, 4.0 - 11 / 6, 3.0, 0.5 - 11 / 6]
    @test col(summarise(n = length(c.x), m = mean(c.x))((g = ["a", "b", "a"], x = [1.0, 2.0, 4.0])), :m) ≈ [7 / 3]
    # empty input: CC-006 values and CC-007 exception types
    e = (x = Float64[],)
    @test col(summarise(s = sum(c.x), n = length(c.x))(e), :s) == [0]
    @test_throws ArgumentError summarise(m = maximum(c.x))(e)
    @test_throws ArgumentError summarise(m = extrema(c.x))(e)
    @test_throws BoundsError summarise(m = last(c.x))(e)
end

@testitem "CF-005 no plain-operator overloads" tags = [:unit] setup = [CF] begin
    for n in (c.x, c.x .+ 1, sum(c.x), c.x .+ missing)
        @test (n == n) === true && isequal(n, n)
        @test hash(n) == hash(deepcopy(n))
        @test Dict(n => 1)[n] == 1
    end
    @test (c.x == c.y) === false
    @test (c.x == missing) === false
    @test (missing == c.x) === false
    @test_throws MethodError c.x + 1
    @test_throws MethodError c.x > 1
    @test_throws MethodError !c.x
end

@testitem "CF-006 whole-column escape hatch" tags = [:unit] setup = [CF] begin
    t = (x = [3, 1, 2], g = [1, 1, 2])
    @test col(mutate(r = c.x |> sortperm)(t), :r) == sortperm(t.x)
    @test col(summarise(s = c.x |> v -> sum(v) / 2)(t), :s) == [3.0]
    @test col((group_by(:g) ⨟ mutate(r = c.x |> sortperm))(t), :r) == [2, 1, 1]
    @test col((group_by(:g) ⨟ summarise(s = c.x |> sum))(t), :s) == [4, 2]
    @test_throws DimensionMismatch mutate(u = c.x |> unique)((x = [1, 1, 2],))
    @test col(summarise(u = c.x |> unique)((x = [1, 1, 2],)), :u) == [[1, 2]]
end

@testitem "CF-007 verbs as values" tags = [:unit] setup = [CF] begin
    a, b, d = filter(c.mass .> 3), group_by(:species), summarise(m = mean(c.mass))
    t = (species = ["a", "b", "a"], mass = [3.1, 5.0, 4.0])
    t2 = (species = ["z"], mass = [9.0])
    @test frame_equal((a ⨟ b)(t), b(a(t)))
    @test frame_equal(((a ⨟ b) ⨟ d)(t), (a ⨟ (b ⨟ d))(t))
    @test frame_equal(((a ⨟ b) ⨟ d)(t), d(b(a(t))))
    p = a ⨟ b ⨟ d
    @test frame_equal(t |> p, p(t))
    @test col(p(t2), :m) == [9.0] && col(p(t), :m) ≈ [3.55, 5.0]
    @test repr(a) == "filter((c.mass .> 3))"
end

@testitem "CF-009 no Base collisions; no piracy" tags = [:unit] begin
    stdlibs = [m for m in values(Base.loaded_modules) if pkgdir(m) !== nothing && startswith(pkgdir(m), Sys.STDLIB)]
    mods = unique([Base, Core, stdlibs...])
    collisions = [
        n for n in names(ChuiFrames) if n !== :ChuiFrames &&
            any(O -> Base.isexported(O, n) && isdefined(O, n) && getfield(O, n) !== getfield(ChuiFrames, n), mods)
    ]
    @test isempty(collisions)
    @test [n for n in names(ChuiFrames) if length(string(n)) == 1] == [:c]
    # every method ChuiFrames adds to a Base/Core/stdlib function has a ChuiFrames-owned argument
    owned(T) = T isa TypeVar ? owned(T.ub) :
        T isa UnionAll ? owned(Base.unwrap_unionall(T)) :
        T isa Union ? (owned(T.a) || owned(T.b)) :
        T isa Core.TypeofVararg ? owned(T.T) :
        T isa DataType ? (
            parentmodule(T) === ChuiFrames || parentmodule(T) === ChuiFrames.Upstream ||
            any(owned, T.parameters)
        ) : false
    bad = String[]
    nchecked = Ref(0)
    for M in mods, n in names(M; all = true)
        isdefined(M, n) || continue
        f = getfield(M, n)
        home = f isa Function ? parentmodule(f) :
            (f isa Type && Base.unwrap_unionall(f) isa DataType) ? parentmodule(Base.unwrap_unionall(f)) : nothing
        home === M || continue
        for m in methods(f)
            pm = parentmodule(m)
            (pm === ChuiFrames || pm === ChuiFrames.Upstream) || continue
            nchecked[] += 1
            sig = Base.unwrap_unionall(m.sig)
            any(owned, sig.parameters[2:end]) || push!(bad, string(m))
        end
    end
    @test nchecked[] > 30
    @test isempty(bad)
    # the Upstream stand-ins are never exported (ADR-0014 rule 2)
    @test !Base.isexported(ChuiFrames, :⨟) && !Base.isexported(ChuiFrames, :combine)
    @test ChuiFrames.filter === Base.filter
end

@testitem "CF-010 c is exported" tags = [:unit] begin
    m = Module()
    Core.eval(m, :(using ChuiFrames))
    @test Core.eval(m, :(isdefined(@__MODULE__, :c)))
    @test Base.isexported(ChuiFrames, :c)
    @test Core.eval(m, :c) === ChuiFrames.c
end

@testitem "CF-017 reserved keywords" tags = [:unit] setup = [CF] begin
    t = (x = [1, 2], g = [1, 1])
    for k in (:by, :keep, :before, :after)
        @test_throws ArgumentError mutate(; (k => c.x .+ 1,)...)
        @test col(mutate(string(k) => c.x .+ 1)(t), k) == [2, 3]
    end
    for k in (:by, :groups)
        @test_throws ArgumentError summarise(; (k => sum(c.x),)...)
        @test col(summarise(string(k) => sum(c.x))(t), k) == [3]
    end
    @test col(mutate(y = c.x .+ 1)(t), :y) == [2, 3]
    @test col(summarise(s = sum(c.x))(t), :s) == [3]
    err = try
        mutate(keep = c.x .+ 1)
    catch e
        e
    end
    @test occursin("mutate(\"keep\" =>", err.msg)
end
