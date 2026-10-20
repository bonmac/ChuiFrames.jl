# tidyr string-column verbs (phase 2b): separate_wider_delim/_position/_regex,
# separate_longer_delim/_position and unite, eager, matching tidyr 1.3.1 where checked in R
# (test/engine/differential_tidyr_pivot_tests.jl). Uses `_colname`, `_reshaped` and
# `_pivot_checkunique` from verbs_pivot.jl.

# The string column `j` of `f` (any declared element type `<: AbstractString`, maybe nullable).
function _strcol(f::Frame, j::Int, verb)
    c = f.columns[j]
    T = nonmissingtype(eltype(c))
    (T <: AbstractString || T === Union{}) ||
        throw(ArgumentError("$verb: column $(repr(f.names[j])) has element type $(eltype(c)), not a string type; convert it first (e.g. mutate($(f.names[j]) = string.(c.$(f.names[j]))))"))
    return c
end

_nullable_input(c) = Missing <: eltype(c)

# A string output column: nullable (`Union{Missing,String}`) by declaration, or plain `String`.
_strout(v::Vector{Union{Missing, String}}, nullable::Bool) = nullable ? column(v) : column(Vector{String}(v))

function _rowlist(rows)
    shown = join(rows[1:min(end, 10)], ", ")
    return length(rows) > 10 ? "$shown, …" : shown
end
_values(k) = k == 1 ? "1 value was" : "$k values were"

# Replace each selected column by its new columns (and keep it after them unless removed).
function _widen(f::Frame, sel::Vector{Int}, new::Dict{Int, Tuple{Vector{Symbol}, Vector{AbstractColumn}}}, cols_remove::Bool, verb)
    names = Symbol[]
    cols = AbstractColumn[]
    for i in eachindex(f.names)
        if haskey(new, i)
            nn, nc = new[i]
            append!(names, nn)
            append!(cols, nc)
            cols_remove || (push!(names, f.names[i]); push!(cols, f.columns[i]))
        else
            push!(names, f.names[i])
            push!(cols, f.columns[i])
        end
    end
    allunique(names) ||
        throw(ArgumentError("$verb: the new columns would duplicate existing names $(join(repr.(unique(n for n in names if count(==(n), names) > 1)), ", ")); use names_sep to prefix them with the column name, or choose other names"))
    return _reshaped(f, names, cols, f.nrow)
end

_checkchoice(verb, kw, v, allowed) = v in allowed ||
    throw(ArgumentError("$verb: $kw must be one of $(join(repr.(allowed), ", ")), got $(repr(v))"))

_optnames(names) = Union{Nothing, Symbol}[x === nothing ? nothing : _colname(x) for x in names]

# =============================================================================================
# separate_wider_delim

struct SeparateWiderDelimStep <: Step
    cols::Any
    delim::Union{String, Regex}
    names::Union{Nothing, Vector{Union{Nothing, Symbol}}}
    names_sep::Union{Nothing, String}
    too_few::Symbol
    too_many::Symbol
    cols_remove::Bool
end

"""
    separate_wider_delim(col, delim; names = nothing, names_sep = nothing, too_few = :error,
                         too_many = :error, cols_remove = true)

Split a string column into columns at `delim` (a string, matched literally, or a `Regex`), as
tidyr's `separate_wider_delim`. `col` may be any selector (ADR-0002 rule 7); each selected
column is replaced, at its position, by the new columns (and kept after them with
`cols_remove = false`).

- `names`: the new column names (Symbols or strings); a `nothing` entry drops that piece.
  With `names_sep`, names are prefixed: `x_p` for column `x`, name `p`, `names_sep = "_"`.
  Without `names`, `names_sep` is required and the columns are `x_1`, `x_2`, … up to the
  most pieces in any value (a **data-dependent** column count).
- `too_few` ∈ (`:error`, `:align_start`, `:align_end`): fewer pieces than names are an error,
  or padded with `missing` at the end or the start.
- `too_many` ∈ (`:error`, `:drop`, `:merge`): more pieces are an error, dropped, or kept in
  the last column with their delimiters.
- A `missing` value gives `missing` in every new column; `""` is one empty piece.

New columns are declared `String` when the input is non-nullable and `too_few = :error`, else
`Union{Missing,String}` (ADR-0001 rule 1). A non-string column is an `ArgumentError` (tidyr
converts it to text first). tidyr's `"debug"` options and `names_repair` are not provided.
"""
function separate_wider_delim(col, delim; names = nothing, names_sep = nothing, too_few = :error, too_many = :error, cols_remove::Bool = true)
    verb = "separate_wider_delim"
    tf, tm = Symbol(too_few), Symbol(too_many)
    _checkchoice(verb, "too_few", tf, (:error, :align_start, :align_end))
    _checkchoice(verb, "too_many", tm, (:error, :drop, :merge))
    names === nothing && names_sep === nothing &&
        throw(ArgumentError("$verb: give names (the new column names) or names_sep (to number them x_1, x_2, …)"))
    delim isa Union{AbstractString, Regex} || throw(ArgumentError("$verb: delim must be a string or a Regex, got $(repr(delim))"))
    d = delim isa AbstractString ? String(delim) : delim
    d isa String && isempty(d) && throw(ArgumentError("$verb: delim must not be empty"))
    nm = names === nothing ? nothing : _optnames(names)
    return SeparateWiderDelimStep(col, d, nm, names_sep === nothing ? nothing : String(names_sep), tf, tm, cols_remove)
