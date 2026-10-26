# The join verbs (phase-4 spec docs/superpowers/specs/2026-10-26-phase4-joins-groupby-codegen-design.md
# §1.1, §1.5; dplyr 1.2.0 semantics; ADR-0002 rule 16 as amended 2026-10-26: `by`). Join lane.

# ---------------------------------------------------------------------------------------------
# Keys: `by` forms and join_by

"""
    JoinBy

Equality key pairs from [`join_by`](@ref), usable as `by = join_by(...)`.
"""
struct JoinBy
    pairs::Vector{Pair{Symbol, Symbol}}
end

"""
    join_by(keys...)

Join keys as equality pairs (spec §1.5): `join_by(:a => :b, :c)` joins x's `a` with y's `b` and
x's `c` with y's `c`. Accepts `:a`, `"a"`, `:a => :b`, `"a" => "b"` and vectors of those (the
same forms as `by`). `by = join_by(:a => :b)` is the same join as `by = :a => :b`.

Only equality pairs exist. dplyr's `join_by(a == b)` form is not shipped, because plain `==`
on `c.a` returns a `Bool`; inequality and rolling keys (`join_by(a >= b)`, `closest`,
`between`, `within`, `overlaps`) are deferred: no design exists yet. A column expression passed
to `join_by` is an `ArgumentError`.
"""
join_by(keys...) = JoinBy(_keypairs(collect(Any, keys), "join_by"))

function Base.show(io::IO, j::JoinBy)
    parts = [p.first === p.second ? repr(p.first) : "$(repr(p.first)) => $(repr(p.second))" for p in j.pairs]
    return print(io, "join_by(", join(parts, ", "), ")")
end

_keypair(k::Union{Symbol, AbstractString}, ::String) = Symbol(k) => Symbol(k)
_keypair(k::Pair{<:Union{Symbol, AbstractString}, <:Union{Symbol, AbstractString}}, ::String) = Symbol(k.first) => Symbol(k.second)
_keypair(k::Node, verb::String) = throw(ArgumentError("$verb: a column expression ($(k)) is not a key; write equality pairs as :a => :b (x's a equals y's b). Inequality and rolling join keys are not available."))
_keypair(k, verb::String) = throw(ArgumentError("$verb: a key must be a column name or a pair :a => :b, got $(repr(k))"))

function _keypairs(keys::Vector{Any}, verb::String)
    out = Pair{Symbol, Symbol}[]
    for k in keys
        if k isa JoinBy
            append!(out, k.pairs)
        elseif k isa AbstractVector
            append!(out, _keypairs(collect(Any, k), verb))
        else
            push!(out, _keypair(k, verb))
        end
    end
    return out
end

function _parse_by(by, verb::String)
    by === nothing && return nothing
    pairs = by isa Union{AbstractVector, JoinBy} ? _keypairs(Any[by], verb) : Pair{Symbol, Symbol}[_keypair(by, verb)]
    isempty(pairs) && throw(ArgumentError("$verb: `by` names no key; give at least one key (use cross_join for a join with no keys)"))
    return pairs
end

# ---------------------------------------------------------------------------------------------
# The verbs

_suffix(s) = (s isa Tuple{Any, Any} || (s isa AbstractVector && length(s) == 2)) ? (String(s[1]), String(s[2])) :
    throw(ArgumentError("suffix must be two strings, e.g. (\"_x\", \"_y\"), got $(repr(s))"))

function _checkopt(verb::String, name::Symbol, v::Symbol, allowed::Tuple)
    v in allowed || throw(ArgumentError("$verb: $name must be one of $(join(repr.(allowed), ", ")), got $(repr(v))"))
    return v
end

_joiny(y::Frame) = y
_joiny(y) = (y isa LazyFrame || y isa Source) ? y : Frame(y)

