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
    # rank types follow the argument's declared type, not the data: Int for an Int column;
    # nullable for a float column (NaN ranks as missing) with or without a NaN present
    r4 = (x = [3, 1, 2],) |> mutate(r = min_rank(c.x), k = row_number())
    @test et(r4, :r) === Int && et(r4, :k) === Int
    @test et((x = [3.0, 1.0],) |> mutate(r = min_rank(c.x)), :r) === Union{Missing, Int}
    @test et((x = [3.0, NaN],) |> mutate(r = min_rank(c.x)), :r) === Union{Missing, Int}
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

@testitem "case_when: element type from the value and default types, not the data" tags = [:unit] begin
    using ChuiFrames
    using ChuiFrames: getcol, StrView
    using Statistics: mean
    const ⨟ = ChuiFrames.Upstream.:⨟
    et(cw, t) = eltype(getcol(mutate(k = cw)(t), :k))
    fires = (x = [1.0, 2.0, 3.0],)   # row 1 takes the default
    never = (x = [2.0, 3.0],)        # every row takes the first branch
    empty = (x = Float64[],)
    # R (dplyr 1.2.0), x <- c(1, 2, 3): the type is the common type of the values and .default,
    # whichever branches fire; an NA default adds nothing (here: only nullability).
    # class(case_when(x > 1 ~ 1L)) "integer"; case_when(x > 0 ~ 1L) "integer";
    # case_when(x > 1 ~ 1L, .default = 2.5) "numeric"; case_when(x > 1 ~ TRUE, .default = 0L)
    # "integer"; case_when(x > 1 ~ x, .default = 0L) "numeric"; case_when(x > 1 ~ TRUE)
    # "logical"; case_when(numeric() > 1 ~ 1L, .default = 2.5) numeric(0).
    cases = [
        (case_when((c.x .> 1) => 1), Union{Missing, Int}),
        (case_when((c.x .> 1) => 1; default = 2.5), Float64),
        (case_when((c.x .> 1) => true; default = 0), Int),
        (case_when((c.x .> 1) => c.x; default = 0), Float64),
        (case_when((c.x .> 1) => c.x), Union{Missing, Float64}),
        (case_when((c.x .> 1) => true), Union{Missing, Bool}),
        (case_when((c.x .> 1) => true; default = false), Bool),
        (case_when((c.x .> 2) => 1, (c.x .> 1) => 2.5), Union{Missing, Float64}),
        (case_when((c.x .> 1) => "a"; default = "b"), StrView),
        (case_when((c.x .> 1) => "a"), Union{Missing, StrView}),
        (case_when((c.x .> 1) => c.x .* 2; default = c.x), Float64),
    ]
    for (cw, T) in cases
        @test et(cw, fires) === T
        @test et(cw, never) === T
        @test et(cw, empty) === T
    end
    # values are converted to the common type
    @test isequal(collect(getcol(mutate(k = case_when((c.x .> 1) => 1; default = 2.5))(fires), :k)), [2.5, 1.0, 1.0])
    # a mix with no common type is an error whatever fires, as in dplyr
    # (R: case_when(x > 1 ~ "a", .default = 1) -> "Can't combine <character> and `.default` <double>")
    mixed = case_when((c.x .> 1) => "a"; default = 1)
    @test_throws ArgumentError mutate(k = mixed)(fires)
    @test_throws ArgumentError mutate(k = mixed)(never)
    @test_throws ArgumentError mutate(k = mixed)(empty)
    # a value whose type is not known exactly (an untyped column) is narrowed by the data, as before
    @test et(case_when((c.x .> 1) => c.a; default = 0), (x = [2.0], a = Any[1])) === Int
    # an Int that Float64 cannot hold is an error, not a silent rounding
    big = case_when((c.x .> 1) => 2^53 + 1; default = 0.5)
    @test_throws ArgumentError mutate(k = big)(fires)
    @test et(big, (x = [0.0],)) === Float64
    # grouped windows: a group where the default fires and one where it does not
    g = (g = ["a", "a", "b"], x = [1.0, 3.0, 2.0])
    r = (group_by(:g) ⨟ mutate(k = case_when((c.x .>= mean(c.x)) => 1)))(g)
    @test eltype(getcol(r, :k)) === Union{Missing, Int} && isequal(collect(getcol(r, :k)), [missing, 1, 1])
    r = (group_by(:g) ⨟ mutate(k = case_when((c.x .>= mean(c.x)) => 1)))((g = ["b"], x = [2.0]))
    @test eltype(getcol(r, :k)) === Union{Missing, Int}
    # scalar (reduction) values
    @test et(case_when((c.x .> 1) => maximum(c.x)), fires) === Union{Missing, Float64}
end