end

_namesrepr(nm) = "[" * join([x === nothing ? "nothing" : repr(x) for x in nm], ", ") * "]"
function _wideopts(s)
    o = String[]
    hasproperty(s, :names) && s.names !== nothing && push!(o, "names = $(_namesrepr(s.names))")
    hasproperty(s, :names_sep) && s.names_sep !== nothing && push!(o, "names_sep = $(repr(s.names_sep))")
    s.too_few === :error || push!(o, "too_few = $(repr(s.too_few))")
    hasproperty(s, :too_many) && s.too_many !== :error && push!(o, "too_many = $(repr(s.too_many))")
    s.cols_remove || push!(o, "cols_remove = false")
    return o
end
Base.show(io::IO, s::SeparateWiderDelimStep) =
    print(io, "separate_wider_delim(", _selrepr(s.cols), ", ", repr(s.delim), isempty(_wideopts(s)) ? "" : "; " * join(_wideopts(s), ", "), ")")

function apply(s::SeparateWiderDelimStep, f::Frame)
    verb = "separate_wider_delim"
    sel = resolve(s.cols, f)
    new = Dict{Int, Tuple{Vector{Symbol}, Vector{AbstractColumn}}}()
    for j in sel
        c = _strcol(f, j, verb)
        x = f.names[j]
        split_ = [ismissing(v) ? nothing : split(String(v), s.delim) for v in c]
        p = s.names === nothing ? maximum((length(q) for q in split_ if q !== nothing); init = 0) : length(s.names)
        short, long = Int[], Int[]
        pieces = [Vector{Union{Missing, String}}(undef, f.nrow) for _ in 1:p]
        for (i, q) in enumerate(split_)
            if q === nothing
                foreach(v -> v[i] = missing, pieces)
                continue
            end
            L = length(q)
            row = Union{Missing, String}[String(t) for t in q]
            if L < p
                s.too_few === :error && push!(short, i)
                row = s.too_few === :align_end ? [fill(missing, p - L); row] : [row; fill(missing, p - L)]
            elseif L > p
                s.too_many === :error && push!(long, i)
                row = s.too_many === :merge ? Union{Missing, String}[String(t) for t in split(String(c[i]), s.delim; limit = p)] : row[1:p]
            end
            for k in 1:p
                pieces[k][i] = row[k]
            end
        end
        if !isempty(short) || !isempty(long)
            msg = "$verb: expected $p pieces in each element of $(repr(x))"
            isempty(short) || (msg *= "; $(_values(length(short))) too short (rows $(_rowlist(short))): use too_few = :align_start or :align_end")
            isempty(long) || (msg *= "; $(_values(length(long))) too long (rows $(_rowlist(long))): use too_many = :drop or :merge")
            throw(ArgumentError(msg))
        end
        nullable = _nullable_input(c) || s.too_few !== :error
        nn, nc = Symbol[], AbstractColumn[]
        for k in 1:p
            base = s.names === nothing ? string(k) : s.names[k]
            base === nothing && continue
            push!(nn, s.names === nothing || s.names_sep !== nothing ? Symbol(string(x, s.names_sep, base)) : base)
            push!(nc, _strout(pieces[k], nullable))
        end
        new[j] = (nn, nc)
    end
    return _widen(f, sel, new, s.cols_remove, verb)
