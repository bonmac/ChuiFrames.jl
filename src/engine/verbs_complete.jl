# tidyr missing-value verbs (phase 2b): fill (a method of Base.fill on nodes, CF-009), expand,
# nesting and complete. Behaviour follows tidyr 1.3.1 (checked with `Rscript`, see
# test/engine/differential_tidyr_nest_tests.jl).

# tidyr (vctrs) treats NaN as missing in fill and in complete's fill (`is.na(NaN)` is TRUE).
@inline _tidymissing(x) = ismissing(x) || (x isa AbstractFloat && isnan(x))

# =============================================================================================
# fill

const FILL_DIRECTIONS = (:down, :up, :downup, :updown)

struct FillStep <: Step
    cols::Vector{Symbol}
    direction::Symbol
end

"""
    fill(c.x, c.y...; direction = :down)

tidyr's `fill`: replace missing values with the previous (`:down`), the next (`:up`) value,
or both in either order (`:downup`, `:updown`). Grouped frames fill within groups. It is a
method of `Base.fill` taking column nodes (ADR-0002 rule 4, CF-009): `fill(5, 2)` is still
Base's. Only plain column references (`c.x`, `c[:x]`) are accepted.

As tidyr (vctrs), NaN counts as missing: it is replaced, and never used as a fill value. A run
of missing values takes the value just before it, so a run at the start keeps its first value
(`NaN, missing, 2` filled down is `NaN, NaN, 2`). This differs from the rest of ChuiFrames,
where NaN is a value (ADR-0002 rule 12); it is kept for parity with tidyr. To leave NaN alone,
turn it into a sentinel first. The column keeps its declared element type (ADR-0001 rule 1).
"""
Base.fill(x::Node; direction = :down) = _fillstep((x,), direction)
Base.fill(x::Node, y::Node, ys::Node...; direction = :down) = _fillstep((x, y, ys...), direction)

function _fillstep(xs::Tuple, direction)
    cols = Symbol[]
    for x in xs
        x isa Col || throw(ArgumentError("fill: expected plain column references such as c.x, got $(x); fill takes columns, not expressions"))
        push!(cols, x.name)
    end
    d = Symbol(direction)
    d in FILL_DIRECTIONS || throw(ArgumentError("fill: direction must be one of $(join(repr.(FILL_DIRECTIONS), ", ")), got $(repr(direction))"))
    return FillStep(cols, d)
end
Base.show(io::IO, s::FillStep) =
    print(io, "fill(", join([repr(Col(n)) for n in s.cols], ", "), s.direction === :down ? "" : "; direction = $(repr(s.direction))", ")")

function apply(s::FillStep, f::Frame)
    rowsets = _rowsets(f)
    cols = copy(f.columns)
    passes = s.direction === :down ? (:down,) : s.direction === :up ? (:up,) :
        s.direction === :downup ? (:down, :up) : (:up, :down)
    for nm in s.cols
        i = get(f.lookup, nm, 0)
        i == 0 && throw(ArgumentError("fill: no column $(repr(nm)); columns are $(join(repr.(f.names), ", "))"))
        nm in f.groups && throw(ArgumentError("fill: cannot fill the grouping column $(repr(nm)); ungroup() first"))
        col = cols[i]
        idx = collect(1:f.nrow)
        for rows in rowsets, p in passes
            order = p === :down ? rows : reverse(rows)
            for k in 2:length(order)
                r = order[k]
                _tidymissing(col[idx[r]]) && (idx[r] = idx[order[k - 1]])
            end
        end
        cols[i] = take(col, idx)
    end
    return Frame(copy(f.names), cols, copy(f.groups), f.gindex, f.nrow)
end

# =============================================================================================
# expand / nesting

"`nesting(cols...)`: inside `expand`/`complete`, only the combinations of `cols` present in the data."
struct Nesting
    cols::Vector{Any}
end
nesting(cols...) = Nesting(Any[cols...])
Base.show(io::IO, n::Nesting) = print(io, "nesting(", join(_selrepr.(n.cols), ", "), ")")

_factorrepr(x::Nesting) = repr(x)
_factorrepr(x) = _selrepr(x)

struct ExpandStep <: Step
    factors::Vector{Any}
end

"""
    expand(cols...)

Every combination of the distinct values of each argument: a column (name, `c.x`, or a
selector, each selected column a factor of its own) or `nesting(cols...)` (only the combinations
present in the data). Values are sorted ascending with `missing` and NaN last, in first-seen
order between themselves (tidyr / vctrs); `-0.0` and `0.0` are one value. The grid varies the
FIRST argument slowest (not `Iterators.product` order). Grouped frames expand per group, groups
first and in group order; the result keeps the grouping. `expand()` is one row with no columns
(per group). A column named twice is an `ArgumentError` (tidyr repairs the names to `a...1`).
"""
expand(factors...) = ExpandStep(Any[factors...])
Base.show(io::IO, s::ExpandStep) = print(io, "expand(", join(_factorrepr.(s.factors), ", "), ")")