function _joinstep(kind::Symbol, y, by; suffix = ("_x", "_y"), na_matches::Symbol = :na, keep::Bool = false, multiple::Symbol = :all, unmatched::Symbol = :drop, name = :y)
    verb = string(kind, "_join")
    _checkopt(verb, :na_matches, na_matches, (:na, :never))
    _checkopt(verb, :multiple, multiple, (:all, :any, :first, :last, :error))
    _checkopt(verb, :unmatched, unmatched, (:drop, :error))
    nm = Symbol(name)
    _ishidden(nm) && throw(ArgumentError("$verb: the column name $(repr(nm)) starts with the reserved prefix $(_HIDDEN_PREFIX)"))
    return JoinStep(kind, _joiny(y), _parse_by(by, verb), _suffix(suffix), na_matches, keep, multiple, unmatched, nm)
end

const _JOIN_KEYS_DOC = """
`by` names the keys: `nothing` (the default: a natural join on the columns both tables have,
logged as `@info "Joining with by = [...]"`), `:a`, `"a"`, `[:a, :b]`, `:a => :b` (x's `a`
equals y's `b`), a vector of those, or [`join_by`](@ref)`(...)`.

Key equality is ADR-0003 rule 8: NaN is one key, `-0.0` and `0.0` are one key, `missing` is its
own key. `na_matches = :never` makes a key holding `missing` or NaN match nothing. Key types:
identical types, two string types, and numeric pairs that `promote_type` keeps exactly are
compared after that promotion; an integer (or `Bool`) key with a float key is compared as
`Float64` (dplyr compares integer and double keys as double). **Integers above 2^53 in
magnitude do not all survive that conversion**: `Int64` keys `2^53` and `2^53 + 1` both match a
`Float64` key `2.0^53`, and the output key shows `9.007199254740992e15` for both; convert the
key first when that matters. `Date`/`DateTime`, `Int64`/`UInt64`, string/number and other pairs
are an `ArgumentError`.

Output (dplyr): x's columns in order, then y's non-key columns. With `keep = false` the keys
appear once, with x's names and the compare type (a row only in y takes y's key). With
`keep = true` both sides' keys are kept unconverted, and both get the suffix when they clash.
Other clashing names get `suffix`; the default `("_x", "_y")` differs from dplyr's
`(".x", ".y")`. Element types are fixed by the kind of join, never by the data: a left join
makes y's columns nullable, a right join x's, a full join both. A grouped x keeps its grouping;
a grouped y is ungrouped first.

Rows (dplyr): x's order, each x row's matches in y's order; right and full joins then append
y's unmatched rows in y's order.
"""

"""
    inner_join(y; by = nothing, suffix = ("_x", "_y"), na_matches = :na, keep = false,
               multiple = :all, unmatched = :drop)

The rows of x with a match in `y`, each paired with its matching rows of `y` (dplyr
`inner_join`). `y` is any Tables.jl table, a `LazyFrame` or a `Source`.

$_JOIN_KEYS_DOC

`multiple` (`:all`, `:any`, `:first`, `:last`, `:error`) chooses among an x row's matches;
`:any` is `:first`. A y row matched but not chosen counts as unmatched. `unmatched = :error`
raises when a row of x or of y would be dropped. Errors follow one order: one ascending pass
over x (no match, then more than one match under `multiple = :error`), then y.
"""
inner_join(y; by = nothing, suffix = ("_x", "_y"), na_matches::Symbol = :na, keep::Bool = false, multiple::Symbol = :all, unmatched::Symbol = :drop) =
    _joinstep(:inner, y, by; suffix, na_matches, keep, multiple, unmatched)

"""
    left_join(y; by = nothing, suffix = ("_x", "_y"), na_matches = :na, keep = false,
              multiple = :all, unmatched = :drop)

Every row of x, paired with its matching rows of `y` (`missing` where none; dplyr `left_join`).
`unmatched = :error` raises when a row of `y` matches nothing. See [`inner_join`](@ref) for
keys, names, types and `multiple`.
"""
left_join(y; by = nothing, suffix = ("_x", "_y"), na_matches::Symbol = :na, keep::Bool = false, multiple::Symbol = :all, unmatched::Symbol = :drop) =
    _joinstep(:left, y, by; suffix, na_matches, keep, multiple, unmatched)

