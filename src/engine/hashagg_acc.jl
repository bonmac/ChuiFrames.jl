# The hash-aggregate sink's simple-aggregate recogniser and typed per-group accumulators
# (phase-4 spec §2.1, §2.3; critic M5, N4). Group-by lane. Split out of hashagg.jl (review B1:
# the 600-line ratchet); the key machinery stays there, the operator is in hashagg_sink.jl.

# ---------------------------------------------------------------------------------------------
# Simple aggregates (phase-4 spec §2.1): what the lazy hash-aggregate sink can fold row by row

"The `n_rows()` reduction as an aggregator of the hash-aggregate sink (it reads no column)."
struct _NRowsAgg end

"""
    _simple_aggregate(x) -> (agg, column) or String

A summary output the hash-aggregate sink can compute (phase-4 spec §2.1): `n_rows()` (gives
`(_NRowsAgg(), nothing)`), or one `Reduce` over a `Col` or `skipmissing(Col)` whose aggregator
is not `Holistic` or `NDistinct` (gives `(_aggregator(x), name)`). Otherwise the reason it is
not simple, for `explain`, e.g. ``"not a simple aggregate: `median`"``.
"""
function _simple_aggregate(x)
    x isa NRows && return (_NRowsAgg(), nothing)
    x isa Reduce || return "not a simple aggregate: `$(x)`"
    agg = _aggregator(x)
    inner = agg isa SkipMissingAgg ? agg.inner : agg
    (inner isa Holistic || inner isa NDistinct) && return "not a simple aggregate: `$(x.fname)`"
    arg = x.arg isa SkipMiss ? x.arg.inner : x.arg
    arg isa Col || return "not a simple aggregate: `$(x)` (a reduction over an expression, not a column)"
    return (agg, arg.name)
end

# ---------------------------------------------------------------------------------------------
# Typed per-group accumulators (phase-4 spec §2.3, critic M5 and N4)
#
# One accumulator per summary output and per run (a task's table between two radix flushes).
# Each holds concretely typed vectors indexed by the run's group ids, and folds rows with the
# same Base calls as the aggregator protocol applied to one-row chunks (`sum((x,))` is Base's
# widened first value), so integer, `Bool`, string, `first`/`last` and `minimum`/`maximum` results
# equal the protocol's exactly, and float sums agree within CC-004's tolerance (they associate per
# morsel). Only `MapM` and `ReduceM` (whose result type needs `promote_op`, ADR-0002 rule 11)
# keep `Vector{Any}` states, through the protocol itself (`_ProtoAcc`).
#
# The state type comes from the input element type `T` and a sample value (`zero(S)` of the
# non-missing type `S`), never from `promote_op`. A morsel whose column has another element type
# widens the accumulator (`_widen`, states kept); types with no common concrete type give `Any`.

abstract type _Acc end

# A sample value of a concrete number type, or nothing (a number type without `zero`).
function _sample(S::Type)
    (S !== Union{} && isconcretetype(S) && S <: Number) || return nothing
    return try
        zero(S)
    catch err
        err isa InterruptException && rethrow()
        nothing
    end
end

# The state type of `f(x)` for inputs of type `T` (nullable when `T` is), or Any.
function _statetype(f, T::Type)
    S = nonmissingtype(T)
    z = _sample(S)
    z === nothing && return Any
    A = typeof(f(z))
    return S === T ? A : Union{Missing, A}
end

# The stored type of values of type `T`: a string view (into a morsel's buffer) is kept as a String.
function _valtype(T::Type)
    S = nonmissingtype(T)
    (S !== Union{} && S <: AbstractString && S !== String) || return T
    return S === T ? String : Union{Missing, String}
end

"""
    _jointype(A, B) -> Type

The element type that holds values of both `A` and `B`: the wider one when one contains the
other, `Union{Missing, S}` when they differ only by `Missing`, tuples component by component,
else `Any`.
"""
function _jointype(A::Type, B::Type)
    B <: A && return A
    A <: B && return B
    if A isa DataType && B isa DataType && A <: Tuple && B <: Tuple && fieldcount(A) == fieldcount(B)
        return Tuple{map(_jointype, fieldtypes(A), fieldtypes(B))...}
    end
    SA, SB = nonmissingtype(A), nonmissingtype(B)
    (SA === SB || SA === Union{} || SB === Union{}) && return Union{A, B}
    return Any