end

# =============================================================================================
# separate_wider_position

struct SeparateWiderPositionStep <: Step
    cols::Any
    widths::Vector{Pair{Union{Nothing, Symbol}, Int}}
    too_few::Symbol
    too_many::Symbol
    cols_remove::Bool
end

_widthpairs(w::NamedTuple) = [k => v for (k, v) in pairs(w)]
_widthpairs(w::AbstractVector) = collect(w)
_widthpairs(w) = throw(ArgumentError("separate_wider_position: widths must be a NamedTuple (a = 2, b = 3) or a vector of Pairs [:a => 2, nothing => 1], got $(repr(w))"))

"""
    separate_wider_position(col; widths, too_few = :error, too_many = :error, cols_remove = true)

Split a string column into columns of fixed widths, as tidyr's `separate_wider_position`.
`widths` is a `NamedTuple` (`(a = 2, b = 3)`) or a vector of Pairs (`[:a => 2, nothing => 1,
:b => 2]`, where `nothing` skips those characters). Widths count Julia `Char`s (Unicode code
points), not bytes or graphemes.

- `too_few` ∈ (`:error`, `:align_start`): a shorter value is an error, or each piece takes the
  characters that are there (a piece starting past the end is `missing`).
- `too_many` ∈ (`:error`, `:drop`): a longer value is an error, or the rest is dropped.
- A `missing` value gives `missing` in every new column.

New columns are declared `String` when the input is non-nullable and `too_few = :error`, else
`Union{Missing,String}` (ADR-0001 rule 1). Placement and `cols_remove` as
[`separate_wider_delim`](@ref).
"""
function separate_wider_position(col; widths, too_few = :error, too_many = :error, cols_remove::Bool = true)
    verb = "separate_wider_position"
    tf, tm = Symbol(too_few), Symbol(too_many)
    _checkchoice(verb, "too_few", tf, (:error, :align_start))
    _checkchoice(verb, "too_many", tm, (:error, :drop))
    ws = Pair{Union{Nothing, Symbol}, Int}[]
    for p in _widthpairs(widths)
        p isa Pair || throw(ArgumentError("$verb: each width must be a Pair name => width, got $(repr(p))"))
        (p.second isa Integer && p.second > 0) || throw(ArgumentError("$verb: widths must be positive integers, got $(repr(p))"))
        push!(ws, (p.first === nothing ? nothing : _colname(p.first)) => Int(p.second))
    end
    isempty(ws) && throw(ArgumentError("$verb: widths must name at least one piece"))
    return SeparateWiderPositionStep(col, ws, tf, tm, cols_remove)
end
Base.show(io::IO, s::SeparateWiderPositionStep) = print(
    io, "separate_wider_position(", _selrepr(s.cols), "; widths = [",
    join(["$(p.first === nothing ? "nothing" : repr(p.first)) => $(p.second)" for p in s.widths], ", "), "]",
    isempty(_wideopts(s)) ? "" : ", " * join(_wideopts(s), ", "), ")"
)

function apply(s::SeparateWiderPositionStep, f::Frame)
    verb = "separate_wider_position"
    sel = resolve(s.cols, f)
    total = sum(last, s.widths)
    starts = cumsum([1; [last(p) for p in s.widths]])
    new = Dict{Int, Tuple{Vector{Symbol}, Vector{AbstractColumn}}}()
    for j in sel
        c = _strcol(f, j, verb)
        x = f.names[j]
        short, long = Int[], Int[]
        pieces = [Vector{Union{Missing, String}}(undef, f.nrow) for _ in s.widths]
        for i in 1:f.nrow
            v = c[i]
            if ismissing(v)
                foreach(p -> p[i] = missing, pieces)
                continue
            end
            chars = collect(String(v))
            L = length(chars)
            L < total && s.too_few === :error && push!(short, i)
            L > total && s.too_many === :error && push!(long, i)
            for k in eachindex(s.widths)
                a, b = starts[k], starts[k + 1] - 1
                pieces[k][i] = a > L ? missing : String(chars[a:min(b, L)])
            end
        end
        if !isempty(short) || !isempty(long)
            msg = "$verb: expected $total characters in each element of $(repr(x))"
            isempty(short) || (msg *= "; $(_values(length(short))) too short (rows $(_rowlist(short))): use too_few = :align_start")
            isempty(long) || (msg *= "; $(_values(length(long))) too long (rows $(_rowlist(long))): use too_many = :drop")
            throw(ArgumentError(msg))
        end
        nullable = _nullable_input(c) || s.too_few !== :error
        nn = Symbol[p.first for p in s.widths if p.first !== nothing]
        nc = AbstractColumn[_strout(pieces[k], nullable) for k in eachindex(s.widths) if s.widths[k].first !== nothing]
        new[j] = (nn, nc)
    end
    return _widen(f, sel, new, s.cols_remove, verb)