"""
    right_join(y; by = nothing, suffix = ("_x", "_y"), na_matches = :na, keep = false,
               multiple = :all, unmatched = :drop)

The matched rows in x order, then the rows of `y` with no match, in y order, with x's columns
`missing` and keys from `y` (dplyr `right_join`). `unmatched = :error` raises when a row of x
matches nothing. See [`inner_join`](@ref).
"""
right_join(y; by = nothing, suffix = ("_x", "_y"), na_matches::Symbol = :na, keep::Bool = false, multiple::Symbol = :all, unmatched::Symbol = :drop) =
    _joinstep(:right, y, by; suffix, na_matches, keep, multiple, unmatched)

"""
    full_join(y; by = nothing, suffix = ("_x", "_y"), na_matches = :na, keep = false,
              multiple = :all)

The left join's rows, then the rows of `y` with no match (dplyr `full_join`; no `unmatched`).
See [`inner_join`](@ref).
"""
full_join(y; by = nothing, suffix = ("_x", "_y"), na_matches::Symbol = :na, keep::Bool = false, multiple::Symbol = :all) =
    _joinstep(:full, y, by; suffix, na_matches, keep, multiple)

"""
    semi_join(y; by = nothing, na_matches = :na)

The rows of x with a match in `y`, each once, in x order, with x's columns only (unconverted;
dplyr `semi_join`). See [`inner_join`](@ref) for the keys.
"""
semi_join(y; by = nothing, na_matches::Symbol = :na) = _joinstep(:semi, y, by; na_matches)

"""
    anti_join(y; by = nothing, na_matches = :na)

The rows of x with no match in `y`, in x order, with x's columns only (dplyr `anti_join`).
See [`inner_join`](@ref) for the keys.
"""
anti_join(y; by = nothing, na_matches::Symbol = :na) = _joinstep(:anti, y, by; na_matches)

"""
    nest_join(y; by = nothing, keep = false, name = :y, na_matches = :na, unmatched = :drop)

Every row of x once, in x order, plus one column `name` holding, for each x row, a `Frame` of
its matching rows of `y` in y order (dplyr `nest_join`; the column is an object column of
`Frame`s, as `nest` builds, so `unnest(name)` expands it). A nested frame holds y's non-key
columns (`keep = false`, the default) or all of y's columns (`keep = true`), with y's types and
no suffix; an x row with no match gets a 0-row frame with the same columns.

- The default `name` is `:y` (dplyr uses the name of the `y` argument).
- A `name` equal to a column of x replaces that column at its position, as dplyr does, and a
  `@warn` names it (logged once, when the join's names are resolved).
- `unmatched = :error` raises when a row of `y` matches nothing (under `na_matches = :never`
  a y row with a `missing` or NaN key is unmatched). No `multiple`, no `suffix`.

See [`inner_join`](@ref) for the keys; the key column under `keep = false` has the compare type.
"""
nest_join(y; by = nothing, keep::Bool = false, name = :y, na_matches::Symbol = :na, unmatched::Symbol = :drop) =
    _joinstep(:nest, y, by; keep, name, na_matches, unmatched)

"""
    cross_join(y; suffix = ("_x", "_y"))

Every row of x paired with every row of `y` (dplyr `cross_join`): `nrow(x) * nrow(y)` rows, in x
order, each x row's block in y order; x's columns, then y's, clashing names suffixed. A grouped
x keeps its grouping.
"""
cross_join(y; suffix = ("_x", "_y")) = JoinStep(:cross, _joiny(y), nothing, _suffix(suffix), :na, false, :all, :drop, :y)

