# Unit tests for separate_wider_*, separate_longer_* and unite (tidyr 1.3.1 behaviour, checked
# in R; the differential file compares against R directly).

@testsnippet SV begin
    using Tables
    using DataAPI: nrow
    const ⨟ = ChuiFrames.Upstream.:⨟
    col(x, n) = collect(Tables.getcolumn(x, n))
    names_of(x) = collect(Tables.columnnames(x))
    eq(a, b) = isequal(a, b)
    T(x, n) = eltype(Tables.getcolumn(x, n))
    errmsg(f) = try
        f()
        ""
    catch e
        e isa ArgumentError ? e.msg : rethrow()
    end
    d = (id = [1, 2, 3, 4, 5], x = Union{Missing, String}["a-b-c", "d-e", missing, "f-g-h-i", ""])
end

@testitem "separate_wider_delim: too_few, too_many, names" tags = [:unit] setup = [SV] begin
    m = errmsg(() -> separate_wider_delim(:x, "-"; names = [:p, :q, :r])(d))
    @test occursin("too short", m) && occursin("too long", m) && occursin("too_few", m) && occursin("too_many", m)
    r = separate_wider_delim(:x, "-"; names = [:p, :q, :r], too_few = :align_start, too_many = :drop)(d)
    @test names_of(r) == [:id, :p, :q, :r]
    @test eq(col(r, :p), ["a", "d", missing, "f", ""])
    @test eq(col(r, :q), ["b", "e", missing, "g", missing])
    @test eq(col(r, :r), ["c", missing, missing, "h", missing])
    @test T(r, :p) == Union{Missing, ChuiFrames.StrView}
    r = separate_wider_delim(:x, "-"; names = ["p", "q", "r"], too_few = :align_end, too_many = :merge)(d)
    @test eq(col(r, :p), ["a", missing, missing, "f", missing])
    @test eq(col(r, :q), ["b", "d", missing, "g", missing])
    @test eq(col(r, :r), ["c", "e", missing, "h-i", ""])
    # `nothing` in names drops that piece
    r = separate_wider_delim(:x, "-"; names = [:p, nothing, :r], too_few = :align_start, too_many = :drop)(d)
    @test names_of(r) == [:id, :p, :r]
    # cols_remove = false keeps the input after the new columns
    r = separate_wider_delim(:x, "-"; names = [:p, :q], too_few = :align_start, too_many = :drop, cols_remove = false)(d)
    @test names_of(r) == [:id, :p, :q, :x]
    # names_sep without names: as many columns as the longest value
    r = separate_wider_delim(:x, "-"; names_sep = "_", too_few = :align_start)(d)
    @test names_of(r) == [:id, :x_1, :x_2, :x_3, :x_4]
    r = separate_wider_delim(:x, "-"; names = [:p, :q], names_sep = "_")((x = ["a-b"],))
    @test names_of(r) == [:x_p, :x_q]
    # regex delimiter; a delimiter that is a regex metacharacter is literal as a string
    r = separate_wider_delim(:x, r"[0-9]"; names = [:p, :q, :r])((x = ["a1b2c"],))
    @test eq(col(r, :r), ["c"])
    r = separate_wider_delim(:x, "."; names = [:p, :q])((x = ["a.b"],))
    @test eq(col(r, :q), ["b"])
    # non-nullable input with too_few = :error gives non-nullable strings
    r = separate_wider_delim(:x, "-"; names = [:p, :q])((x = ["a-b", "c-d"],))
    @test !(Missing <: T(r, :p))
end

@testitem "separate_wider_delim: empty, grouped, errors, show" tags = [:unit] setup = [SV] begin
    e = (id = Int[], x = String[])
    r = separate_wider_delim(:x, "-"; names = [:p, :q])(e)
    @test names_of(r) == [:id, :p, :q] && nrow(r) == 0
    g = group_by(:id)(d)
    r = separate_wider_delim(:x, "-"; names = [:p, :q], too_few = :align_start, too_many = :drop)(g)
    @test groupcols(r) == [:id]
    r = separate_wider_delim(:x, "-"; names = [:p, :q], too_few = :align_start, too_many = :drop)(group_by(:x)(d))
    @test groupcols(r) == Symbol[]                                    # the grouping column was removed
    @test_throws ArgumentError separate_wider_delim(:x, "-")                     # names or names_sep
    @test_throws ArgumentError separate_wider_delim(:x, "-"; names = [:p], too_few = :bad)
    @test_throws ArgumentError separate_wider_delim(:x, "-"; names = [:p], too_many = :bad)
    @test occursin("duplicate", errmsg(() -> separate_wider_delim(:x, "-"; names = [:p, :q])((x = ["a-b"], p = [1]))))
    @test occursin("string", errmsg(() -> separate_wider_delim(:x, "-"; names = [:p, :q])((x = [1, 2],))))
    @test occursin("separate_wider_delim", repr(separate_wider_delim(:x, "-"; names = [:p, :q])))
