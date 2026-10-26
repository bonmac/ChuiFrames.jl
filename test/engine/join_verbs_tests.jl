# Unit tests of the eager join verbs (phase-4 spec docs/superpowers/specs/2026-10-26-phase4-joins-groupby-codegen-design.md
# §1.1, §1.2, §1.5, §1.6: dplyr 1.2.0 semantics). Every case runs under each `_FORCE_JOIN` value
# (the three physical shapes and both build sides, §0.3), so the result cannot depend on the shape.

@testsnippet JoinHelpers begin
    using Tables
    const FORCES = (:auto, :broadcast_x, :broadcast_y, :partitioned_x, :partitioned_y)
    "Run `f()` under every `_FORCE_JOIN` value; return the results."
    forall(f) = [withforce(f, ChuiFrames._FORCE_JOIN => v) for v in FORCES]
    "The column values of `f` as plain vectors (for readable comparisons)."
    cols(f) = Dict(n => collect(Tables.getcolumn(f, n)) for n in Tables.columnnames(f))
    colvec(f, n) = collect(Tables.getcolumn(f, n))
    "Every result under every forced shape is `isequal` to `want` (and has its element types)."
    function same_everywhere(f, want)
        ok = true
        for (v, r) in zip(FORCES, forall(f))
            good = isequal(r, want) && [eltype(c) for c in r.columns] == [eltype(c) for c in want.columns]
            good || @info "join result differs" force = v got = Tables.columntable(r) want = Tables.columntable(want) gottypes = eltype.(r.columns) wanttypes = eltype.(want.columns)
            ok &= good
        end
        return ok
    end
    "The exception every forced shape raises (type and message), or `nothing` if one does not raise."
    function errors_everywhere(f)
        out = Any[]
        for v in FORCES
            e = try
                withforce(f, ChuiFrames._FORCE_JOIN => v)
                nothing
            catch err
                (typeof(err), sprint(showerror, err))
            end
            push!(out, e)
        end
        return out
    end
end

@testitem "join: inner/left/right/full rows, order and names (dplyr)" tags = [:unit] setup = [Force, JoinHelpers] begin
    x = Frame(k = [2, 1, 3, 2], v = ["a", "b", "c", "d"])
    y = Frame(k = [2, 4, 2, 1], w = [10, 20, 30, 40])
    # inner: x order, each x row's matches in y order
    want = Frame(k = [2, 2, 1, 2, 2], v = ["a", "a", "b", "d", "d"], w = [10, 30, 40, 10, 30])
    @test same_everywhere(() -> inner_join(y; by = :k)(x), want)
    # left: unmatched x rows keep their place; y columns become nullable (static, by kind)
    want = Frame(k = [2, 2, 1, 3, 2, 2], v = ["a", "a", "b", "c", "d", "d"], w = Union{Missing, Int}[10, 30, 40, missing, 10, 30])
    @test same_everywhere(() -> left_join(y; by = :k)(x), want)
    # right: the inner rows in x order, then y's unmatched rows in y order (keys from y)
    want = Frame(k = [2, 2, 1, 2, 2, 4], v = Union{Missing, String}["a", "a", "b", "d", "d", missing], w = [10, 30, 40, 10, 30, 20])
    @test same_everywhere(() -> right_join(y; by = :k)(x), want)
    # full: the left join's rows, then y's unmatched rows
    want = Frame(
        k = [2, 2, 1, 3, 2, 2, 4], v = Union{Missing, String}["a", "a", "b", "c", "d", "d", missing],
        w = Union{Missing, Int}[10, 30, 40, missing, 10, 30, 20],
    )
    @test same_everywhere(() -> full_join(y; by = :k)(x), want)
    # the step form and the pipe form agree (CF-007)
    @test isequal(x |> inner_join(y; by = :k), inner_join(y; by = :k)(x))
    # a Tables.jl y is converted once
    @test isequal(inner_join((k = [2, 4, 2, 1], w = [10, 20, 30, 40]); by = :k)(x), inner_join(y; by = :k)(x))