end

# =============================================================================================
# separate_wider_regex

struct SeparateWiderRegexStep <: Step
    cols::Any
    patterns::Vector{Pair{Union{Nothing, Symbol}, String}}
    too_few::Symbol
    cols_remove::Bool
end

_patpairs(p::NamedTuple) = [k => v for (k, v) in pairs(p)]
_patpairs(p::AbstractVector) = collect(p)
_patpairs(p) = throw(ArgumentError("separate_wider_regex: patterns must be a vector of Pairs [:a => \"[a-z]+\", nothing => \"-\"] or a NamedTuple, got $(repr(p))"))
_pattext(r::Regex) = r.pattern
_pattext(r::AbstractString) = String(r)
_pattext(r) = throw(ArgumentError("separate_wider_regex: a pattern must be a string or a Regex, got $(repr(r))"))

"""
    separate_wider_regex(col; patterns, too_few = :error, cols_remove = true)

Split a string column into columns by matching regular expressions in sequence, as tidyr's
`separate_wider_regex`. `patterns` is a vector of Pairs (`[:a => "[a-z]+", nothing => "-",
:b => "\\\\d+"]`) or a `NamedTuple`; a `nothing` name matches without making a column. Values
are strings or `Regex`es (only a `Regex`'s pattern text is used; its flags are ignored, so
write inline flags such as `(?i)`). The whole value must match the concatenated patterns
(anchored at both ends). A pattern must not contain capture groups: write `(?:…)`.

- `too_few` ∈ (`:error`, `:align_start`): a value that does not match is an error, or the
  longest leading run of patterns that matches at the start fills its columns (the rest
  `missing`; trailing text is then ignored, as tidyr does).
- A `missing` value gives `missing` in every new column.

New columns are declared `String` when the input is non-nullable and `too_few = :error`, else
`Union{Missing,String}` (ADR-0001 rule 1). Placement and `cols_remove` as
[`separate_wider_delim`](@ref).
"""
function separate_wider_regex(col; patterns, too_few = :error, cols_remove::Bool = true)
    verb = "separate_wider_regex"
    tf = Symbol(too_few)
    _checkchoice(verb, "too_few", tf, (:error, :align_start))
    ps = Pair{Union{Nothing, Symbol}, String}[]
    for p in _patpairs(patterns)
        p isa Pair || throw(ArgumentError("$verb: each pattern must be a Pair name => pattern, got $(repr(p))"))
        push!(ps, (p.first === nothing ? nothing : _colname(p.first)) => _pattext(p.second))
    end
    isempty(ps) && throw(ArgumentError("$verb: patterns must not be empty"))
    return SeparateWiderRegexStep(col, ps, tf, cols_remove)
end
Base.show(io::IO, s::SeparateWiderRegexStep) = print(
    io, "separate_wider_regex(", _selrepr(s.cols), "; patterns = [",
    join(["$(p.first === nothing ? "nothing" : repr(p.first)) => $(repr(p.second))" for p in s.patterns], ", "), "]",
    isempty(_wideopts(s)) ? "" : ", " * join(_wideopts(s), ", "), ")"
)

function _regexparts(ps)
    parts = String[]
    for (nm, p0) in ps
        p = String(p0)::String   # pattern text (the constructor stores strings; typed for JET)
        # `(?:p)|` always matches "", so its captures count p's own groups
        ng = length(match(Regex("(?:" * p * ")|"), "").captures)
        ng == 0 || throw(ArgumentError("separate_wider_regex: the pattern $(repr(p)) has $ng capture group(s); use (?:…) for grouping inside patterns"))
        push!(parts, nm === nothing ? "(?:" * p * ")" : "(" * p * ")")
    end
    return parts