end

@testitem "separate_wider_position" tags = [:unit] setup = [SV] begin
    t = (x = Union{Missing, String}["abcde", "ab", missing, "abcdefg"],)
    m = errmsg(() -> separate_wider_position(:x; widths = [:a => 2, nothing => 1, :b => 2])(t))
    @test occursin("too short", m) && occursin("too long", m)
    r = separate_wider_position(:x; widths = [:a => 2, nothing => 1, :b => 2], too_few = :align_start, too_many = :drop)(t)
    @test names_of(r) == [:a, :b]
    @test eq(col(r, :a), ["ab", "ab", missing, "ab"])
    @test eq(col(r, :b), ["de", missing, missing, "de"])
    # partial pieces (tidyr): a piece that starts inside the string keeps what is there
    r = separate_wider_position(:x; widths = (a = 2, b = 2), too_few = :align_start)((x = ["abc", "a"],))
    @test eq(col(r, :a), ["ab", "a"]) && eq(col(r, :b), ["c", missing])
    # widths count characters, not bytes
    r = separate_wider_position(:x; widths = (a = 1, b = 2))((x = ["éßç"],))
    @test eq(col(r, :a), ["é"]) && eq(col(r, :b), ["ßç"])
    r = separate_wider_position(:x; widths = (a = 2, b = 3), cols_remove = false)((x = ["abcde"],))
    @test names_of(r) == [:a, :b, :x]
    @test !(Missing <: T(r, :a))
    @test_throws ArgumentError separate_wider_position(:x; widths = (a = 2,), too_few = :align_end)
    @test_throws ArgumentError separate_wider_position(:x; widths = (a = 2,), too_many = :merge)
    @test_throws ArgumentError separate_wider_position(:x; widths = (a = 0,))
    @test nrow(separate_wider_position(:x; widths = (a = 2,))((x = String[],))) == 0
    @test occursin("separate_wider_position", repr(separate_wider_position(:x; widths = (a = 2,))))
end

@testitem "separate_wider_regex" tags = [:unit] setup = [SV] begin
    t = (x = Union{Missing, String}["x12-ab", "y3-c", missing, "nope"],)
    pats = [:l => "[a-z]", :n => "[0-9]+", nothing => "-", :s => "[a-z]+"]
    @test occursin("match", errmsg(() -> separate_wider_regex(:x; patterns = pats)(t)))
    r = separate_wider_regex(:x; patterns = pats, too_few = :align_start)(t)
    @test names_of(r) == [:l, :n, :s]
    @test eq(col(r, :l), ["x", "y", missing, "n"])
    @test eq(col(r, :n), ["12", "3", missing, missing])
    @test eq(col(r, :s), ["ab", "c", missing, missing])
    # anchored: trailing text is an error, accepted by align_start
    @test_throws ArgumentError separate_wider_regex(:x; patterns = pats)((x = ["x12-abZZ"],))
    r = separate_wider_regex(:x; patterns = pats, too_few = :align_start)((x = ["x12-abZZ", "x12", "12"],))
    @test eq(col(r, :s), ["ab", missing, missing]) && eq(col(r, :n), ["12", "12", missing])
    # Regex values and a NamedTuple of patterns
    r = separate_wider_regex(:x; patterns = (a = r"[a-z]+", b = r"\d+"), cols_remove = false)((x = ["ab12"],))
    @test names_of(r) == [:a, :b, :x] && eq(col(r, :b), ["12"])
    @test !(Missing <: T(r, :a))
    # capture groups inside a pattern are an error (use (?:...))
    @test occursin("(?:", errmsg(() -> separate_wider_regex(:x; patterns = [:a => "[a-z]", :n => "([0-9])+"])((x = ["a1"],))))
    @test_throws ArgumentError separate_wider_regex(:x; patterns = [:a => "a"], too_few = :align_end)
    @test nrow(separate_wider_regex(:x; patterns = pats)((x = String[],))) == 0
end