end

@testitem "join: element types are static by kind (widened even when all rows match)" tags = [:unit] setup = [Force, JoinHelpers] begin
    x = Frame(k = [1, 2], v = [1.5, 2.5])
    y = Frame(k = [2, 1], w = ["p", "q"])
    for r in forall(() -> left_join(y; by = :k)(x))
        @test eltype(ChuiFrames.getcol(r, :w)) == Union{Missing, eltype(ChuiFrames.getcol(y, :w))}
        @test eltype(ChuiFrames.getcol(r, :v)) == Float64
    end
    for r in forall(() -> right_join(y; by = :k)(x))
        @test eltype(ChuiFrames.getcol(r, :v)) == Union{Missing, Float64}
        @test eltype(ChuiFrames.getcol(r, :w)) == eltype(ChuiFrames.getcol(y, :w))
    end
    for r in forall(() -> full_join(y; by = :k)(x))
        @test eltype(ChuiFrames.getcol(r, :v)) == Union{Missing, Float64}
        @test eltype(ChuiFrames.getcol(r, :w)) == Union{Missing, eltype(ChuiFrames.getcol(y, :w))}
        @test eltype(ChuiFrames.getcol(r, :k)) == Int
    end
    for r in forall(() -> inner_join(y; by = :k)(x))
        @test [eltype(c) for c in r.columns] == [Int, Float64, eltype(ChuiFrames.getcol(y, :w))]
    end
    # a nullable key on either side makes the output key nullable
    yn = Frame(k = Union{Missing, Int}[2, missing], w = [1, 2])
    for r in forall(() -> inner_join(yn; by = :k)(x))
        @test eltype(ChuiFrames.getcol(r, :k)) == Union{Missing, Int}
        @test isequal(colvec(r, :k), [2])
    end
    # a dictionary column keeps its dictionary when every value comes from one frame
    d = ChuiFrames.DictColumn(UInt8[1, 2], ChuiFrames.column(["lo", "hi"]))
    xd = Frame(k = [1, 2], g = d)
    for r in forall(() -> left_join(y; by = :k)(xd))
        @test ChuiFrames.getcol(r, :g) isa ChuiFrames.DictColumn
    end
    # a key fed by both frames (full, keep = false) is decoded to plain values
    xk = Frame(k = ChuiFrames.DictColumn(UInt8[1, 2], ChuiFrames.column(["a", "b"])), v = [1, 2])
    yk = Frame(k = ChuiFrames.DictColumn(UInt8[2, 1], ChuiFrames.column(["c", "b"])), w = [3, 4])
    for r in forall(() -> full_join(yk; by = :k)(xk))
        @test !(ChuiFrames.getcol(r, :k) isa ChuiFrames.DictColumn)
        @test isequal(colvec(r, :k), ["a", "b", "c"])
        @test isequal(colvec(r, :w), [missing, 3, 4])           # yk is ["b", "c"] (codes 2, 1)
    end
end

