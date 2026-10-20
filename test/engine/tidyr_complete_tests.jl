# Unit tests for fill (a method of Base.fill on nodes, CF-009), expand, nesting and complete
# (src/engine/verbs_complete.jl). Expected values were checked against tidyr 1.3.1 with
# `Rscript` (the differential item re-checks the main cases).

@testsnippet TC begin
    using Tables
    using DataAPI: nrow, ncol
    using ChuiFrames: frame_equal
    const ⨟ = ChuiFrames.Upstream.:⨟
    col(x, n) = collect(Tables.getcolumn(x, n))
    eq(a, b) = isequal(a, b)
    names_of(x) = collect(Tables.columnnames(x))
    f = (g = [1, 1, 1, 2, 2, 2], v = Union{Missing, Float64}[missing, 3.0, missing, missing, NaN, missing], w = Union{Missing, String}["a", missing, missing, missing, "b", missing])
    e = (a = Union{Missing, Float64}[2.0, 1.0, missing, 2.0], b = Union{Missing, String}["y", "x", "x", missing], c = [true, false, true, true], n = [1, 2, 3, 4])
end

@testitem "fill: CF-009, a Base.fill method on nodes" tags = [:unit] setup = [TC] begin
    @test ChuiFrames.fill === Base.fill
    @test fill(5, 2) == [5, 5]                                   # Base untouched
    @test size(fill(5)) == ()
    @test fill(c.v) isa ChuiFrames.Step
    @test_throws ArgumentError fill(c.v .+ 1)                    # only plain column nodes
    @test_throws ArgumentError fill(c.v; direction = :sideways)
    @test sprint(show, fill(c.v, c.w; direction = :up)) == "fill(c.v, c.w; direction = :up)"
    @test !any(m -> m[1].name === :fill || m[2].name === :fill, Test.detect_ambiguities(Base, ChuiFrames))
    @test sprint(show, fill(c.v)) == "fill(c.v)"                 # one argument is ours, not a 0-dim array
end

@testitem "fill: directions, NaN counts as missing (tidyr), grouped" tags = [:unit] setup = [TC] begin
    @test eq(col(fill(c.v)(f), :v), [missing, 3.0, 3.0, 3.0, 3.0, 3.0])
    @test eq(col(fill(c.v, c.w)(f), :w), ["a", "a", "a", "a", "b", "b"])
    @test eq(col(fill(c.v; direction = :up)(f), :w), ["a", missing, missing, missing, "b", missing])
    @test eq(col(fill(c.w; direction = :up)(f), :w), ["a", "b", "b", "b", "b", missing])
    @test eq(col(fill(c.v; direction = :downup)(f), :v), fill(3.0, 6))
    @test eq(col(fill(c.w; direction = :updown)(f), :w), ["a", "b", "b", "b", "b", "b"])
    gf = group_by(:g)(f)
    @test eq(col(fill(c.v)(gf), :v), [missing, 3.0, 3.0, missing, missing, missing])   # NaN filled from the NA before it (tidyr)
    @test eq(col(fill(c.w; direction = :downup)(gf), :w), ["a", "a", "a", "b", "b", "b"])
    @test groupcols(fill(c.v)(gf)) == [:g]
    # tidyr's vctrs fill: a run of missing/NaN takes the value just before it, so a leading
    # NaN stays NaN and the NA after it becomes NaN
    s = (v = [NaN, missing, 2.0, NaN, missing, NaN],)
    @test eq(col(fill(c.v)(s), :v), [NaN, NaN, 2.0, 2.0, 2.0, 2.0])
    @test eq(col(fill(c.v; direction = :up)(s), :v), [2.0, 2.0, 2.0, NaN, NaN, NaN])
    # declared type kept (nullable stays nullable, ADR-0001 rule 1)
    @test eltype(Tables.getcolumn(fill(c.v; direction = :downup)(f), :v)) == Union{Missing, Float64}
    @test nrow(fill(c.v)((v = Float64[],))) == 0
    @test_throws ArgumentError fill(c.zz)(f)
end