end

_anytype(T::Type) = T === Union{} ? Any : T

# Grow a flag vector to m entries, the new ones `x`.
function _growfill!(v::Vector, m::Int, x)
    n0 = length(v)
    resize!(v, m)
    @inbounds for i in (n0 + 1):m
        v[i] = x
    end
    return v
end

"""
    _newacc(agg, T) -> _Acc

A fresh accumulator (no groups yet; see `_grow!`) for aggregator `agg` over input values of
element type `T`.
"""
function _newacc end

# --- Sum, Prod, Max, Min, Extrema: a value per group, from the group's first value on

struct _FoldAcc{G, A, T} <: _Acc
    agg::G
    has::Vector{Bool}
    val::Vector{A}
end
_foldacc(agg::G, ::Type{A}, ::Type{T}) where {G, A, T} = _FoldAcc{G, A, T}(agg, Bool[], A[])

_newacc(agg::UP.Sum, T::Type) = _foldacc(agg, _statetype(z -> sum((z,)), T), T)
_newacc(agg::UP.Prod, T::Type) = _foldacc(agg, _statetype(z -> prod((z,)), T), T)
_newacc(agg::Union{UP.Max, UP.Min}, T::Type) = _foldacc(agg, _valtype(_anytype(T)), T)
_newacc(agg::UP.Extrema, T::Type) = (V = _valtype(_anytype(T)); _foldacc(agg, Tuple{V, V}, T))

@inline _fold1(::UP.Sum, x) = sum((x,))
@inline _fold1(::UP.Prod, x) = prod((x,))
@inline _fold1(::Union{UP.Max, UP.Min}, x) = x
@inline _fold1(::UP.Extrema, x) = (x, x)
@inline _foldstep(::UP.Sum, a, x) = a + x
@inline _foldstep(::UP.Prod, a, x) = a * x
@inline _foldstep(::UP.Max, a, x) = max(a, x)
@inline _foldstep(::UP.Min, a, x) = min(a, x)
@inline _foldstep(::UP.Extrema, a, x) = (min(a[1], x), max(a[2], x))
@inline _foldcomb(::UP.Sum, a, b) = a + b
@inline _foldcomb(::UP.Prod, a, b) = a * b
@inline _foldcomb(::UP.Max, a, b) = max(a, b)
@inline _foldcomb(::UP.Min, a, b) = min(a, b)
@inline _foldcomb(::UP.Extrema, a, b) = UP._ext(a, b)

_intype(::_FoldAcc{G, A, T}) where {G, A, T} = T
_ngroups(a::_FoldAcc) = length(a.has)
function _grow!(a::_FoldAcc, m::Int)
    _growfill!(a.has, m, false)
    resize!(a.val, m)
    return a
end
@inline function _step!(a::_FoldAcc, g::Int, x)
    @inbounds if a.has[g]
        a.val[g] = _foldstep(a.agg, a.val[g], x)
    else
        a.val[g] = _fold1(a.agg, x)
        a.has[g] = true
    end
    return nothing
end
@inline function _comb!(d::_FoldAcc, gd::Int, s::_FoldAcc, ls::Int)
    @inbounds if s.has[ls]
        if d.has[gd]
            d.val[gd] = _foldcomb(d.agg, d.val[gd], s.val[ls])
        else
            d.val[gd] = s.val[ls]
            d.has[gd] = true
        end
    end
    return nothing
end
_finalvalue(a::_FoldAcc, g::Int) = a.has[g] ? a.val[g] : UP.final(a.agg, UP.novalue)

# --- Count, CountTrue and n_rows(): a count per group

struct _CountAcc{G} <: _Acc
    agg::G
    n::Vector{Int}