end

function apply(s::SeparateWiderRegexStep, f::Frame)
    verb = "separate_wider_regex"
    sel = resolve(s.cols, f)
    parts = _regexparts(s.patterns)
    np = length(parts)
    full = Regex("^" * join(parts) * "\\z")
    prefixes = [Regex("^" * join(parts[1:k])) for k in np:-1:1]
    named = [k for k in 1:np if s.patterns[k].first !== nothing]
    new = Dict{Int, Tuple{Vector{Symbol}, Vector{AbstractColumn}}}()
    for j in sel
        c = _strcol(f, j, verb)
        x = f.names[j]
        bad = Int[]
        pieces = [Vector{Union{Missing, String}}(missing, f.nrow) for _ in named]
        for i in 1:f.nrow
            v = c[i]
            ismissing(v) && continue
            str = String(v)
            m = match(full, str)
            if m === nothing
                if s.too_few === :error
                    push!(bad, i)
                    continue
                end
                for r in prefixes
                    m = match(r, str)
                    m === nothing || break
                end
            end
            m === nothing && continue
            for q in eachindex(m.captures)
                cap = m.captures[q]
                pieces[q][i] = cap === nothing ? missing : String(cap)
            end
        end
        isempty(bad) || throw(ArgumentError("$verb: expected each value of $(repr(x)) to match the whole pattern $(repr(full.pattern)); $(_values(length(bad))) not (rows $(_rowlist(bad))): use too_few = :align_start"))
        nullable = _nullable_input(c) || s.too_few !== :error
        new[j] = (Symbol[s.patterns[k].first for k in named], AbstractColumn[_strout(p, nullable) for p in pieces])
    end
    return _widen(f, sel, new, s.cols_remove, verb)
end

# =============================================================================================
# separate_longer_delim / separate_longer_position

struct SeparateLongerStep <: Step
    cols::Any
    delim::Union{Nothing, String, Regex}
    width::Int
    keep_empty::Bool
end

"""
    separate_longer_delim(col, delim)

Split a string column at `delim` (a string, matched literally, or a `Regex`) into rows, as
tidyr's `separate_longer_delim`: each piece becomes a row and the other columns are repeated.
`col` may select several columns: their pieces pair up row by row, a single piece is recycled,
and other unequal counts are an `ArgumentError`. `missing` stays one `missing` row; `""` is one
`""` row. The column's declared element type becomes `String` (nullable when the input is).
"""
function separate_longer_delim(col, delim)
    delim isa Union{AbstractString, Regex} || throw(ArgumentError("separate_longer_delim: delim must be a string or a Regex, got $(repr(delim))"))
    d = delim isa AbstractString ? String(delim) : delim
    d isa String && isempty(d) && throw(ArgumentError("separate_longer_delim: delim must not be empty"))
    return SeparateLongerStep(col, d, 0, false)
end

"""
    separate_longer_position(col, width; keep_empty = false)

Split a string column into rows of `width` characters (Julia `Char`s; the last piece may be
shorter), as tidyr's `separate_longer_position`. `""` gives no row, or one `missing` row with
`keep_empty = true`. **Divergence:** a `missing` value gives one `missing` row (tidyr 1.3.1
raises an error on `NA`). Several columns pair up as in [`separate_longer_delim`](@ref). The
declared element type is `String`, nullable when the input is or with `keep_empty = true`.
"""
function separate_longer_position(col, width::Integer; keep_empty::Bool = false)
    width > 0 || throw(ArgumentError("separate_longer_position: width must be a positive integer, got $width"))
    return SeparateLongerStep(col, nothing, Int(width), keep_empty)
end

Base.show(io::IO, s::SeparateLongerStep) = s.delim === nothing ?
    print(io, "separate_longer_position(", _selrepr(s.cols), ", ", s.width, s.keep_empty ? "; keep_empty = true" : "", ")") :
    print(io, "separate_longer_delim(", _selrepr(s.cols), ", ", repr(s.delim), ")")

