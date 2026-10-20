# Filter predicates for the lazy optimizer (spec §4; ADR-0004 rules 1, 3, 4; CF-012, CF-013):
# conjunct splitting, totality, `Tables.Scan` translation and statistics pruning. Internal.

# ---------------------------------------------------------------------------------------------
# Node shapes.

const _CMP_OPS = (==, !=, <, <=, >, >=)
_iscmp(f) = any(op -> f === op, _CMP_OPS)

# `lit op col` is `col flip(op) lit` (Base defines `>(x, y) = y < x`, `>=(x, y) = y <= x`).
_flip(f) = f === (<) ? (>) : f === (<=) ? (>=) : f === (>) ? (<) : f === (>=) ? (<=) : f
# The comparison that is `!(x op v)` for every non-NaN, non-`missing` value of a total order.
_negate(f) = f === (==) ? (!=) : f === (!=) ? (==) : f === (<) ? (>=) :
    f === (<=) ? (>) : f === (>) ? (<=) : (<)

_isunary(p::Node, f) = p isa Call && p.f === f && length(p.args) == 1
_isbinary(p::Node, f) = p isa Call && p.f === f && length(p.args) == 2
_unarycol(p::Node, f) = _isunary(p, f) && p.args[1] isa Col

# `(op, column name, literal)` of a dotted column-vs-literal comparison, literal-first order
# normalized by flipping the operator; `nothing` for anything else.
function _cmpparts(p::Node)
    p isa Call && _iscmp(p.f) && length(p.args) == 2 || return nothing
    a, b = p.args
    a isa Col && b isa Lit && return (p.f, a.name, b)
    a isa Lit && b isa Col && return (_flip(p.f), b.name, a)
    return nothing
end

# A literal that may appear in a total comparison: one scalar value of a plain kind.
_scalarlit(l::Lit) = l.scalar && l.value isa Union{Real, AbstractString, Dates.TimeType, ArrowTimestamp}

"""
    conjuncts(p::Node) -> Vector{Node}

Split `p` on `.&` (a `Call` of `&` with two arguments), recursively: `a .& (b .& c)` gives
`[a, b, c]`. Anything else is one conjunct (spec §4).
"""
function conjuncts(p::Node)
    out = Node[]
    _conjuncts!(out, p)
    return out
end
function _conjuncts!(out, p::Node)
    if _isbinary(p, &)
        _conjuncts!(out, p.args[1])
        _conjuncts!(out, p.args[2])
    else
        push!(out, p)
    end
    return out
end

# ---------------------------------------------------------------------------------------------
# Totality (spec §1 R-total, §4).

const _TOTAL_FAMILIES = (Integer, AbstractFloat, AbstractString, Dates.Date, Dates.DateTime, ArrowTimestamp)

# The non-missing element type of column `name` when it is concrete and of a total family.
function _totaltype(name::Symbol, types::AbstractDict)
    haskey(types, name) || return nothing
    T = nonmissingtype(types[name])
    isconcretetype(T) && any(F -> T <: F, _TOTAL_FAMILIES) || return nothing
    return T
end

# A representative value of `T` (one of `_TOTAL_FAMILIES`, concrete); throws when none is known.
_sample(::Type{T}) where {T <: Number} = zero(T)
_sample(::Type{String}) = ""
_sample(::Type{T}) where {T <: AbstractString} = convert(T, "")
_sample(::Type{Dates.Date}) = Dates.Date(2000)
_sample(::Type{Dates.DateTime}) = Dates.DateTime(2000)
_sample(::Type{ArrowTimestamp{U, TZ}}) where {U, TZ} = ArrowTimestamp{U, TZ}(0)

"""
    istotal(p::Node, types::AbstractDict{Symbol,<:Type}) -> Bool

Whether `p` can never throw on any row of columns with these element types (spec §1 R-total,
§4). True only for: a dotted comparison `==, !=, <, <=, >, >=` (either argument order) between
a `Col` whose non-missing element type is concrete and an `Integer` (incl. `Bool`),
`AbstractFloat`, `AbstractString`, `Date`, `DateTime` or `ArrowTimestamp`, and a scalar `Lit`
that compares with a sample value of that type without throwing (checked here, at plan time);
`isnan.(col)` for a float column; `ismissing.(col)` for a concrete-typed column; and `.!p`,
`p .& q`, `p .| q` over total parts. A column missing from `types` is not total.
"""
function istotal(p::Node, types::AbstractDict)
    p isa Call || return false
    if _isunary(p, !)
        return istotal(p.args[1], types)
    elseif _isbinary(p, &) || _isbinary(p, |)
        return istotal(p.args[1], types) && istotal(p.args[2], types)
    elseif _unarycol(p, isnan)
        T = _totaltype(p.args[1].name, types)
        return T !== nothing && T <: AbstractFloat
    elseif _unarycol(p, ismissing)
        a = p.args[1]
        haskey(types, a.name) || return false
        return isconcretetype(nonmissingtype(types[a.name]))
    end
    parts = _cmpparts(p)
    parts === nothing && return false
    _, name, lit = parts
    _scalarlit(lit) || return false
    T = _totaltype(name, types)
    T === nothing && return false
    # The comparison in the node's own argument order, on a sample value of the column type.
    return try
        s = _sample(T)
        r = p.args[1] isa Col ? p.f(s, lit.value) : p.f(lit.value, s)
        r isa Bool
    catch
        false
    end
end

# ---------------------------------------------------------------------------------------------
# `Tables.Scan` translation (ADR-0004 rule 1).