function _factors(f::Frame, args::Vector{Any}, verb)
    out = Vector{Vector{Symbol}}()
    for a in args
        if a isa Nesting
            push!(out, Symbol[f.names[i] for i in resolve(a.cols, f)])
        else
            for i in resolve(a, f)
                push!(out, [f.names[i]])
            end
        end
    end
    all = Symbol[n for fac in out for n in fac]
    for (k, n) in enumerate(all)
        n in f.groups && throw(ArgumentError("$verb: cannot expand the grouping column $(repr(n)); it is expanded per group already"))
        n in view(all, 1:(k - 1)) && throw(ArgumentError("$verb: column $(repr(n)) is used more than once"))
    end
    return out
end

# Ascending order with missing/NaN last as one tie class, -0.0 == 0.0, stable.
function _tidyorder(vals::Vector, n::Int)
    function lt(i, j)
        for v in vals
            a, b = v[i], v[j]
            ta, tb = _tidymissing(a), _tidymissing(b)
            ta && tb && continue
            ta && return false
            tb && return true
            ka, kb = _canon(a), _canon(b)
            isless(ka, kb) && return true
            isless(kb, ka) && return false
        end
        return false
    end
    return try
        sort!(collect(1:n); lt = lt, alg = MergeSort)
    catch err
        err isa MethodError || rethrow()
        collect(1:n)   # values without `isless`: first-seen order
    end
end

# Rows of `f` holding the distinct combinations of `cols` among `rows`, sorted.
function _factor_rows(cols::Vector{AbstractColumn}, rows::Vector{Int})
    sub = AbstractVector[view(c, rows) for c in cols]
    _, firstrows = rowcodes(sub)
    vals = [[v[i] for i in firstrows] for v in sub]
    return rows[firstrows[_tidyorder(vals, length(firstrows))]]
end

# The grid of several factors (row indices per factor), first factor slowest.
function _grid(fr::Vector{Vector{Int}})
    sizes = length.(fr)
    total = prod(sizes; init = 1)
    out = [Vector{Int}(undef, total) for _ in fr]
    for r in 0:(total - 1)
        q = r
        for j in length(fr):-1:1
            out[j][r + 1] = fr[j][q % sizes[j] + 1]
            q = q ÷ sizes[j]
        end
    end
    return out, total
end

function apply(s::ExpandStep, f::Frame)
    facs = _factors(f, s.factors, "expand")
    gi = gindex(f)
    groupsets = gi === nothing ? [collect(1:f.nrow)] : [collect(group_rows(gi, g)) for g in 1:ngroups(gi)]
    keyrows = Int[]
    facidx = [Int[] for _ in facs]
    for rows in groupsets
        fr = [_factor_rows(AbstractColumn[getcol(f, n) for n in fac], rows) for fac in facs]
        g, total = _grid(fr)
        append!(keyrows, Base.fill(isempty(rows) ? 0 : rows[1], total))
        for j in eachindex(facs)
            append!(facidx[j], g[j])
        end
    end
    names = copy(f.groups)
    cols = AbstractColumn[take(getcol(f, k), keyrows) for k in f.groups]
    for (j, fac) in enumerate(facs), n in fac
        push!(names, n)
        push!(cols, take(getcol(f, n), facidx[j]))
    end
    return Frame(names, cols, copy(f.groups), nothing, length(keyrows))
end

# =============================================================================================
# complete

struct CompleteStep <: Step
    factors::Vector{Any}
    fill::Vector{Pair{Symbol, Any}}
    explicit::Bool
end

_fillspec(x::NamedTuple) = Pair{Symbol, Any}[k => v for (k, v) in pairs(x)]
_fillspec(x::AbstractDict) = Pair{Symbol, Any}[Symbol(k) => v for (k, v) in x]
_fillspec(x::Union{Tuple, AbstractVector}) = Pair{Symbol, Any}[Symbol(p.first) => p.second for p in x]
_fillspec(x) = throw(ArgumentError("complete: fill must be a NamedTuple such as (n = 0,), got $(repr(x))"))