@testitem "separate_longer_delim and separate_longer_position" tags = [:unit] setup = [SV] begin
    t = (id = [1, 2, 3, 4], x = Union{Missing, String}["a,b", missing, "", "c"])
    r = separate_longer_delim(:x, ",")(t)
    @test eq(col(r, :id), [1, 1, 2, 3, 4])
    @test eq(col(r, :x), ["a", "b", missing, "", "c"])
    @test groupcols(separate_longer_delim(:x, ",")(group_by(:id)(t))) == [:id]
    r = separate_longer_delim(:x, r"[0-9]+")((id = [1, 2], x = ["a1b22c", "d"]))
    @test eq(col(r, :x), ["a", "b", "c", "d"])
    # several columns: pieces pair up; a single piece is recycled
    r = separate_longer_delim([:x, :y], ",")((x = ["a,b", "d"], y = ["p,q", "r"]))
    @test eq(col(r, :x), ["a", "b", "d"]) && eq(col(r, :y), ["p", "q", "r"])
    r = separate_longer_delim([:x, :y], ",")((x = ["a,b"], y = ["p"]))
    @test eq(col(r, :y), ["p", "p"])
    @test_throws ArgumentError separate_longer_delim([:x, :y], ",")((x = ["a,b"], y = ["p,q,r"]))
    @test !(Missing <: T(separate_longer_delim(:x, ",")((x = ["a,b"],)), :x))
    @test nrow(separate_longer_delim(:x, ",")((x = String[],))) == 0
    # position
    p = (id = [1, 2, 3, 4], x = Union{Missing, String}["abcde", "", "a", missing])
    r = separate_longer_position(:x, 2)(p)
    @test eq(col(r, :id), [1, 1, 1, 3, 4])
    @test eq(col(r, :x), ["ab", "cd", "e", "a", missing])
    r = separate_longer_position(:x, 2; keep_empty = true)(p)
    @test eq(col(r, :id), [1, 1, 1, 2, 3, 4])
    @test eq(col(r, :x), ["ab", "cd", "e", missing, "a", missing])
    @test eq(col(separate_longer_position(:x, 1)((x = ["éß"],)), :x), ["é", "ß"])
    @test_throws ArgumentError separate_longer_position(:x, 0)
    @test occursin("separate_longer_position", repr(separate_longer_position(:x, 2)))
    @test occursin("separate_longer_delim", repr(separate_longer_delim(:x, ",")))
end

@testitem "unite" tags = [:unit] setup = [SV] begin
    t = (a = Union{Missing, String}["x", missing, "z"], b = Union{Missing, Int}[1, 2, missing], c = Union{Missing, String}["p", "q", missing])
    r = unite(:ab, :a, :b)(t)
    @test names_of(r) == [:ab, :c]
    @test eq(col(r, :ab), ["x_1", "NA_2", "z_NA"])
    @test !(Missing <: T(r, :ab))
    @test eq(col(unite(:ab, :a, :b; na_rm = true)(t), :ab), ["x_1", "2", "z"])
    r = unite("ab", :b, :c; sep = "", remove = false)(t)
    @test names_of(r) == [:a, :ab, :b, :c]
    @test eq(col(r, :ab), ["1p", "2q", "NANA"])
    # text in selection order; placed where the leftmost united column was
    r = unite(:ab, :c, :a)(t)
    @test names_of(r) == [:ab, :b]
    @test eq(col(r, :ab), ["p_x", "q_NA", "NA_z"])
    # no columns: every column; selectors
    @test eq(col(unite(:all)(t), :all), ["x_1_p", "NA_2_q", "z_NA_NA"])
    @test eq(col(unite(:ac, r"^[ac]$")(t), :ac), ["x_p", "NA_q", "z_NA"])
    # Julia's `string` for non-strings (R writes TRUE and 1, Julia true and 1.0; documented)
    @test eq(col(unite(:z, :a, :b)((a = [true], b = [1.5])), :z), ["true_1.5"])
    # grouping: a removed grouping column leaves the grouping
    @test groupcols(unite(:ab, :a, :b)(group_by(:a)(t))) == Symbol[]
    @test groupcols(unite(:ab, :a, :b)(group_by(:c)(t))) == [:c]
    # replaces an existing column of the new name
    @test names_of(unite(:c, :a, :b)(t)) == [:c]
    r = unite(:ab, :a, :b)((a = String[], b = Int[]))
    @test nrow(r) == 0 && names_of(r) == [:ab]
    @test eq(col(unite(:z, :a, :b; na_rm = true)((a = Union{Missing, String}["x", missing], b = Union{Missing, String}[missing, missing])), :z), ["x", ""])
    @test occursin("unite", repr(unite(:ab, :a, :b; sep = "-")))
end