end
_newacc(agg::Union{UP.Count, UP.CountTrue, _NRowsAgg}, ::Type) = _CountAcc(agg, Int[])
_intype(::_CountAcc) = Any
_ngroups(a::_CountAcc) = length(a.n)
_grow!(a::_CountAcc, m::Int) = (_growfill!(a.n, m, 0); a)
@inline _step!(a::_CountAcc{UP.Count}, g::Int, x) = (@inbounds a.n[g] += 1; nothing)
@inline function _step!(a::_CountAcc{UP.CountTrue}, g::Int, x)
    x isa Bool || throw(TypeError(:count, "", Bool, x))   # Base `count` takes Bool only
    @inbounds a.n[g] += x
    return nothing
end
@inline _comb!(d::_CountAcc, gd::Int, s::_CountAcc, ls::Int) = (@inbounds d.n[gd] += s.n[ls]; nothing)
_finalvalue(a::_CountAcc, g::Int) = a.n[g]

# --- any / all: three-valued, as Base

struct _BoolAcc{G} <: _Acc
    agg::G
    val::Vector{Union{Missing, Bool}}
end
_newacc(agg::Union{UP.AnyM, UP.AllM}, ::Type) = _BoolAcc(agg, Union{Missing, Bool}[])
_intype(::_BoolAcc) = Any
_ngroups(a::_BoolAcc) = length(a.val)
_grow!(a::_BoolAcc, m::Int) = (_growfill!(a.val, m, UP.init(a.agg)); a)
@inline _step!(a::_BoolAcc{UP.AnyM}, g::Int, x) = (@inbounds a.val[g] = a.val[g] | UP._checkbool(:any, x); nothing)
@inline _step!(a::_BoolAcc{UP.AllM}, g::Int, x) = (@inbounds a.val[g] = a.val[g] & UP._checkbool(:all, x); nothing)
@inline _comb!(d::_BoolAcc{UP.AnyM}, gd::Int, s::_BoolAcc, ls::Int) = (@inbounds d.val[gd] = d.val[gd] | s.val[ls]; nothing)
@inline _comb!(d::_BoolAcc{UP.AllM}, gd::Int, s::_BoolAcc, ls::Int) = (@inbounds d.val[gd] = d.val[gd] & s.val[ls]; nothing)
_finalvalue(a::_BoolAcc, g::Int) = a.val[g]

# --- mean: a float sum plus a count, as `UP.Mean` (critic N4: Int data never overflows)

struct _MeanAcc{F, T} <: _Acc
    s::Vector{F}
    n::Vector{Int}
end
_newacc(::UP.Mean, T::Type) = (F = _statetype(z -> false + float(z), T); _MeanAcc{F, T}(F[], Int[]))
_intype(::_MeanAcc{F, T}) where {F, T} = T
_ngroups(a::_MeanAcc) = length(a.n)
function _grow!(a::_MeanAcc, m::Int)
    resize!(a.s, m)
    _growfill!(a.n, m, 0)
    return a
end
@inline function _step!(a::_MeanAcc, g::Int, x)
    @inbounds begin
        a.s[g] = a.n[g] == 0 ? false + float(x) : a.s[g] + float(x)   # `UP.Mean` starts from `false`
        a.n[g] += 1
    end
    return nothing
end
@inline function _comb!(d::_MeanAcc, gd::Int, s::_MeanAcc, ls::Int)
    @inbounds if s.n[ls] > 0
        d.s[gd] = d.n[gd] == 0 ? s.s[ls] : d.s[gd] + s.s[ls]
        d.n[gd] += s.n[ls]
    end
    return nothing
end
_finalvalue(a::_MeanAcc, g::Int) = a.n[g] == 0 ? false / 0 : a.s[g] / a.n[g]

# --- var / std (`Spread` over `Moments`): Welford's update per row, Chan's merge per run

struct _SpreadAcc{F, T} <: _Acc
    agg::Spread
    n::Vector{Int}
    m::Vector{F}
    M2::Vector{F}
    miss::Vector{Bool}   # a `missing` value: the result is `missing`, as eager's
end
function _newacc(agg::Spread, T::Type)
    F = _statetype(float, nonmissingtype(T))
    return _SpreadAcc{F, T}(agg, Int[], F[], F[], Bool[])
