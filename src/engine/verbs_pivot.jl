# tidyr pivots (phase 2b): pivot_longer and pivot_wider, eager, matching tidyr 1.3.1 where
# checked in R (test/engine/differential_tidyr_pivot_tests.jl). Each verb is a Step.

# A column name given as a Symbol or a string; `nothing` (tidyr's NA) only where allowed.
_colname(x::Union{Symbol, AbstractString}) = Symbol(x)
_colname(x) = throw(ArgumentError("expected a column name (a Symbol or a string), got $(repr(x))"))

# The frame with `names`/`cols`; grouping columns that survive stay grouping columns.
_reshaped(f::Frame, names::Vector{Symbol}, cols::Vector{AbstractColumn}, nrow::Int) =
    Frame(names, cols, Symbol[g for g in f.groups if g in names], nothing, nrow, f.drop)

function _pivot_checkunique(verb, names::Vector{Symbol})
    allunique(names) && return nothing
    dup = unique([n for n in names if count(==(n), names) > 1])
    throw(ArgumentError("$verb: the output would have duplicate column names $(join(repr.(dup), ", ")); rename the input columns or choose other names"))
end

# A column with a nullable declared element type (same values).
_pivot_nullable(c::AbstractColumn) = isnullable(c) || Missing <: eltype(c) ? c : column(Vector{Union{Missing, eltype(c)}}(collect(c)))

# =============================================================================================
# pivot_longer

struct PivotLongerStep <: Step
    cols::Any
    names_to::Vector{Union{Nothing, Symbol}}
    values_to::Symbol
    names_prefix::Union{Nothing, String, Regex}
    names_sep::Union{Nothing, String, Regex}
    names_pattern::Union{Nothing, Regex}
    values_drop_na::Bool
end

"""
    pivot_longer(cols; names_to = :name, values_to = :value, names_prefix = nothing,
                 names_sep = nothing, names_pattern = nothing, values_drop_na = false)

Lengthen a frame (tidyr's `pivot_longer`): the columns chosen by the selector `cols`
(ADR-0002 rule 7; in selection order) become rows. Each input row gives one output row per
pivoted column, in input row order. The other columns come first (in frame order), then the
name columns, then `values_to`.

- `names_to`: one name, or a vector of names with `names_sep` (a string or `Regex` splitting
  each column name) or `names_pattern` (a `Regex` whose capture groups give the parts). A
  `nothing` entry drops that part. Too few parts give `missing`; extra parts are dropped
  (tidyr also warns). The special name `".value"` makes one value column per distinct value of
  that part (then `values_to` is unused); absent combinations are `missing`.
- `names_prefix`: a string removed from the start of each name, or a `Regex` removed where it
  matches (tidyr reads a prefix as a regular expression; here a string is literal).
- `values_drop_na = true` drops rows whose value columns are all `missing`.

Element types come from the declared schema (ADR-0001 rule 1): name columns are strings,
nullable only when some column name has too few parts; the value column holds the lossless
union of the pivoted columns' declared types, as `vcat_columns` builds it. **Divergence:**
tidyr errors on incompatible value types (`<double>` and `<character>`); ChuiFrames keeps both
in one column (ADR-0001 rule 12). Grouping columns that are not pivoted stay grouping columns.
"""
function pivot_longer(cols; names_to = :name, values_to = :value, names_prefix = nothing, names_sep = nothing, names_pattern = nothing, values_drop_na::Bool = false)
    nt = names_to isa AbstractVector ? Union{Nothing, Symbol}[x === nothing ? nothing : _colname(x) for x in names_to] :
        Union{Nothing, Symbol}[_colname(names_to)]
    isempty(nt) && throw(ArgumentError("pivot_longer: names_to must name at least one column"))
    names_sep !== nothing && names_pattern !== nothing && throw(ArgumentError("pivot_longer: give names_sep or names_pattern, not both"))
    if length(nt) > 1 && names_sep === nothing && names_pattern === nothing
        throw(ArgumentError("pivot_longer: names_to has $(length(nt)) names, so give names_sep (a string or Regex) or names_pattern (a Regex with $(length(nt)) groups)"))
    end
    count(==(Symbol(".value")), nt) > 1 && throw(ArgumentError("pivot_longer: \".value\" may appear only once in names_to"))
    sep = names_sep isa AbstractString ? String(names_sep) : names_sep
    pre = names_prefix isa AbstractString ? String(names_prefix) : names_prefix
    sep isa Union{Nothing, String, Regex} || throw(ArgumentError("pivot_longer: names_sep must be a string or a Regex, got $(repr(names_sep))"))
    pre isa Union{Nothing, String, Regex} || throw(ArgumentError("pivot_longer: names_prefix must be a string or a Regex, got $(repr(names_prefix))"))
    names_pattern isa Union{Nothing, Regex} || throw(ArgumentError("pivot_longer: names_pattern must be a Regex, got $(repr(names_pattern))"))
    return PivotLongerStep(cols, nt, _colname(values_to), pre, sep, names_pattern, values_drop_na)
