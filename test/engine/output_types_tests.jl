# Verb outputs take their element type from the declared schema, never from the data
# (ADR-0001 rule 1). Reviewer finding B1 (phase-2 review, 2026-10-20): all-missing groups and
# empty-group neutral values used to give object columns (`Real`, `Missing`) that cannot be
# written to Arrow/CSV/Parquet.

@testitem "B1: verb output element types come from the static type" tags = [:unit] begin
    using ChuiFrames
    using ChuiFrames: getcol, ObjectColumn
    using Statistics: mean
    et(f, n) = eltype(getcol(f, n))
    # mutate over an all-missing nullable Float64 column stays a nullable Float64 column
    f = (x = Union{Missing, Float64}[missing, missing],) |> mutate(z = c.x .+ 1)
    @test et(f, :z) === Union{Missing, Float64}
    @test !(getcol(f, :z) isa ObjectColumn)
    # sum(skipmissing) over a group whose values are all missing: Float64 (0.0), not Real
    t = (g = ["a", "b"], x = Union{Missing, Float64}[1.5, missing])
    r = t |> group_by(:g) |> summarise(s = sum(skipmissing(c.x)))
    @test et(r, :s) === Float64
    @test isequal(collect(getcol(r, :s)), [1.5, 0.0])
    # mean over groups that are all missing: nullable Float64, not an object column of Missing
    r2 = (g = ["a", "b"], x = Union{Missing, Float64}[missing, missing]) |> group_by(:g) |> summarise(m = mean(c.x))
    @test et(r2, :m) === Union{Missing, Float64}
    # count_by with weights keeps the weight column's type
    r3 = (g = ["a", "b", "a"], w = [1.5, 2.0, 0.5]) |> count_by(:g; wt = c.w)
    @test et(r3, :n) === Float64
    # ranks are Int whatever the data (nullable when their argument is)
    r4 = (x = [3, 1, 2],) |> mutate(r = min_rank(c.x), k = row_number())
    @test et(r4, :r) === Int && et(r4, :k) === Int
    # each result is writable
    for (fr, nm) in ((f, :z), (r, :s), (r2, :m), (r3, :n))
        p = tempname() * ".arrow"
        write_arrow(fr, p)
        @test isequal(collect(getcol(read_arrow(p), nm)), collect(getcol(fr, nm)))
    end
end

@testitem "B1: data narrowing keeps small numeric unions lossless" tags = [:unit] begin
    using ChuiFrames
    using ChuiFrames: getcol, PrimitiveColumn
    # an expression whose static type is unknown (|> escape hatch) mixing Int and Float64
    f = (x = [1, 2],) |> mutate(y = c.x |> v -> Any[v[1], 2.5])
    @test getcol(f, :y) isa PrimitiveColumn{Float64}
    @test collect(getcol(f, :y)) == [1.0, 2.5]
end