end
_intype(::_SpreadAcc{F, T}) where {F, T} = T
_ngroups(a::_SpreadAcc) = length(a.n)
function _grow!(a::_SpreadAcc, m::Int)
    _growfill!(a.n, m, 0)
    _growfill!(a.m, m, false)
    _growfill!(a.M2, m, false)
    _growfill!(a.miss, m, false)
    return a
end
@inline function _step!(a::_SpreadAcc, g::Int, x)
    @inbounds begin
        n1 = a.n[g] + 1
        a.n[g] = n1
        if ismissing(x)
            a.miss[g] = true
        else
            xf = float(x)
            m0 = a.m[g]
            δ = xf - m0
            m1 = m0 + δ / n1
            a.M2[g] = a.M2[g] + δ * (xf - m1)
            a.m[g] = m1
        end
    end
    return nothing
end
@inline function _comb!(d::_SpreadAcc, gd::Int, s::_SpreadAcc, ls::Int)
    @inbounds begin
        nb = s.n[ls]
        nb == 0 && return nothing
        na = d.n[gd]
        d.miss[gd] |= s.miss[ls]
        if na == 0
            d.n[gd], d.m[gd], d.M2[gd] = nb, s.m[ls], s.M2[ls]
        else
            n = na + nb
            δ = s.m[ls] - d.m[gd]
            d.m[gd] = d.m[gd] + δ * nb / n
            d.M2[gd] = d.M2[gd] + s.M2[ls] + δ^2 * na * nb / n
            d.n[gd] = n
        end
    end
    return nothing
end
function _finalvalue(a::_SpreadAcc, g::Int)
    mo = a.agg.inner
    n = a.n[g]
    (n <= (mo.corrected ? 1 : 0) || a.miss[g]) && return missing   # Spread's rule (and n = 0)
    v = a.M2[g] / (mo.corrected ? n - 1 : n)
    return mo.std ? sqrt(v) : v
end

# --- first / last: a value per group and whether it is set (runs merge in row order)

struct _PickAcc{L, G, V, T} <: _Acc   # L: true for `last`
    agg::G
    has::Vector{Bool}
    val::Vector{V}
end
function _newacc(agg::Union{UP.First, UP.Last}, T::Type)
    V = _valtype(_anytype(T))
    return _PickAcc{agg isa UP.Last, typeof(agg), V, T}(agg, Bool[], V[])
end
_intype(::_PickAcc{L, G, V, T}) where {L, G, V, T} = T
_ngroups(a::_PickAcc) = length(a.has)
function _grow!(a::_PickAcc, m::Int)
    _growfill!(a.has, m, false)
    resize!(a.val, m)
    return a
end
@inline function _step!(a::_PickAcc{L}, g::Int, x) where {L}
    @inbounds if L || !a.has[g]
        a.val[g] = x
        a.has[g] = true
    end
    return nothing
end
@inline function _comb!(d::_PickAcc{L}, gd::Int, s::_PickAcc, ls::Int) where {L}
    @inbounds if s.has[ls] && (L || !d.has[gd])
        d.val[gd] = s.val[ls]
        d.has[gd] = true
    end
    return nothing
end
_finalvalue(a::_PickAcc, g::Int) = a.has[g] ? a.val[g] : UP.final(a.agg, UP.novalue)

# --- MapM, ReduceM (and any other aggregator): the protocol on one-row chunks, Vector{Any}

struct _ProtoAcc{G} <: _Acc
    agg::G
    st::Vector{Any}
end
_newacc(agg, ::Type) = _ProtoAcc(agg, Any[])
_intype(::_ProtoAcc) = Any
_ngroups(a::_ProtoAcc) = length(a.st)
function _grow!(a::_ProtoAcc, m::Int)
    for _ in (length(a.st) + 1):m
        push!(a.st, UP.init(a.agg))
    end
    return a
end
@inline _step!(a::_ProtoAcc, g::Int, x) = (@inbounds a.st[g] = UP.partial(a.agg, a.st[g], (x,)); nothing)
@inline _comb!(d::_ProtoAcc, gd::Int, s::_ProtoAcc, ls::Int) = (@inbounds d.st[gd] = UP.combine(d.agg, d.st[gd], s.st[ls]); nothing)
_finalvalue(a::_ProtoAcc, g::Int) = UP.final(a.agg, a.st[g])