end

function Base.show(io::IO, s::PivotLongerStep)
    nt = [x === nothing ? "nothing" : x === Symbol(".value") ? "\".value\"" : repr(x) for x in s.names_to]
    o = String[]
    nt == [":name"] || push!(o, "names_to = " * (length(nt) == 1 ? nt[1] : "[" * join(nt, ", ") * "]"))
    s.values_to === :value || push!(o, "values_to = $(repr(s.values_to))")
    s.names_prefix === nothing || push!(o, "names_prefix = $(repr(s.names_prefix))")
    s.names_sep === nothing || push!(o, "names_sep = $(repr(s.names_sep))")
    s.names_pattern === nothing || push!(o, "names_pattern = $(repr(s.names_pattern))")
    s.values_drop_na && push!(o, "values_drop_na = true")
    return print(io, "pivot_longer(", _selrepr(s.cols), isempty(o) ? "" : "; " * join(o, ", "), ")")
end

_stripprefix(s::String, ::Nothing) = s
_stripprefix(s::String, p::String) = startswith(s, p) ? s[(ncodeunits(p) + 1):end] : s
function _stripprefix(s::String, p::Regex)
    m = match(p, s)
    m === nothing && return s
    return string(s[1:prevind(s, m.offset)], s[(m.offset + ncodeunits(m.match)):end])
end

# The parts of a column name: a vector of length k, `missing` for absent parts.
function _nameparts(s::String, k::Int, sep, pat)
    if pat !== nothing
        m = match(pat, s)
        m === nothing && return Vector{Union{Missing, String}}(fill(missing, k))
        length(m.captures) == k ||
            throw(ArgumentError("pivot_longer: names_pattern $(repr(pat)) has $(length(m.captures)) groups but names_to has $k names"))
        return Union{Missing, String}[c === nothing ? missing : String(c) for c in m.captures]
    elseif sep !== nothing
        pieces = split(s, sep)
        return Union{Missing, String}[i <= length(pieces) ? String(pieces[i]) : missing for i in 1:k]
    else
        return Union{Missing, String}[s]
    end
end

function _strcolumn(v::Vector{Union{Missing, String}})
    return any(ismissing, v) ? column(v) : column(Vector{String}(v))
end

function apply(s::PivotLongerStep, f::Frame)
    sel = resolve(s.cols, f)
    isempty(sel) && throw(ArgumentError("pivot_longer: $(_selrepr(s.cols)) selects no columns; cols must select at least one"))
    n = f.nrow
    keep = [i for i in eachindex(f.names) if !(i in sel)]
    k = length(s.names_to)
    parts = [_nameparts(_stripprefix(string(f.names[j]), s.names_prefix), k, s.names_sep, s.names_pattern) for j in sel]
    vpos = findfirst(==(Symbol(".value")), s.names_to)
    kpos = [p for p in 1:k if s.names_to[p] !== nothing && p !== vpos]
    names = Symbol[f.names[i] for i in keep]
    cols = AbstractColumn[]
    m = 0
    if vpos === nothing
        m = length(sel)
        rowidx = repeat(1:n; inner = m)
        append!(cols, AbstractColumn[take(f.columns[i], rowidx) for i in keep])
        for p in kpos
            push!(names, s.names_to[p])
            push!(cols, _strcolumn(repeat(Union{Missing, String}[pt[p] for pt in parts]; outer = n)))
        end
        push!(names, s.values_to)
        combined = vcat_columns(AbstractColumn[f.columns[j] for j in sel])
        push!(cols, take(combined, Int[(c - 1) * n + i for i in 1:n for c in 1:m]))
        vcols = [length(cols)]
    else
        # value names and the remaining key, each in first-appearance order
        vname(pt) = ismissing(pt[vpos]) ? "NA" : pt[vpos]
        keyof(pt) = Tuple(pt[p] for p in kpos)
        vnames = unique([vname(pt) for pt in parts])
        ks = unique([keyof(pt) for pt in parts])
        where_ = Dict{Tuple{String, Any}, Int}()
        for (c, pt) in enumerate(parts)
            kk = (vname(pt), keyof(pt))
            haskey(where_, kk) && throw(ArgumentError("pivot_longer: the columns $(f.names[sel[where_[kk]]]) and $(f.names[sel[c]]) give the same \".value\" name and key; names must be unique"))
            where_[kk] = c
        end
        m = length(ks)
        rowidx = repeat(1:n; inner = m)
        append!(cols, AbstractColumn[take(f.columns[i], rowidx) for i in keep])
        for (q, p) in enumerate(kpos)
            push!(names, s.names_to[p])
            push!(cols, _strcolumn(repeat(Union{Missing, String}[key[q] for key in ks]; outer = n)))
        end
        vcols = Int[]
        for v in vnames
            members = [c for c in eachindex(parts) if vname(parts[c]) == v]
            combined = vcat_columns(AbstractColumn[f.columns[sel[c]] for c in members])
            slot = Dict(keyof(parts[c]) => q for (q, c) in enumerate(members))
            idx = Int[]
            for i in 1:n, key in ks
                q = get(slot, key, 0)
                push!(idx, q == 0 ? 0 : (q - 1) * n + i)
            end
            push!(names, Symbol(v))
            push!(cols, take(combined, idx))
            push!(vcols, length(cols))
        end
    end
    _pivot_checkunique("pivot_longer", names)
    out = _reshaped(f, names, cols, n * m)
    if s.values_drop_na
        rows = [r for r in 1:out.nrow if !all(c -> ismissing(out.columns[c][r]), vcols)]
        out = take(out, rows)
    end
    return out
