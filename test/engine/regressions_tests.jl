# The prototype's eight review bugs (reference/prototype/DESIGN.md §5), kept as regression tests.
# Where the bug lived in lazy mode, this is the eager half; the lazy half is phase 3's.

@testsnippet Reg begin
    using Tables, Statistics
    const ⨟ = ChuiFrames.Upstream.:⨟
    col(x, n) = collect(Tables.getcolumn(x, n))
end

@testitem "regression 1: mean of Int does not overflow" tags = [:unit] setup = [Reg] begin
    t = (g = [1, 1, 2], x = [typemax(Int), typemax(Int), 1])
    @test col(summarise(m = mean(c.x))(t), :m)[1] ≈ (2 * Float64(typemax(Int)) + 1) / 3
    @test col((group_by(:g) ⨟ summarise(m = mean(c.x)))(t), :m)[1] ≈ Float64(typemax(Int))
    # lazy half (morsel partials): phase 3
end

@testitem "regression 2: Take is stateful and never runs per partition" tags = [:unit] setup = [Reg] begin
    UP = ChuiFrames.Upstream
    @test !UP.isstateless(UP.Take(2))
    @test UP.foldxl(push!, UP.:⨟(UP.Map(identity), UP.Take(2)), 1:10; init = Int[]) == [1, 2]
    @test col(head(2)((x = 1:10,)), :x) == [1, 2]
    # lazy half (parallel fold with a limit): phase 3
end

@testitem "regression 3: desc(:sym) sorts by the column" tags = [:unit] setup = [Reg] begin
    t = (x = [2, 3, 1],)
    @test col(arrange(desc(:x))(t), :x) == [3, 2, 1]
    @test desc(:x) == desc(c.x)
end

@testitem "var/std of fewer than two values are missing (dplyr NA, Polars/DuckDB null)" tags = [:unit] setup = [Reg] begin
    # user decision at the phase-2c ★ (2026-10-20); ADR-0002 note of that date.
    # R: var(5) -> NA; sd(5) -> NA; var(numeric(0)) -> NA
    r = summarise(v = var(c.y), s = std(c.y))((y = [5],))
    @test ismissing(col(r, :v)[1]) && ismissing(col(r, :s)[1])
    r = summarise(v = var(c.y), s = std(c.y))((y = Float64[],))
    @test ismissing(col(r, :v)[1]) && ismissing(col(r, :s)[1])
    # grouped: a one-row group is missing, a two-row group is a number
    g = (group_by(:g) ⨟ summarise(v = var(c.y), s = std(c.y)))((g = ["a", "b", "b"], y = [1.0, 2.0, 4.0]))
    @test isequal(col(g, :v), [missing, 2.0]) && isequal(col(g, :s), [missing, sqrt(2.0)])
    @test eltype(col(g, :v)) === Union{Missing, Float64}
    # two or more values still match Statistics
    @test col(summarise(v = var(c.y))((y = [1.0, 2.0, 4.0],)), :v)[1] ≈ var([1.0, 2.0, 4.0])
    # skipmissing: one non-missing value is too few
    @test ismissing(col(summarise(v = var(skipmissing(c.y)))((y = [missing, 3.0],)), :v)[1])
    # windows too: R mutate(group_by(d, g), v = var(y))$v -> NA, 2, 2
    w = (group_by(:g) ⨟ mutate(v = var(c.y)))((g = ["a", "b", "b"], y = [1.0, 2.0, 4.0]))
    @test isequal(col(w, :v), [missing, 2.0, 2.0])
    # corrected = false (population variance, ddof 0) of one value is 0, as Polars var(ddof=0)
    # and DuckDB var_pop; of none it is missing
    @test col(summarise(v = var(c.y; corrected = false))((y = [5.0],)), :v)[1] == 0.0
    @test ismissing(col(summarise(v = var(c.y; corrected = false))((y = Float64[],)), :v)[1])
end

@testitem "regression 4: count is Bool-only, like Base" tags = [:unit] setup = [Reg] begin
    @test_throws TypeError summarise(n = count(c.x))((x = [1, 2, 3],))
    @test col(summarise(n = count(c.b))((b = [true, false, true],)), :n) == [2]
end

@testitem "regression 5: no broadcast-style method ambiguity" tags = [:unit] setup = [Reg] begin
    using Test
    amb = Test.detect_ambiguities(ChuiFrames; recursive = true)
    @test isempty(amb)
    struct Weird end
    Base.broadcastable(w::Weird) = w
    Base.Broadcast.BroadcastStyle(::Type{Weird}) = Base.Broadcast.Unknown()
    @test (c.x .+ Weird()) isa ChuiFrames.Node        # an Unknown style on the other side
end

@testitem "regression 6: empty grouped input keeps the key columns" tags = [:unit] setup = [Reg] begin
    e = (g = String[], x = Int[])
    r = (group_by(:g) ⨟ summarise(s = sum(c.x)))(e)
    @test Tables.columnnames(r) == [:g, :s] && length(col(r, :g)) == 0
    # the original bug was in unnest (not a phase-2 verb); revisit with nest/unnest
end

@testitem "regression 7: NaN never hides matching rows" tags = [:unit] setup = [Reg] begin
    t = (f = [1.0, NaN, 2.0, 3.0],)
    @test isequal(col(filter(.!(c.f .<= 2.0))(t), :f), [NaN, 3.0])
    @test isequal(col(filter(c.f .!= 2.0)(t), :f), [1.0, NaN, 3.0])
    # lazy half (statistics pruning, CF-013): phase 3
end

@testitem "regression 8: a filter never runs ahead of a select that drops its column" tags = [:unit] setup = [Reg] begin
    t = (a = [1, 2, 3], b = [3, 2, 1])
    @test_throws ArgumentError (select(:a) ⨟ filter(c.b .> 1))(t)
    @test col((filter(c.b .> 1) ⨟ select(:a))(t), :a) == [1, 2]
    # lazy half (pushdown past select): phase 3
end