"""
    to_scan(p::Node, types) -> Union{Nothing, Tables.ScanExpr}

The `Tables.Scan` filter equal to `filter(p)` on every value (NaN, -0.0 and `missing`
included; a row is kept only when `p` is exactly `true`), or `nothing`. Only total predicates
(`istotal(p, types)`) translate, and only these node kinds, each covered by a differential test:
the six column-vs-literal comparisons (`Tables.colcmp`), `ismissing.` (`Tables.isnull`), `.!`,
`.&` and `.|`. `isnan.` has no faithful `Scan` form, so a subtree containing it gives `nothing`.
"""
function to_scan(p::Node, types::AbstractDict)
    istotal(p, types) || return nothing
    return _scan(p)
end
function _scan(p::Node)
    if _isunary(p, !)
        a = _scan(p.args[1])
        return a === nothing ? nothing : !a
    elseif _isbinary(p, &) || _isbinary(p, |)
        a = _scan(p.args[1])
        a === nothing && return nothing
        b = _scan(p.args[2])
        b === nothing && return nothing
        return p.f === (&) ? a & b : a | b
    elseif _unarycol(p, ismissing)
        return Tables.isnull(Tables.Col(p.args[1].name))
    end
    parts = _cmpparts(p)
    parts === nothing && return nothing
    op, name, lit = parts
    # `Tables.Col(::Symbol)` is what `Tables.col(::Symbol)` builds (Tables 1.14 scan.jl).
    return Tables.colcmp(op, Tables.Col(name), lit.value)
end

# ---------------------------------------------------------------------------------------------
# Statistics pruning (ADR-0004 rule 4, CF-013).

_field(st, f::Symbol) = hasproperty(st, f) ? getproperty(st, f) : nothing
_known0(st, f::Symbol) = (x = _field(st, f); x isa Integer && x == 0)
# A usable bound: known, not `missing`, not NaN.
_okbound(b) = !(b === nothing || ismissing(b) || (b isa Number && isnan(b)))
_safe(f) = try
    f() === true
catch
    false
end

"""
    may_match(p::Node, stats) -> Bool

`false` only when one partition provably has no row where `p` is `true`, so it can be pruned
(ADR-0004 rule 4, CF-013). `stats(col::Symbol)` gives that partition's
`(; lo, hi, nnull, nnan, ndistinct)` for a column, or `nothing`; `lo`/`hi` are bounds.

Keeps the partition (`true`) whenever statistics, a needed field or a bound is unknown, a bound
is NaN or `missing`, or a comparison throws. A predicate that can be true on NaN (`.!=`, a
negated comparison, `isnan.`) prunes only with `nnan == 0` known; one that can be true on
`missing` (`ismissing.`) only with `nnull == 0` known. `.&` prunes when either side does, `.|`
when both do, and `.!` is pushed inward (De Morgan). Anything unclassified never prunes.

The caller prunes only by total predicates (spec §1 R-total): pruning skips evaluating every
other conjunct on that partition.
"""
function may_match(p::Node, stats)
    return try
        !_prunes(p, stats, false)
    catch
        true
    end
end

# Whether no row makes `p` (when `neg`, `.!p`) exactly `true`, under three-valued logic.
function _prunes(p::Node, stats, neg::Bool)
    if _isunary(p, !)
        return _prunes(p.args[1], stats, !neg)
    elseif _isbinary(p, &)       # !(a & b) == !a | !b
        a, b = p.args
        return neg ? (_prunes(a, stats, true) && _prunes(b, stats, true)) :
            (_prunes(a, stats, false) || _prunes(b, stats, false))
    elseif _isbinary(p, |)       # !(a | b) == !a & !b
        a, b = p.args
        return neg ? (_prunes(a, stats, true) || _prunes(b, stats, true)) :
            (_prunes(a, stats, false) && _prunes(b, stats, false))
    elseif _unarycol(p, ismissing)
        # true exactly on `missing` rows; its negation needs a row count to prune
        neg && return false
        st = _colstats(stats, p.args[1].name)
        return st !== nothing && _known0(st, :nnull)
    elseif _unarycol(p, isnan)
        # true exactly on NaN rows (`missing` on `missing`); its negation never prunes
        neg && return false
        st = _colstats(stats, p.args[1].name)
        return st !== nothing && _known0(st, :nnan)
    end
    parts = _cmpparts(p)
    parts === nothing && return false
    op, name, lit = parts
    return _prunes_cmp(op, name, lit, stats, neg)
end

_colstats(stats, name::Symbol) = try
    stats(name)
catch
    nothing
end

function _prunes_cmp(op, name::Symbol, lit::Lit, stats, neg::Bool)
    _scalarlit(lit) || return false
    v = lit.value
    _okbound(v) || return false          # a NaN literal: keep
    st = _colstats(stats, name)
    st === nothing && return false
    # On `missing` a comparison and its negation are `missing`: never true. On NaN every
    # comparison is false except `!=`, so `!=` and a negated non-`!=` are true there.
    (op === (!=)) ⊻ neg && !_known0(st, :nnan) && return false
    # On the remaining rows (neither NaN nor `missing`) the order is total: negate the operator.
    eop = neg ? _negate(op) : op
    lo, hi = _field(st, :lo), _field(st, :hi)
    return if eop === (>)
        _okbound(hi) && _safe(() -> hi <= v)
    elseif eop === (>=)
        _okbound(hi) && _safe(() -> hi < v)
    elseif eop === (<)
        _okbound(lo) && _safe(() -> lo >= v)
    elseif eop === (<=)
        _okbound(lo) && _safe(() -> lo > v)
    elseif eop === (==)
        (_okbound(lo) && _safe(() -> v < lo)) || (_okbound(hi) && _safe(() -> v > hi))
    else                                   # !=: every value equals v (IEEE: -0.0 == 0.0)
        _okbound(lo) && _okbound(hi) && _safe(() -> lo == v) && _safe(() -> hi == v)
    end
end