@testitem "join: keep, suffix and name clashes (dplyr 1.2.0 names)" tags = [:unit] setup = [Force, JoinHelpers] begin
    x = Frame(k = [1, 2], v = [1, 2])
    y = Frame(k = [1, 3], v = [10, 30], w = [5, 6])
    # dplyr: inner_join(x, y, by = "k", keep = TRUE) gives k.x v.x k.y v.y w
    for r in forall(() -> inner_join(y; by = :k, keep = true)(x))
        @test r.names == [:k_x, :v_x, :k_y, :v_y, :w]
        @test isequal(Tables.columntable(r), (k_x = [1], v_x = [1], k_y = [1], v_y = [10], w = [5]))
    end
    for r in forall(() -> inner_join(y; by = :k)(x))
        @test r.names == [:k, :v_x, :v_y, :w]
    end
    for r in forall(() -> left_join(y; by = :k, suffix = (".left", ".right"))(x))
        @test r.names == [:k, Symbol("v.left"), Symbol("v.right"), :w]
    end
    # keep = true on a full join: each side's key keeps its own values (missing where absent)
    for r in forall(() -> full_join(y; by = :k, keep = true)(x))
        @test isequal(colvec(r, :k_x), [1, 2, missing])
        @test isequal(colvec(r, :k_y), [1, missing, 3])
    end
    # a y non-key column named like x's key column gets the y suffix (add_suffixes)
    x2 = Frame(a = [1, 2], v = [7, 8])
    y2 = Frame(b = [2, 1], a = ["p", "q"])
    for r in forall(() -> left_join(y2; by = :a => :b)(x2))
        @test r.names == [:a, :v, :a_y]
        @test isequal(colvec(r, :a_y), ["q", "p"])
    end
    # keep = true suffixes only names that clash with y's (dplyr 1.2.0, checked with Rscript)
    for r in forall(() -> inner_join(Frame(b = [1], w = [2]); by = :a => :b, keep = true)(Frame(a = [1], v = [1])))
        @test r.names == [:a, :v, :b, :w]
    end
    for r in forall(() -> inner_join(Frame(k = [1], v = [2], k_x = [5]); by = :k, keep = true)(Frame(k = [1], v = [1])))
        @test r.names == [:k_x_x, :v_x, :k_y, :v_y, :k_x]
    end
    # suffixes repeat while the name is taken by y or by an earlier output (dplyr's add_suffixes)
    x3 = Frame(k = [1], v = [1], v_x = [2])
    y3 = Frame(k = [1], v = [3])
    for r in forall(() -> inner_join(y3; by = :k)(x3))
        @test r.names == [:k, :v_x, :v_x_x, :v_y]
    end
end

@testitem "join: by forms, join_by, natural joins" tags = [:unit] setup = [Force, JoinHelpers] begin
    x = Frame(a = [1, 2, 3], b = ["p", "q", "r"], v = [1.0, 2.0, 3.0])
    y = Frame(a = [3, 1], bb = ["r", "p"], w = [30, 10])
    want = inner_join(y; by = [:a => :a, :b => :bb])(x)
    @test isequal(want, Frame(a = [1, 3], b = ["p", "r"], v = [1.0, 3.0], w = [10, 30]))
    for by in (["a" => "a", "b" => "bb"], [:a, :b => :bb], [:a, "b" => "bb"], join_by(:a, :b => :bb), join_by("a", "b" => "bb"), join_by([:a, :b => :bb]))
        @test isequal(inner_join(y; by)(x), want)
    end
    @test isequal(inner_join(y; by = :a)(x), inner_join(y; by = "a")(x))
    @test isequal(inner_join(y; by = [:a])(x), inner_join(y; by = join_by(:a))(x))
    @test sprint(show, join_by(:a => :b, :c)) == "join_by(:a => :b, :c)"
    # a node is not a key pair (the a == b form is not shipped)
    @test_throws ArgumentError join_by(c.a .== c.b)
    @test_throws ArgumentError join_by(c.a)
    @test_throws ArgumentError inner_join(y; by = Symbol[])(x)
    # natural join: the common names, with an @info naming them, logged once
    yn = Frame(a = [1, 2], b = ["p", "x"], w = [5, 6])
    r = @test_logs (:info, "Joining with by = [:a, :b]") inner_join(yn)(x)
    @test isequal(r, Frame(a = [1], b = ["p"], v = [1.0], w = [5]))
    @test_throws ArgumentError inner_join(Frame(z = [1]))(x)            # no common column
    # missing key columns, duplicate keys
    @test_throws ArgumentError inner_join(y; by = :nope)(x)
    @test_throws ArgumentError inner_join(y; by = :a => :nope)(x)
    @test_throws ArgumentError inner_join(y; by = [:a, :a])(x)
    # unknown keywords are the verb's keyword error
    @test_throws MethodError inner_join(y; by = :a, makeunique = true)
    @test_throws MethodError full_join(y; by = :a, unmatched = :error)
    @test_throws MethodError semi_join(y; by = :a, keep = true)
    # bad option values
    @test_throws ArgumentError inner_join(y; by = :a, multiple = :warning)
    @test_throws ArgumentError inner_join(y; by = :a, unmatched = :warn)
    @test_throws ArgumentError inner_join(y; by = :a, na_matches = :sometimes)