end

# =============================================================================================
# pivot_wider

struct PivotWiderStep <: Step
    names_from::Any
    values_from::Any
    id_cols::Any
    values_fill::Any
    values_fn::Any
    names_sep::String
    names_prefix::String
    names_sort::Bool
end

"""
    pivot_wider(; names_from = :name, values_from = :value, id_cols = nothing,
                values_fill = nothing, values_fn = nothing, names_sep = "_",
                names_prefix = "", names_sort = false)

Widen a frame (tidyr's `pivot_wider`). `names_from` and `values_from` are selectors
(ADR-0002 rule 7). `id_cols` (a selector; by default every other column) identifies the
output rows: one per distinct id combination, in order of first appearance (`missing` is one
id value). One new column per distinct `names_from` combination, in order of first appearance
(or sorted by value with `names_sort = true`, `missing` last), named `names_prefix * name`;
several `names_from` columns are joined by `names_sep`, and `missing` names read `"NA"`. With
several `values_from` columns the names are `{value}{names_sep}{names_prefix}{name}`, all
names of the first value column first.

- A cell with no row is `missing`, or `values_fill` (a scalar, or a `NamedTuple` per value
  column). Existing `missing` values are not filled.
- Two rows for one (id, name) cell need `values_fn` (a function of the cell's values, or a
  `NamedTuple` per value column), else an `ArgumentError`. **Divergence:** tidyr warns and
  builds list-columns; use `values_fn = collect` for that.
- Numeric names use Julia's `string` (`10.0`, where R writes `10`).

Element types (ADR-0001 rule 1): without `values_fn`, a new column's declared type is the
value column's, made nullable unless `values_fill` is given (then the union with the fill's
type). With `values_fn` the element type is **data-dependent** (the results' types). Grouping
columns that are id columns stay grouping columns.
"""
pivot_wider(; names_from = :name, values_from = :value, id_cols = nothing, values_fill = nothing, values_fn = nothing, names_sep::AbstractString = "_", names_prefix::AbstractString = "", names_sort::Bool = false) =
    PivotWiderStep(names_from, values_from, id_cols, values_fill, values_fn, String(names_sep), String(names_prefix), names_sort)

function Base.show(io::IO, s::PivotWiderStep)
    o = String["names_from = $(_selrepr(s.names_from))", "values_from = $(_selrepr(s.values_from))"]
    s.id_cols === nothing || push!(o, "id_cols = $(_selrepr(s.id_cols))")
    s.values_fill === nothing || push!(o, "values_fill = $(repr(s.values_fill))")
    s.values_fn === nothing || push!(o, "values_fn = $(s.values_fn isa Function ? _fname(s.values_fn) : repr(s.values_fn))")
    s.names_sep == "_" || push!(o, "names_sep = $(repr(s.names_sep))")
    isempty(s.names_prefix) || push!(o, "names_prefix = $(repr(s.names_prefix))")
    s.names_sort && push!(o, "names_sort = true")
    return print(io, "pivot_wider(; ", join(o, ", "), ")")