# --- skipmissing(x): the inner accumulator over the non-missing values

struct _SkipAcc{A <: _Acc} <: _Acc
    inner::A
end
_newacc(agg::SkipMissingAgg, T::Type) = _SkipAcc(_newacc(agg.inner, _anytype(nonmissingtype(T))))
_intype(a::_SkipAcc) = _intype(a.inner)
_ngroups(a::_SkipAcc) = _ngroups(a.inner)
_grow!(a::_SkipAcc, m::Int) = (_grow!(a.inner, m); a)
@inline _step!(a::_SkipAcc, g::Int, x) = (ismissing(x) || _step!(a.inner, g, x); nothing)
@inline _comb!(d::_SkipAcc, gd::Int, s::_SkipAcc, ls::Int) = _comb!(d.inner, gd, s.inner, ls)
_finalvalue(a::_SkipAcc, g::Int) = _finalvalue(a.inner, g)

# --- the generic operations

"Fold the rows of one morsel: row `i` (value `col[i]`) into group `ids[i]` (a function barrier)."
function _fold!(a::_Acc, ids::Vector{Int}, col::AbstractVector)
    length(ids) == length(col) || throw(DimensionMismatch("_fold!: $(length(ids)) ids for $(length(col)) values"))
    @inbounds for (i, j) in zip(eachindex(ids), eachindex(col))
        _step!(a, ids[i], col[j])
    end
    return a
end
function _fold!(a::_CountAcc{_NRowsAgg}, ids::Vector{Int}, ::Nothing)
    @inbounds for g in ids
        a.n[g] += 1
    end
    return a
end

"Combine group `lids[k]` of the later accumulator `s` into group `gids[k]` of `d` (CC-005 order)."
function _mergeinto!(d::_Acc, gids::AbstractVector{Int}, s::_Acc, lids::AbstractVector{Int})
    length(gids) == length(lids) || throw(DimensionMismatch("_mergeinto!: $(length(gids)) targets for $(length(lids)) groups"))
    @inbounds for k in eachindex(gids, lids)
        _comb!(d, gids[k], s, lids[k])
    end
    return d
end

"Does the accumulator take values of element type `T` without widening?"
_accepts(a::_Acc, T::Type) = T <: _intype(a)
_accepts(a::_SkipAcc, T::Type) = _accepts(a.inner, _anytype(nonmissingtype(T)))

_aggof(a::_FoldAcc) = a.agg
_aggof(a::_SpreadAcc) = a.agg
_aggof(a::_PickAcc) = a.agg
_aggof(::_MeanAcc) = UP.Mean()

"""
    _widen(a, T) -> _Acc

`a` rebuilt for input values of element type `_jointype(_intype(a), T)`, every group's state
kept (the old state type is contained in the new one, or the new one is `Any`).
"""
_widen(a::_Acc, ::Type) = a     # states that do not depend on the input type
_widen(a::_SkipAcc, T::Type) = _SkipAcc(_widen(a.inner, _anytype(nonmissingtype(T))))
function _widen(a::Union{_FoldAcc, _MeanAcc, _SpreadAcc, _PickAcc}, T::Type)
    b = _newacc(_aggof(a), _jointype(_intype(a), T))
    _grow!(b, _ngroups(a))
    _mergeinto!(b, 1:_ngroups(a), a, 1:_ngroups(a))
    return b
end

"""
    _emptyfinal(agg, T)

The value of aggregator `agg` over an empty group of element type `T`: the eager protocol call
on no values (CC-006, CC-007: a neutral element, or its error).
"""
_emptyfinal(::_NRowsAgg, ::Type) = 0
_emptyfinal(agg, T::Type) = UP.aggregate(agg, UP.Map(identity), (Vector{_anytype(T)}(),))

"Every group's final value, by id (a function barrier over the accumulator's type)."
_finals(a::_Acc) = Any[_finalvalue(a, g) for g in 1:_ngroups(a)]