function Base.show(io::IO, s::JoinStep)
    opts = String[]
    s.kind === :cross || push!(opts, "by = " * (s.by === nothing ? "nothing" : repr(JoinBy(s.by))))
    s.suffix == ("_x", "_y") || s.kind in (:semi, :anti, :nest) || push!(opts, "suffix = $(repr(s.suffix))")
    s.na_matches === :na || push!(opts, "na_matches = :never")
    s.keep && push!(opts, "keep = true")
    s.multiple === :all || push!(opts, "multiple = $(repr(s.multiple))")
    s.unmatched === :drop || push!(opts, "unmatched = :error")
    s.kind === :nest && push!(opts, "name = $(repr(s.name))")
    return print(io, s.kind, "_join(…; ", join(opts, ", "), ")")
end

# ---------------------------------------------------------------------------------------------
# Name resolution (spec §1.1, §1.4, §1.6): keys, output names, suffixes

# dplyr 1.2.0's add_suffixes (read with Rscript, 2026-10-26): put `against` first, then
# append `suffix` to every later duplicate until none is left; return the part for `names`.
function _add_suffixes(names::Vector{Symbol}, against::Vector{Symbol}, suffix::String)
    isempty(suffix) && return copy(names)
    z = String[String(n) for n in [against; names]]
    while true
        seen = Set{String}()
        dup = falses(length(z))
        for (i, s) in enumerate(z)
            s in seen ? (dup[i] = true) : push!(seen, s)
        end
        any(dup) || break
        z[dup] .= z[dup] .* suffix
    end
    return Symbol[Symbol(s) for s in z[(length(against) + 1):end]]
end

function _check_reserved(names::Vector{Symbol}, side::String)
    for n in names
        _ishidden(n) && throw(ArgumentError("join: $side's column $(repr(n)) starts with the reserved prefix $(_HIDDEN_PREFIX); rename it first"))
    end
    return nothing
end