end

@testitem "join: na_matches (missing and NaN keys)" tags = [:unit] setup = [Force, JoinHelpers] begin
    x = Frame(k = Union{Missing, Float64}[1.0, missing, NaN, -0.0], v = [1, 2, 3, 4])
    y = Frame(k = Union{Missing, Float64}[NaN, missing, 0.0], w = [10, 20, 30])
    # :na (default): missing matches missing, NaN matches NaN, ±0.0 is one key; key values are x's
    want = Frame(k = Union{Missing, Float64}[missing, NaN, -0.0], v = [2, 3, 4], w = [20, 10, 30])
    @test same_everywhere(() -> inner_join(y; by = :k)(x), want)
    # :never: a missing or NaN key matches nothing; left keeps those x rows
    want = Frame(k = Union{Missing, Float64}[-0.0], v = [4], w = [30])
    @test same_everywhere(() -> inner_join(y; by = :k, na_matches = :never)(x), want)
    want = Frame(k = Union{Missing, Float64}[1.0, missing, NaN, -0.0], v = [1, 2, 3, 4], w = Union{Missing, Int}[missing, missing, missing, 30])
    @test same_everywhere(() -> left_join(y; by = :k, na_matches = :never)(x), want)
    # full under :never: y's missing/NaN rows are unmatched y rows (appended, keys from y)
    for r in forall(() -> full_join(y; by = :k, na_matches = :never)(x))
        @test isequal(colvec(r, :k), [1.0, missing, NaN, -0.0, NaN, missing])
        @test isequal(colvec(r, :w), [missing, missing, missing, 30, 10, 20])
    end
    @test same_everywhere(() -> semi_join(y; by = :k, na_matches = :never)(x), Frame(k = Union{Missing, Float64}[-0.0], v = [4]))
    @test same_everywhere(() -> anti_join(y; by = :k, na_matches = :never)(x), Frame(k = Union{Missing, Float64}[1.0, missing, NaN], v = [1, 2, 3]))
    @test same_everywhere(() -> semi_join(y; by = :k)(x), Frame(k = Union{Missing, Float64}[missing, NaN, -0.0], v = [2, 3, 4]))
    @test same_everywhere(() -> anti_join(y; by = :k)(x), Frame(k = Union{Missing, Float64}[1.0], v = [1]))
    # several key columns: a NaN in any key column under :never matches nothing
    x2 = Frame(a = [1, 1], b = [NaN, 2.0])
    y2 = Frame(a = [1, 1], b = [NaN, 2.0], w = [1, 2])
    @test same_everywhere(() -> inner_join(y2; by = [:a, :b], na_matches = :never)(x2), Frame(a = [1], b = [2.0], w = [2]))
    @test same_everywhere(() -> inner_join(y2; by = [:a, :b])(x2), Frame(a = [1, 1], b = [NaN, 2.0], w = [1, 2]))
end