function _longerpieces(s::SeparateLongerStep, v)
    ismissing(v) && return Union{Missing, String}[missing]
    str = String(v)
    s.delim === nothing || return Union{Missing, String}[String(t) for t in split(str, s.delim)]
    chars = collect(str)
    isempty(chars) && return s.keep_empty ? Union{Missing, String}[missing] : Union{Missing, String}[]
    return Union{Missing, String}[String(chars[a:min(a + s.width - 1, end)]) for a in 1:s.width:length(chars)]
end

function apply(s::SeparateLongerStep, f::Frame)
    verb = s.delim === nothing ? "separate_longer_position" : "separate_longer_delim"
    sel = resolve(s.cols, f)
    srcs = [_strcol(f, j, verb) for j in sel]
    rowidx = Int[]
    outs = [Union{Missing, String}[] for _ in sel]
    for i in 1:f.nrow
        ps = [_longerpieces(s, c[i]) for c in srcs]
        sizes = unique(length(p) for p in ps if length(p) != 1)
        length(sizes) > 1 &&
            throw(ArgumentError("$verb: row $i splits into $(join([length(p) for p in ps], ", ")) pieces in $(join(repr.(f.names[sel]), ", ")); the counts must be equal (or 1)"))
        L = isempty(sizes) ? 1 : only(sizes)
        for _ in 1:L
            push!(rowidx, i)
        end
        for (q, p) in enumerate(ps)
            append!(outs[q], length(p) == 1 ? fill(p[1], L) : p)
        end
    end
    pos = Dict(j => q for (q, j) in enumerate(sel))
    cols = AbstractColumn[
        haskey(pos, i) ? _strout(outs[pos[i]], _nullable_input(srcs[pos[i]]) || s.keep_empty) : take(f.columns[i], rowidx)
            for i in eachindex(f.names)
    ]
    return _reshaped(f, copy(f.names), cols, length(rowidx))
end

# =============================================================================================
# unite

struct UniteStep <: Step
    col::Symbol
    cols::Vector{Any}
    sep::String
    remove::Bool
    na_rm::Bool
end

"""
    unite(col, cols...; sep = "_", remove = true, na_rm = false)

Paste the columns selected by `cols...` (selectors, ADR-0002 rule 7; none means every column)
into one string column `col`, joined by `sep`, in selection order, as tidyr's `unite`. The new
column takes the place of the leftmost united column; with `remove = true` the united columns
are dropped. An existing column named `col` is replaced. `missing` is written `"NA"` (as R
does), or skipped with `na_rm = true`. Non-string values use Julia's `string`. **Divergence:**
R writes `TRUE` and `1` where Julia writes `true` and `1.0`. The declared element type is
`String` (never missing). A removed grouping column leaves the grouping.
"""
unite(col, cols...; sep::AbstractString = "_", remove::Bool = true, na_rm::Bool = false) =
    UniteStep(_colname(col), Any[cols...], String(sep), remove, na_rm)
function Base.show(io::IO, s::UniteStep)
    print(io, "unite(", repr(s.col))
    for c in s.cols
        print(io, ", ", _selrepr(c))
    end
    o = String[]
    s.sep == "_" || push!(o, "sep = $(repr(s.sep))")
    s.remove || push!(o, "remove = false")
    s.na_rm && push!(o, "na_rm = true")
    return print(io, isempty(o) ? "" : "; " * join(o, ", "), ")")
end

_unitestr(x::AbstractString) = String(x)
_unitestr(x) = string(x)

function apply(s::UniteStep, f::Frame)
    sel = isempty(s.cols) ? collect(eachindex(f.names)) : resolve(s.cols, f)
    vals = Vector{String}(undef, f.nrow)
    for i in 1:f.nrow
        parts = String[]
        for j in sel
            x = f.columns[j][i]
            if ismissing(x)
                s.na_rm || push!(parts, "NA")
            else
                push!(parts, _unitestr(x))
            end
        end
        vals[i] = join(parts, s.sep)
    end
    anchor = isempty(sel) ? length(f.names) + 1 : minimum(sel)
    rest = [i for i in eachindex(f.names) if !(s.remove && i in sel) && f.names[i] != s.col]
    at = count(<(anchor), rest)
    names = Symbol[f.names[rest[1:at]]; s.col; f.names[rest[(at + 1):end]]]
    cols = AbstractColumn[f.columns[rest[1:at]]..., column(vals), f.columns[rest[(at + 1):end]]...]
    return _reshaped(f, names, cols, f.nrow)
end