@testitem "expand and nesting: sorted grid, first argument slowest, missing last" tags = [:unit] setup = [TC] begin
    x = expand(:a, :b)(e)
    @test names_of(x) == [:a, :b]
    @test eq(col(x, :a), [1.0, 1.0, 1.0, 2.0, 2.0, 2.0, missing, missing, missing])
    @test eq(col(x, :b), ["x", "y", missing, "x", "y", missing, "x", "y", missing])
    @test eq(col(expand(:b, :a)(e), :b), ["x", "x", "x", "y", "y", "y", missing, missing, missing])
    n = expand(nesting(:a, :b), :c)(e)
    @test eq(col(n, :a), [1.0, 1.0, 2.0, 2.0, 2.0, 2.0, missing, missing])
    @test eq(col(n, :b), ["x", "x", "y", "y", missing, missing, "x", "x"])
    @test col(n, :c) == [false, true, false, true, false, true, false, true]
    nb = expand(nesting(:b, :a))(e)
    @test eq(col(nb, :b), ["x", "x", "y", missing]) && eq(col(nb, :a), [1.0, missing, 2.0, 2.0])
    # NaN and missing are one tie class, in first-seen order (tidyr / vctrs)
    @test eq(col(expand(:a)((a = [1.0, NaN, missing, -1.0],)), :a), [-1.0, 1.0, NaN, missing])
    @test eq(col(expand(:a)((a = [missing, NaN, 1.0],)), :a), [1.0, missing, NaN])
    # grouped: per group, groups first
    gx = expand(:a, :b)(group_by(:c)(e))
    @test names_of(gx) == [:c, :a, :b] && groupcols(gx) == [:c]
    @test col(gx, :c) == [false, true, true, true, true, true, true]
    @test eq(col(gx, :a), [1.0, 2.0, 2.0, 2.0, missing, missing, missing])
    # empty input and no arguments
    x0 = expand(:a, :b)(Frame(a = Float64[], b = String[]))
    @test nrow(x0) == 0 && eltype(Tables.getcolumn(x0, :a)) === Float64
    @test nrow(expand()(e)) == 1 && ncol(expand()(e)) == 0
    @test_throws ArgumentError expand(:a, :a)(e)                 # tidyr repairs names; we refuse
    @test_throws ArgumentError expand(:c)(group_by(:c)(e))
    @test sprint(show, expand(nesting(:a, :b), :c)) == "expand(nesting(:a, :b), :c)"
end

@testitem "complete: grid order, fill, explicit, grouped, empty" tags = [:unit] setup = [TC] begin
    r = complete(:a, :b)(e)
    @test names_of(r) == [:a, :b, :c, :n]
    @test eq(col(r, :a), [1.0, 1.0, 1.0, 2.0, 2.0, 2.0, missing, missing, missing])
    @test eq(col(r, :n), [2, missing, missing, missing, 1, 4, 3, missing, missing])
    @test eq(col(r, :c), [false, missing, missing, missing, true, true, true, missing, missing])
    @test eltype(Tables.getcolumn(r, :n)) == Union{Missing, Int}
    rf = complete(:a, :b; fill = (n = 0,))(e)
    @test col(rf, :n) == [2, 0, 0, 0, 1, 4, 3, 0, 0]
    @test eltype(Tables.getcolumn(rf, :n)) === Int              # every missing replaced
    e2 = merge(e, (n = Union{Missing, Int}[1, missing, 3, 4],))
    @test col(complete(:a, :b; fill = (n = 0,))(e2), :n) == [0, 0, 0, 0, 1, 4, 3, 0, 0]
    ex = complete(:a, :b; fill = (n = 0,), explicit = false)(e2)
    @test eq(col(ex, :n), [missing, 0, 0, 0, 1, 4, 3, 0, 0])
    # NaN counts as missing for fill, as tidyr's replace_na
    @test eq(col(complete(:a; fill = (n = 0.0,))((a = [2.0, 1.0, 1.0], n = [missing, NaN, 3.0])), :n), [0.0, 3.0, 0.0])
    @test eq(col(complete(; fill = (n = 0.0,))((a = [2.0, 1.0, 1.0], n = [missing, NaN, 3.0])), :n), [0.0, 0.0, 3.0])
    # nesting
    rn = complete(nesting(:a, :b), :c)(e)
    @test eq(col(rn, :n), [2, missing, missing, 1, missing, 4, missing, 3])
    # duplicate keys: all matching rows, in data order
    d3 = complete(:a, :b)((a = [1.0, 1.0, 2.0], b = ["x", "x", "y"], n = [1, 2, 3]))
    @test eq(col(d3, :n), [1, 2, missing, missing, 3])
    # grouped
    g = complete(:a, :b)(group_by(:c)(e))
    @test names_of(g) == [:c, :a, :b, :n] && groupcols(g) == [:c]
    @test eq(col(g, :n), [2, missing, 1, 4, 3, missing, missing])
    # empty and no-argument forms
    z = complete(:a, :b)(Frame(a = Float64[], b = String[], n = Int[]))
    @test nrow(z) == 0 && names_of(z) == [:a, :b, :n]
    @test frame_equal(complete()(e), Frame(e))
    # errors
    @test_throws ArgumentError complete(:a, :b; fill = (zz = 0,))(e)
    @test_throws ArgumentError complete(:a, :b; fill = (n = "z",))(e)   # tidyr: can't convert
end