@testitem "join: multiple and unmatched (dplyr 1.2.0, unchosen y rows are unmatched)" tags = [:unit] setup = [Force, JoinHelpers] begin
    x = Frame(k = [1], a = [100])
    y = Frame(k = [1, 1], w = [10, 20])
    @test same_everywhere(() -> inner_join(y; by = :k, multiple = :first)(x), Frame(k = [1], a = [100], w = [10]))
    @test same_everywhere(() -> inner_join(y; by = :k, multiple = :any)(x), Frame(k = [1], a = [100], w = [10]))
    @test same_everywhere(() -> inner_join(y; by = :k, multiple = :last)(x), Frame(k = [1], a = [100], w = [20]))
    # right_join(multiple = "first"): 2 rows, the second with a = NA, w = 20
    @test same_everywhere(() -> right_join(y; by = :k, multiple = :first)(x), Frame(k = [1, 1], a = Union{Missing, Int}[100, missing], w = [10, 20]))
    # full_join(multiple = "last"): w = 20 matched, then w = 10 with NA
    @test same_everywhere(() -> full_join(y; by = :k, multiple = :last)(x), Frame(k = [1, 1], a = Union{Missing, Int}[100, missing], w = Union{Missing, Int}[20, 10]))
    # left/inner with unmatched = :error and multiple = :first/:any raise for y row 2
    for kind in (left_join, inner_join), m in (:first, :any)
        es = errors_everywhere(() -> kind(y; by = :k, multiple = m, unmatched = :error)(x))
        @test all(e -> e !== nothing && e[1] === ArgumentError && occursin("Each row of `y` must be matched by `x`", e[2]) && occursin("Row 2 of `y`", e[2]), es)
    end
    # multiple = :error
    es = errors_everywhere(() -> inner_join(y; by = :k, multiple = :error)(x))
    @test all(e -> e !== nothing && occursin("Each row in `x` must match at most 1 row in `y`", e[2]) && occursin("Row 1 of `x`", e[2]), es)
    @test same_everywhere(() -> left_join(Frame(k = [1], w = [5]); by = :k, multiple = :error)(x), Frame(k = [1], a = [100], w = Union{Missing, Int}[5]))
    # unmatched: right checks x, left checks y, inner checks both
    x2 = Frame(k = [1, 2], a = [1, 2])
    y2 = Frame(k = [1, 3], w = [1, 3])
    es = errors_everywhere(() -> right_join(y2; by = :k, unmatched = :error)(x2))
    @test all(e -> e !== nothing && occursin("Each row of `x` must have a match in `y`", e[2]) && occursin("Row 2 of `x`", e[2]), es)
    es = errors_everywhere(() -> left_join(y2; by = :k, unmatched = :error)(x2))
    @test all(e -> e !== nothing && occursin("Each row of `y` must be matched by `x`", e[2]) && occursin("Row 2 of `y`", e[2]), es)
    es = errors_everywhere(() -> inner_join(y2; by = :k, unmatched = :error)(x2))
    @test all(e -> e !== nothing && occursin("Row 2 of `x` does not have a match", e[2]), es)
    @test same_everywhere(() -> inner_join(Frame(k = [2, 1], w = [2, 1]); by = :k, unmatched = :error)(x2), Frame(k = [1, 2], a = [1, 2], w = [1, 2]))
end

@testitem "join: error precedence (one ascending x pass, then the y side; MAJOR-3)" tags = [:unit] setup = [Force, JoinHelpers] begin
    y = Frame(k = [1, 1])
    # x k = [2, 1]: row 1 has no match -> the x-unmatched error for row 1
    es = errors_everywhere(() -> inner_join(y; by = :k, unmatched = :error, multiple = :error)(Frame(k = [2, 1])))
    @test all(e -> e == (ArgumentError, "ArgumentError: Each row of `x` must have a match in `y`. Row 1 of `x` does not have a match."), es)
    # x k = [1, 2]: row 1 matches twice -> the multiple error for row 1
    es = errors_everywhere(() -> inner_join(y; by = :k, unmatched = :error, multiple = :error)(Frame(k = [1, 2])))
    @test all(e -> e == (ArgumentError, "ArgumentError: Each row in `x` must match at most 1 row in `y`. Row 1 of `x` matches multiple rows in `y`."), es)
    # the y-side error only after a clean x-side pass
    es = errors_everywhere(() -> inner_join(Frame(k = [1, 3]); by = :k, unmatched = :error)(Frame(k = [1])))
    @test all(e -> e == (ArgumentError, "ArgumentError: Each row of `y` must be matched by `x`. Row 2 of `y` was not matched."), es)