"""
    complete(cols...; fill = NamedTuple(), explicit = true)

`expand(cols...)`, then the data joined back: every row of the grid, with the data rows that
match it (all of them, in data order; key equality is ADR-0003 rule 8's, `missing` is a key).
Grid rows absent from the data get `missing` in the other columns. Columns: the grouping
columns, the expanded columns, then the other columns in their order. Rows follow the grid.

`fill = (n = 0,)` replaces missing values of the named columns: in the new rows, and in the
existing rows too when `explicit = true` (tidyr's `replace_na`, which also replaces NaN). A
fill value that does not convert losslessly to the column's type is an `ArgumentError` (tidyr:
"can't convert"). A column whose element type is only `Missing` declares no value type, so a
fill gives it the fill value's type (`fill = (m = 0,)` makes it `Int64`); tidyr keeps such a
column logical, and fills it with `FALSE`. `complete()` with no columns only applies `fill`. Grouped frames complete
per group and keep the grouping. The non-key columns are declared nullable (rows may be new),
except a column whose every missing value `fill` replaced.
"""
complete(factors...; fill = NamedTuple(), explicit::Bool = true) = CompleteStep(Any[factors...], _fillspec(fill), explicit)
function Base.show(io::IO, s::CompleteStep)
    opts = String[]
    isempty(s.fill) || push!(opts, "fill = (" * join(["$k = $(repr(v))" for (k, v) in s.fill], ", ") * (length(s.fill) == 1 ? ",)" : ")"))
    s.explicit || push!(opts, "explicit = false")
    return print(io, "complete(", join(_factorrepr.(s.factors), ", "), isempty(opts) ? "" : "; " * join(opts, ", "), ")")
end

# The column made nullable (its declared type admits missing), values unchanged.
function _complete_nullable(c::AbstractColumn)
    n = length(c)
    return take(take(c, [collect(1:n); 0]), collect(1:n))
end

# `col` with its missing (and NaN) values replaced by `v` where `ok(row)` is true.
function _replace_missing(col::AbstractColumn, v, ok, nm::Symbol, decl_nullable::Bool)
    S = nonmissingtype(eltype(col))
    if S !== Any && isconcretetype(S) && !(v isa S) && !(S <: AbstractString && v isa AbstractString)
        y = try
            convert(S, v)
        catch
            nothing
        end
        (y === nothing || !isequal(y, v)) &&
            throw(ArgumentError("complete: the fill value $(repr(v)) for column $(repr(nm)) can't be converted to its element type $S"))
        v = y
    end
    vals = Any[x for x in col]
    for i in eachindex(vals)
        _tidymissing(vals[i]) && ok(i) && (vals[i] = v)
    end
    return typed_column(vals, decl_nullable ? Union{Missing, S} : S)
end

function apply(s::CompleteStep, f::Frame)
    for (k, _) in s.fill
        hascolumn(f, k) || throw(ArgumentError("complete: fill names no column $(repr(k)); columns are $(join(repr.(f.names), ", "))"))
    end
    if isempty(s.factors)
        s.explicit || return f
        cols = copy(f.columns)
        for (k, v) in s.fill
            i = f.lookup[k]
            cols[i] = _replace_missing(cols[i], v, _ -> true, k, false)
        end
        return Frame(copy(f.names), cols, copy(f.groups), f.gindex, f.nrow)
    end
    grid = apply(ExpandStep(s.factors), f)
    keys = grid.names
    ng = grid.nrow
    codes, _ = rowcodes(AbstractVector[vcat(getcol(grid, k), getcol(f, k)) for k in keys])
    bykey = Dict{Int, Vector{Int}}()
    for r in 1:f.nrow
        push!(get!(Vector{Int}, bykey, codes[ng + r]), r)
    end
    gidx = Int[]
    didx = Int[]
    matched = falses(f.nrow)
    for g in 1:ng
        rs = get(bykey, codes[g], nothing)
        if rs === nothing
            push!(gidx, g)
            push!(didx, 0)
        else
            for r in rs
                push!(gidx, g)
                push!(didx, r)
                matched[r] = true
            end
        end
    end
    # Data rows outside the grid (none when the grid comes from the data), appended as
    # tidyr's full join does.
    for r in 1:f.nrow
        matched[r] || (push!(gidx, 0); push!(didx, r))
    end
    extra = any(iszero, gidx)
    names = copy(keys)
    cols = AbstractColumn[
        extra ? vcat_columns(AbstractColumn[take(getcol(grid, k), gidx[gidx .!= 0]), take(getcol(f, k), didx[gidx .== 0])]) :
            take(getcol(grid, k), gidx) for k in keys
    ]
    for (i, n) in enumerate(f.names)
        n in keys && continue
        push!(names, n)
        push!(cols, _complete_nullable(take(f.columns[i], didx)))
    end
    for (k, v) in s.fill
        i = findfirst(==(k), names)
        orig_nullable = Missing <: eltype(getcol(f, k))
        ok = s.explicit ? (_ -> true) : (r -> didx[r] == 0)
        cols[i] = _replace_missing(cols[i], v, ok, k, s.explicit ? false : (orig_nullable && !(k in keys)))
    end
    return Frame(names, cols, copy(f.groups), nothing, length(gidx))
end