"""
    _resolve_names(s::JoinStep, xnames, ynames; log = true) -> JoinNames

The keys and output names of join `s` on tables with these column names (spec §1.1, §1.6;
dplyr 1.2.0's naming). Raises an `ArgumentError` for a missing or repeated key, for no common
column under `by = nothing`, and for names with the reserved prefix `##chui_`. With `log`, a
natural join logs `@info "Joining with by = [...]"` and a `nest_join` whose `name` replaces an
x column logs a `@warn`: once, when the names are resolved (never again in replay).
"""
function _resolve_names(s::JoinStep, xnames::Vector{Symbol}, ynames::Vector{Symbol}; log::Bool = true)
    verb = string(s.kind, "_join")
    _check_reserved(xnames, "x")
    _check_reserved(ynames, "y")
    natural = false
    pairs = if s.kind === :cross
        Pair{Symbol, Symbol}[]
    elseif s.by === nothing
        common = Symbol[n for n in xnames if n in ynames]
        isempty(common) && throw(ArgumentError("$verb: `by = nothing` and x and y have no column in common; give the keys with `by`"))
        natural = true
        log && @info "Joining with by = $(repr(common))"
        Pair{Symbol, Symbol}[n => n for n in common]
    else
        s.by
    end
    for p in pairs
        p.first in xnames || throw(ArgumentError("$verb: the key `$(p.first)` is not a column of x; x has $(join(repr.(xnames), ", "))"))
        p.second in ynames || throw(ArgumentError("$verb: the key `$(p.second)` is not a column of y; y has $(join(repr.(ynames), ", "))"))
    end
    xkeys = Symbol[p.first for p in pairs]
    ykeys = Symbol[p.second for p in pairs]
    allunique(xkeys) || throw(ArgumentError("$verb: x's key columns must be unique, got $(xkeys)"))
    allunique(ykeys) || throw(ArgumentError("$verb: y's key columns must be unique, got $(ykeys)"))
    outn = Symbol[]
    side = Symbol[]
    src = Symbol[]
    sx, sy = s.suffix
    if s.kind === :semi || s.kind === :anti
        append!(outn, xnames)
        append!(side, fill(:x, length(xnames)))
        append!(src, xnames)
    elseif s.kind === :nest
        for n in xnames
            push!(outn, n)
            push!(side, (!s.keep && n in xkeys) ? :key : :x)
            push!(src, n)
        end
        j = findfirst(==(s.name), outn)
        if j === nothing
            push!(outn, s.name)
            push!(side, :nest)
            push!(src, s.name)
        else
            log && @warn "nest_join: the nested column $(repr(s.name)) replaces x's column $(repr(s.name))"
            side[j] = :nest
            src[j] = s.name
        end
    else
        # dplyr 1.2.0's join_cols (read with Rscript, 2026-10-26)
        if !s.keep
            yaux = Symbol[n for n in ynames if !(n in xkeys) && !(n in ykeys)]
            xo = copy(xnames)
            isaux = [!(n in xkeys) for n in xnames]
            xo[isaux] = _add_suffixes(xnames[isaux], [xkeys; yaux], sx)
            keepy = [!(n in ykeys) for n in ynames]
        else
            xo = _add_suffixes(xnames, ynames, sx)
            keepy = fill(true, length(ynames))
        end
        yo = _add_suffixes(ynames, xnames, sy)
        for (n, o) in zip(xnames, xo)
            push!(outn, o)
            push!(side, (s.kind !== :cross && !s.keep && n in xkeys) ? :key : :x)
            push!(src, n)
        end
        for (n, o, k) in zip(ynames, yo, keepy)
            k || continue
            push!(outn, o)
            push!(side, :y)
            push!(src, n)
        end
    end
    allunique(outn) || throw(ArgumentError("$verb: the output would have duplicate column names $(unique(n for n in outn if count(==(n), outn) > 1)); rename a column or change `suffix`"))
    xclash = Symbol[src[j] for j in eachindex(outn) if side[j] === :x && outn[j] !== src[j]]
    yclash = Symbol[src[j] for j in eachindex(outn) if side[j] === :y && outn[j] !== src[j]]
    return JoinNames(pairs, natural, copy(xnames), copy(ynames), outn, side, src, xclash, yclash, nothing)
end

# ---------------------------------------------------------------------------------------------
# Eager apply

"y as an ungrouped frame: a lazy y (a `LazyFrame` or a `Source`) is collected first."
function _yframe(s::JoinStep)
    y = s.y
    f = y isa Frame ? y : collect(lazy(y))
    return _ungrouped(f)
end

function apply(s::JoinStep, x::Frame)
    y = _yframe(s)
    names = _resolve_names(s, x.names, y.names; log = true)
    return _join_frames(s, names, x, y)
end

# ---------------------------------------------------------------------------------------------
# DataAPI's join methods (ADR-0007): DataAPI's keyword `on` is forwarded to the verb's `by`; every
# other keyword is passed through unchanged (so a DataFrames-only keyword raises the verb's error).

DataAPI.innerjoin(x::Frame, y; on = nothing, kw...) = inner_join(y; by = on, kw...)(x)
DataAPI.leftjoin(x::Frame, y; on = nothing, kw...) = left_join(y; by = on, kw...)(x)
DataAPI.rightjoin(x::Frame, y; on = nothing, kw...) = right_join(y; by = on, kw...)(x)
DataAPI.outerjoin(x::Frame, y; on = nothing, kw...) = full_join(y; by = on, kw...)(x)
DataAPI.semijoin(x::Frame, y; on = nothing, kw...) = semi_join(y; by = on, kw...)(x)
DataAPI.antijoin(x::Frame, y; on = nothing, kw...) = anti_join(y; by = on, kw...)(x)
DataAPI.crossjoin(x::Frame, y; kw...) = cross_join(y; kw...)(x)

export inner_join, left_join, right_join, full_join, semi_join, anti_join, nest_join, cross_join, join_by