end

@testitem "join: semi and anti joins" tags = [:unit] setup = [Force, JoinHelpers] begin
    x = Frame(k = [3, 1, 2, 1], v = ["a", "b", "c", "d"])
    y = Frame(k = [1, 1, 4], w = [1, 2, 3])
    @test same_everywhere(() -> semi_join(y; by = :k)(x), Frame(k = [1, 1], v = ["b", "d"]))
    @test same_everywhere(() -> anti_join(y; by = :k)(x), Frame(k = [3, 2], v = ["a", "c"]))
    @test same_everywhere(() -> semi_join(Frame(k = Int[]); by = :k)(x), Frame(k = Int[], v = String[]))
    @test same_everywhere(() -> anti_join(Frame(k = Int[]); by = :k)(x), x)
    # empty x
    @test same_everywhere(() -> inner_join(y; by = :k)(Frame(k = Int[], v = String[])), Frame(k = Int[], v = String[], w = Int[]))
    @test same_everywhere(() -> full_join(y; by = :k)(Frame(k = Int[], v = String[])), Frame(k = [1, 1, 4], v = Vector{Union{Missing, String}}(missing, 3), w = Union{Missing, Int}[1, 2, 3]))
end

@testitem "join: grouping (x keeps its groups, y is ungrouped)" tags = [:unit] setup = [Force, JoinHelpers] begin
    x = group_by(:g)(Frame(g = ["b", "a", "b"], k = [1, 2, 3]))
    y = group_by(:w)(Frame(k = [3, 1], w = [30, 10]))
    for r in forall(() -> left_join(y; by = :k)(x))
        @test groupcols(r) == [:g]
        @test isequal(colvec(r, :w), [10, missing, 30])
        @test ChuiFrames.ngroups(ChuiFrames.gindex(r)) == 2
    end
    for r in forall(() -> semi_join(y; by = :k)(x))
        @test groupcols(r) == [:g]
    end
end

@testitem "join: reserved names, abstract and rejected key types" tags = [:unit] setup = [Force, JoinHelpers] begin
    x = Frame(k = [1, 2])
    @test_throws ArgumentError inner_join(Frame(k = [1], var"##chui_yrow" = [1]); by = :k)(x)
    @test_throws ArgumentError inner_join(Frame(k = [1]); by = :k)(Frame(k = [1], var"##chui_x" = [1]))
    @test_throws ArgumentError nest_join(Frame(k = [1]); by = :k, name = Symbol("##chui_n"))(x)
    # an abstract key element type (n6) names the column
    xa = Frame(k = ChuiFrames.ObjectColumn(Any[1, 2]))
    err = try
        inner_join(Frame(k = ChuiFrames.ObjectColumn(Any[1])); by = :k)(xa)
    catch e
        e
    end
    @test err isa ArgumentError && occursin("`k`", err.msg)
    # rejected pairs (N1): Date vs DateTime, Int64 vs UInt64, string vs number
    using Dates
    for (a, b) in ((Date(2020), DateTime(2020)), (Int64(1), UInt64(1)), ("1", 1))
        e = try
            inner_join(Frame(k = [b]); by = :k)(Frame(k = [a]))
        catch err
            err
        end
        @test e isa ArgumentError && occursin("`k`", e.msg)
    end
end