end

# Always a `String`: joining StrViews with Strings hits a StringViews `write` ambiguity on 1.13.
_namestr(x) = ismissing(x) ? "NA" : x isa AbstractString ? String(x) : string(x)

_pervalue(x::NamedTuple, nm::Symbol, what) = haskey(x, nm) ? (true, x[nm]) : (false, nothing)
_pervalue(x::AbstractDict, nm::Symbol, what) =
    haskey(x, nm) ? (true, x[nm]) : haskey(x, string(nm)) ? (true, x[string(nm)]) : (false, nothing)
_pervalue(::Nothing, nm::Symbol, what) = (false, nothing)
_pervalue(x, nm::Symbol, what) = (true, x)

function apply(s::PivotWiderStep, f::Frame)
    ctx = SelectCtx(f)
    nf = resolve(s.names_from, ctx)
    vf = resolve(s.values_from, ctx)
    isempty(nf) && throw(ArgumentError("pivot_wider: names_from = $(_selrepr(s.names_from)) selects no columns"))
    isempty(vf) && throw(ArgumentError("pivot_wider: values_from = $(_selrepr(s.values_from)) selects no columns"))
    ids = s.id_cols === nothing ? [i for i in eachindex(f.names) if !(i in nf) && !(i in vf)] :
        [i for i in resolve(s.id_cols, ctx) if !(i in nf) && !(i in vf)]
    n = f.nrow
    # no id columns: one output row (none for an empty input); `rowcodes` needs a column
    idcodes, idfirst = isempty(ids) ? (ones(Int, n), n == 0 ? Int[] : [1]) : rowcodes(AbstractVector[f.columns[i] for i in ids])
    nmcodes, nmfirst = rowcodes(AbstractVector[f.columns[i] for i in nf])
    nn = length(nmfirst)
    order = collect(1:nn)
    if s.names_sort
        keyvals = [Tuple(f.columns[i][r] for i in nf) for r in nmfirst]
        order = sortperm(keyvals; lt = isless, alg = MergeSort)
    end
    labels = [join([_namestr(f.columns[i][r]) for i in nf], s.names_sep) for r in nmfirst]
    # cells: the rows of each (id, name) pair
    nid = length(idfirst)
    cell = zeros(Int, nid, nn)
    multi = Dict{Tuple{Int, Int}, Vector{Int}}()
    for r in 1:n
        a, b = idcodes[r], nmcodes[r]
        if cell[a, b] == 0
            cell[a, b] = r
        else
            push!(get!(() -> Int[cell[a, b]], multi, (a, b)), r)
        end
    end
    outnames = Symbol[f.names[i] for i in ids]
    outcols = AbstractColumn[take(f.columns[i], idfirst) for i in ids]
    for j in vf
        vname = f.names[j]
        src = f.columns[j]
        hasfn, fn = _pervalue(s.values_fn, vname, "values_fn")
        hasfill, fillv = _pervalue(s.values_fill, vname, "values_fill")
        if !hasfn && !isempty(multi)
            (a, b) = first(keys(multi))
            throw(ArgumentError("pivot_wider: values of $(repr(vname)) are not uniquely identified: $(length(multi)) (id, name) cells hold several rows (e.g. name $(repr(labels[b])), rows $(multi[(a, b)])); pass values_fn (e.g. values_fn = sum, or values_fn = collect for vectors) to combine them"))
        end
        for b in order
            nm = length(vf) == 1 ? s.names_prefix * labels[b] : string(vname) * s.names_sep * s.names_prefix * labels[b]
            push!(outnames, Symbol(nm))
            if hasfn
                vals = Vector{Any}(undef, nid)
                for a in 1:nid
                    r = cell[a, b]
                    vals[a] = r == 0 ? (hasfill ? fillv : missing) : fn(src[get(multi, (a, b), [r])])
                end
                push!(outcols, column(identity.(vals)))
            elseif hasfill
                E = Union{eltype(src), typeof(fillv)}
                vals = Vector{E}(undef, nid)
                for a in 1:nid
                    r = cell[a, b]
                    vals[a] = r == 0 ? fillv : src[r]
                end
                push!(outcols, column(vals))
            else
                push!(outcols, _pivot_nullable(take(src, cell[:, b])))
            end
        end
    end
    _pivot_checkunique("pivot_wider", outnames)
    return _reshaped(f, outnames, outcols, nid)
end