@testitem "join: nest_join (dplyr 1.2.0, tidyr nest representation)" tags = [:unit] setup = [Force, JoinHelpers] begin
    x = Frame(k = [2, 1, 3], v = ["p", "q", "r"])
    y = Frame(k = [2, 1, 2], w = [1.0, 2.0, 3.0], v = ["a", "b", "c"])
    for r in forall(() -> nest_join(y; by = :k)(x))
        @test r.names == [:k, :v, :y]
        @test ChuiFrames.getcol(r, :y) isa ChuiFrames.ObjectColumn
        @test eltype(ChuiFrames.getcol(r, :y)) === Frame
        ys = colvec(r, :y)
        # y order within a row; no suffix inside the nested frame
        @test isequal(ys[1], Frame(w = [1.0, 3.0], v = ["a", "c"]))
        @test isequal(ys[2], Frame(w = [2.0], v = ["b"]))
        # no match: a 0-row frame with y's names and column types
        @test ys[3].nrow == 0 && ys[3].names == [:w, :v]
        @test [eltype(c) for c in ys[3].columns] == [eltype(c) for c in ys[1].columns]
    end
    for r in forall(() -> nest_join(y; by = :k, keep = true, name = :m)(x))
        @test r.names == [:k, :v, :m]
        @test colvec(r, :m)[1].names == [:k, :w, :v]
    end
    # a 0-row x gives a 0-row result that still has the column
    for r in forall(() -> nest_join(y; by = :k)(Frame(k = Int[], v = String[])))
        @test r.names == [:k, :v, :y] && r.nrow == 0
    end
    # unmatched = :error checks y only
    @test all(isnothing, errors_everywhere(() -> nest_join(Frame(k = [1]); by = :k, unmatched = :error)(x)))
    es = errors_everywhere(() -> nest_join(Frame(k = [1, 9]); by = :k, unmatched = :error)(x))
    @test all(e -> e == (ArgumentError, "ArgumentError: Each row of `y` must be matched by `x`. Row 2 of `y` was not matched."), es)
    # under na_matches = :never a y row with a missing/NaN key is unmatched
    xn = Frame(k = Union{Missing, Int}[1, missing])
    yn = Frame(k = Union{Missing, Int}[1, missing])
    es = errors_everywhere(() -> nest_join(yn; by = :k, na_matches = :never, unmatched = :error)(xn))
    @test all(e -> e !== nothing && occursin("Row 2 of `y` was not matched", e[2]), es)
    for r in forall(() -> nest_join(yn; by = :k, na_matches = :never)(xn))
        @test [f.nrow for f in colvec(r, :y)] == [1, 0]
    end
    # no multiple / suffix keywords (dplyr: "`...` must be empty")
    @test_throws MethodError nest_join(y; by = :k, multiple = :first)
    # grouped x keeps its groups; a grouped y nests ungrouped frames
    for r in forall(() -> nest_join(group_by(:k)(y); by = :k)(group_by(:v)(x)))
        @test groupcols(r) == [:v]
        @test all(f -> !isgrouped(f), colvec(r, :y))
    end
end

@testitem "join: nest_join name clashes (replace x's column with a @warn, once)" tags = [:unit] setup = [Force, JoinHelpers] begin
    y = Frame(k = [1, 1], w = [1, 2])
    # x(a, y, k) with name = "y" -> a y k: the nested column takes the replaced column's position
    x = Frame(a = [5], y = ["old"], k = [1])
    r = @test_logs (:warn, r"replaces x's column :y") nest_join(y; by = :k)(x)
    @test r.names == [:a, :y, :k]
    @test colvec(r, :y)[1] isa Frame
    quiet(f) = Base.CoreLogging.with_logger(f, Base.CoreLogging.NullLogger())
    for r in quiet(() -> forall(() -> nest_join(y; by = :k)(x)))
        @test r.names == [:a, :y, :k]
    end
    # name equal to the key column (keep = false) replaces the key too
    x2 = Frame(k = [1, 2], v = ["a", "b"])
    r = @test_logs (:warn, r"replaces x's column :k") nest_join(y; by = :k, name = :k)(x2)
    @test r.names == [:k, :v] && eltype(ChuiFrames.getcol(r, :k)) === Frame
    # name equal to a grouping column keeps the grouping, now by the list column
    xg = group_by(:v)(Frame(k = [1, 2, 1], v = ["a", "b", "c"]))
    r = @test_logs (:warn, r"replaces x's column :v") nest_join(y; by = :k, name = :v)(xg)
    @test groupcols(r) == [:v]
    @test ChuiFrames.ngroups(ChuiFrames.gindex(r)) == 2     # rows 1 and 3 nest equal frames
    # on inputs with no clashing names, unnest(name) of the result equals the inner join
    x3 = Frame(k = [2, 1, 3], v = ["p", "q", "r"])
    y3 = Frame(k = [2, 1, 2], w = [1.0, 2.0, 3.0])
    @test isequal(unnest(:y)(nest_join(y3; by = :k)(x3)), inner_join(y3; by = :k)(x3))
end

@testitem "join: cross_join" tags = [:unit] setup = [Force, JoinHelpers] begin
    x = Frame(a = [1, 2], v = ["p", "q"])
    y = Frame(v = ["s", "t", "u"])
    for r in forall(() -> cross_join(y)(x))                 # _FORCE_JOIN does not apply
        @test r.names == [:a, :v_x, :v_y]
        @test isequal(colvec(r, :a), [1, 1, 1, 2, 2, 2])
        @test isequal(colvec(r, :v_y), ["s", "t", "u", "s", "t", "u"])
    end
    @test cross_join(y)(Frame(a = Int[])).nrow == 0
    @test isequal(cross_join(Frame(z = [1]); suffix = (".a", ".b"))(Frame(z = [2])).names, [Symbol("z.a"), Symbol("z.b")])
    @test groupcols(cross_join(y)(group_by(:a)(x))) == [:a]
end

@testitem "join: DataAPI methods forward `on` to `by`" tags = [:unit] setup = [Force, JoinHelpers] begin
    using DataAPI
    x = Frame(k = [1, 2, 3], v = [1, 2, 3])
    y = Frame(k = [3, 1, 4], w = [30, 10, 40])
    @test isequal(DataAPI.innerjoin(x, y; on = :k), inner_join(y; by = :k)(x))
    @test isequal(DataAPI.leftjoin(x, y; on = :k), left_join(y; by = :k)(x))
    @test isequal(DataAPI.rightjoin(x, y; on = :k), right_join(y; by = :k)(x))
    @test isequal(DataAPI.outerjoin(x, y; on = :k), full_join(y; by = :k)(x))
    @test isequal(DataAPI.semijoin(x, y; on = :k), semi_join(y; by = :k)(x))
    @test isequal(DataAPI.antijoin(x, y; on = :k), anti_join(y; by = :k)(x))
    @test isequal(DataAPI.crossjoin(x, y), cross_join(y)(x))
    @test isequal(DataAPI.innerjoin(x, y; on = join_by(:k), keep = true), inner_join(y; by = :k, keep = true)(x))
    @test isequal(DataAPI.leftjoin(x, y; on = :k, multiple = :first, unmatched = :drop), left_join(y; by = :k, multiple = :first)(x))
    @test_throws MethodError DataAPI.innerjoin(x, y; on = :k, makeunique = true)
    r = @test_logs (:info, "Joining with by = [:k]") DataAPI.innerjoin(x, y)
    @test isequal(r, inner_join(y; by = :k)(x))
end

@testitem "join: a lazy y under an eager x is collected first" tags = [:unit] setup = [Force, JoinHelpers] begin
    x = Frame(k = [1, 2], v = [1, 2])
    y = Frame(k = [2, 3], w = [20, 30])
    @test isequal(inner_join(lazy(y) |> filter(c.w .> 0); by = :k)(x), inner_join(y; by = :k)(x))
    @test isequal(left_join(lazy(y); by = :k)(x), left_join(y; by = :k)(x))
end
