# The hash-aggregate operator: typed keys, two-phase partial aggregation (phase-4 spec §2;
# ADR-0003 rules 5, 6, 8, 9). Group-by lane.
#
# This file holds the key machinery shared by the group-by and the joins (ADR-0003 rule 10: no
# duplicate key machinery): typed canonical keys, `keyhash`, the open-addressing `KeyTable`, and
# the join key-pair rule (critic N1). The names and signatures of `typed_keys`, `keyhash`,
# `KeyTable`, `getorinsert!`, `lookup`, `length` and `keyvalues` are frozen (phase-4 spec §2.2):
# later lanes may add methods but not change them.

# ---------------------------------------------------------------------------------------------
# Typed canonical keys

# A key element type: concrete, or `Union{Missing, S}` with `S` concrete (`Missing` alone too).
function _keyable(E::Type)
    E === Union{} && return false
    isconcretetype(E) && return true
    S = nonmissingtype(E)
    return S !== E && isconcretetype(S)
end

"""
    typed_keys(cols::AbstractVector{<:AbstractVector}, n::Int; codes::Bool = true)
        -> Union{Nothing, AbstractVector}

The canonical typed key of each of the `n` rows of the key columns `cols` (ADR-0003 rule 8):

- **one column** of element type `T` (concrete, or `Union{Missing, S}` with `S` concrete): a
  `Vector{T}` of canonical values (`_canon`: `-0.0` becomes `0.0`, every NaN payload one `NaN`;
  `missing` stays `missing`);
- **several columns:** a `Vector` of concrete `Tuple`s of the per-column keys;
- **no columns:** `fill((), n)`, every row one key;
- a **`DictColumn`** with `codes = true` (group-by within one frame): `UInt32` codes of its
  canonicalised dictionary (entries that are `±0.0` or NaN payloads of each other share one
  code; a `missing` row is code `0`), so string keys never hash strings per row. With
  `codes = false` (joins across frames): its canonical values, as for any column.

Returns `nothing` when a column's element type is abstract (e.g. `Any`, `Real`,
`Union{Int, Float64}`): the caller then uses the existing `Dict`-based path (rare; there is no
`Dict{Any}` on the hot path). A column whose length is not `n` is a `DimensionMismatch`.

Keys hash with [`keyhash`](@ref) and go into a [`KeyTable`](@ref). The raw (uncanonicalised)
first-seen key of a group is not kept here: see [`keyids!`](@ref). Frozen API (phase-4 spec §2.2).
"""
function typed_keys(cols::AbstractVector{<:AbstractVector}, n::Int; codes::Bool = true)
    for col in cols
        length(col) == n || throw(
            DimensionMismatch("typed_keys: key columns have lengths $(map(length, cols)), expected $n rows")
        )
    end
    isempty(cols) && return fill((), n)
    length(cols) == 1 && return _colkeys(cols[1], codes)
    ks = Vector{AbstractVector}(undef, length(cols))
    for j in eachindex(cols)
        k = _colkeys(cols[j], codes)
        k === nothing && return nothing
        ks[j] = k
    end
    return _tuplekeys(Tuple(ks), n)
end

_colkeys(col::AbstractVector, ::Bool) = _keyable(eltype(col)) ? _canonkeys(col) : nothing
function _colkeys(col::DictColumn, codes::Bool)
    codes && return _dictcodes(col)
    return _keyable(eltype(col)) ? _dictvalues(col) : nothing
end

function _canonkeys(col::AbstractVector{E}) where {E}
    out = Vector{E}(undef, length(col))
    @inbounds for (o, i) in zip(eachindex(out), eachindex(col))
        out[o] = _canon(col[i])
    end
    return out
end

# Codes of the canonicalised dictionary (the dictionary is small: `_keycodes` per entry, not per row).
function _dictcodes(col::DictColumn)
    length(col.dict) <= typemax(UInt32) ||
        throw(ArgumentError("typed_keys: a dictionary of $(length(col.dict)) entries exceeds UInt32 codes"))
    dcodes, _ = _keycodes(col.dict)
    return _dictcodes!(Vector{UInt32}(undef, length(col.codes)), col.codes, col.validity, dcodes)
end
function _dictcodes!(out::Vector{UInt32}, codes::Vector{<:Unsigned}, v::Validity, dcodes::Vector{Int})
    @inbounds for i in eachindex(out)
        out[i] = _isvalid(v, i) ? (dcodes[Int(codes[i])] % UInt32) : UInt32(0)
    end
    return out
end

function _dictvalues(col::DictColumn{E}) where {E}
    cv = _canonkeys(col.dict)
    return _dictvalues!(Vector{E}(undef, length(col.codes)), col.codes, col.validity, cv)
end
function _dictvalues!(out::Vector, codes::Vector{<:Unsigned}, ::Nothing, cv::AbstractVector)
    @inbounds for i in eachindex(out)
        out[i] = cv[Int(codes[i])]
    end
    return out
end
function _dictvalues!(out::Vector, codes::Vector{<:Unsigned}, v::BitVector, cv::AbstractVector)
    @inbounds for i in eachindex(out)
        out[i] = v[i] ? cv[Int(codes[i])] : missing
    end
    return out
end

# Several key columns: one concrete Tuple per row (a function barrier fills it).
_tuplekeys(ks::Tuple, n::Int) = _filltuples!(Vector{Tuple{map(eltype, ks)...}}(undef, n), ks)
function _filltuples!(out::Vector{<:Tuple}, ks::Tuple)
    @inbounds for i in eachindex(out)
        out[i] = map(k -> k[i], ks)
    end
    return out
end

# ---------------------------------------------------------------------------------------------
# Hashing

_canonkey(k) = _canon(k)
_canonkey(k::Tuple) = map(_canonkey, k)

"""
    keyhash(k)::UInt64

The hash of key `k`: Base `hash` of its canonical value (`_canon`, applied inside tuples too),
so `±0.0` and every NaN payload hash alike, and the hash agrees with `isequal` after
canonicalisation. Because Base `hash` agrees across numeric types and across string types, it
also agrees for every allowed join key pair (`_keypair_allowed`: e.g. `Int32` against
`Float64`, `true` against `1`, `NaN32` against `NaN`, `SubString` against `String`). Frozen API
(phase-4 spec §2.2).
"""
@inline keyhash(k)::UInt64 = hash(_canonkey(k)) % UInt64

"""
    keyhashes(keys::AbstractVector) -> Vector{UInt64}

[`keyhash`](@ref) of every key, in order (the hash column fed to [`getorinsert!`](@ref),
[`lookup`](@ref) and [`radix_partition`](@ref)).
"""
function keyhashes(keys::AbstractVector)
    out = Vector{UInt64}(undef, length(keys))
    @inbounds for (o, i) in zip(eachindex(out), eachindex(keys))
        out[o] = keyhash(keys[i])
    end
    return out
end

# ---------------------------------------------------------------------------------------------
# The open-addressing key table

"""
    KeyTable{K}(sizehint::Int)

A hash table of keys of type `K` (from [`typed_keys`](@ref)) giving each distinct key a dense
id, `1, 2, …` in first-seen order. Open addressing with linear probing over a power-of-two
number of slots, at load factor ≤ 0.5. The home slot of hash `h` is `(h & (cap - 1)) + 1`, the
**low** bits; [`radix_partition`](@ref) uses the high bits, so the two never correlate. Keys,
hashes and slot ids live in separate typed vectors (no `Dict`, no boxing). `sizehint` is the
expected number of keys. Not thread-safe: use one table per task.

Operations: [`getorinsert!`](@ref), [`lookup`](@ref), `length`, [`keyvalues`](@ref). Frozen API
(phase-4 spec §2.2).
"""
struct KeyTable{K}
    keys::Vector{K}         # by id
    hashes::Vector{UInt64}  # by id
    slots::Vector{Int}      # 0 = empty, else an id; length a power of two
    function KeyTable{K}(sizehint::Int) where {K}
        cap = max(8, nextpow(2, 2 * max(sizehint, 1)))
        keys = K[]
        hashes = UInt64[]
        sizehint!(keys, max(sizehint, 0))
        sizehint!(hashes, max(sizehint, 0))
        return new{K}(keys, hashes, zeros(Int, cap))
    end
end

"""
    length(t::KeyTable) -> Int

The number of distinct keys in `t` (the largest id).
"""
Base.length(t::KeyTable) = length(t.keys)

"""
    keyvalues(t::KeyTable{K})::Vector{K}

The keys of `t` in id order (`keyvalues(t)[id]`), canonical. This is the table's own vector:
do not mutate it.
"""
keyvalues(t::KeyTable{K}) where {K} = t.keys

@inline _homeslot(h::UInt64, mask::Int) = Int(h & (mask % UInt64)) + 1

"""
    getorinsert!(t::KeyTable{K}, k, h::UInt64)::Int

The id of key `k` with hash `h == keyhash(k)` in `t`, inserting it with the next id
(`length(t) + 1`) when absent. Keys compare with `isequal` after canonicalisation, so `-0.0`
finds `0.0`. A new key is stored as `convert(K, canonical k)`. The caller detects a new id as
`id == length(t)` after the call (or `id >` the length of its own per-id vectors) and keeps any
per-group data, such as the raw first-seen key, in its own vectors indexed by id (critic n4;
see [`keyids!`](@ref)). Frozen API (phase-4 spec §2.2).
"""
function getorinsert!(t::KeyTable{K}, k, h::UInt64) where {K}
    ck = _canonkey(k)
    slots = t.slots
    mask = length(slots) - 1
    s = _homeslot(h, mask)
    @inbounds while true
        id = slots[s]
        id == 0 && break
        t.hashes[id] == h && isequal(t.keys[id], ck) && return id
        s = (s & mask) + 1
    end
    push!(t.keys, ck)
    push!(t.hashes, h)
    id = length(t.keys)
    @inbounds slots[s] = id
    2 * id > length(slots) && _grow!(t)
    return id
end

"""
    lookup(t::KeyTable{K}, k, h::UInt64)::Int

The id of key `k` (hash `h == keyhash(k)`) in `t`, or `0` when absent. `k` may be of another
type than `K` (a join probing with `Int32` keys a `Float64` table): it compares with `isequal`
after canonicalisation, and an allowed key pair has equal hashes (`keyhash`). Frozen API
(phase-4 spec §2.2).
"""
function lookup(t::KeyTable, k, h::UInt64)
    ck = _canonkey(k)
    slots = t.slots
    mask = length(slots) - 1
    s = _homeslot(h, mask)
    @inbounds while true
        id = slots[s]
        id == 0 && break
        t.hashes[id] == h && isequal(t.keys[id], ck) && return id
        s = (s & mask) + 1
    end
    return 0
end

# Double the slots and reinsert every id from its stored hash (keys are not rehashed).
function _grow!(t::KeyTable)
    slots = t.slots
    resize!(slots, 2 * length(slots))
    fill!(slots, 0)
    mask = length(slots) - 1
    @inbounds for id in eachindex(t.hashes)
        s = _homeslot(t.hashes[id], mask)
        while slots[s] != 0
            s = (s & mask) + 1
        end
        slots[s] = id
    end
    return t
end

"""
    keyids!(ids::AbstractVector{Int}, t::KeyTable, keys::AbstractVector, hashes::AbstractVector{UInt64},
            firstrows::Vector{Int}) -> ids

Insert every `keys[i]` (hash `hashes[i]`) into `t`, writing its id to `ids[i]`, and push `i`
onto `firstrows` whenever a new id appears. With `firstrows` empty and `t` fresh on entry,
`firstrows[id]` is the first row of group `id`, so the caller's **raw first-seen key** vector is
`rawkeys = col[firstrows]` (the uncanonicalised value: the first `±0.0` in row order, ADR-0003
rule 8; critic n4). This is the pattern every caller of [`getorinsert!`](@ref) follows.
"""
function keyids!(ids::AbstractVector{Int}, t::KeyTable, keys::AbstractVector, hashes::AbstractVector{UInt64}, firstrows::Vector{Int})
    length(ids) == length(keys) == length(hashes) ||
        throw(DimensionMismatch("keyids!: ids, keys and hashes have lengths $(length(ids)), $(length(keys)), $(length(hashes))"))
    @inbounds for (o, i, q) in zip(eachindex(ids), eachindex(keys), eachindex(hashes))
        n0 = length(t)
        id = getorinsert!(t, keys[i], hashes[q])
        id > n0 && push!(firstrows, i)
        ids[o] = id
    end
    return ids
end

# ---------------------------------------------------------------------------------------------
# The join key-pair rule (critic N1; phase-4 spec §1.1)

# Base.BitInteger and Base.IEEEFloat spelled out (they are not public in Base).
const _KeyInt = Union{Int8, Int16, Int32, Int64, Int128, UInt8, UInt16, UInt32, UInt64, UInt128}
const _KeyFloat = Union{Float16, Float32, Float64}
const _NumKey = Union{Bool, _KeyInt, _KeyFloat}

_keybits(::Type{Bool}) = 1
_keybits(::Type{S}) where {S <: _KeyInt} = 8 * sizeof(S)

# Does every value of S survive conversion to T = promote_type(S, …)?
_keyfits(::Type{S}, ::Type{T}) where {S <: _KeyFloat, T} = T <: _KeyFloat && precision(S) <= precision(T)
_keyfits(::Type{S}, ::Type{T}) where {S <: Union{Bool, _KeyInt}, T <: Union{Bool, _KeyInt}} =
    typemin(S) >= typemin(T) && typemax(S) <= typemax(T)
_keyfits(::Type{S}, ::Type{T}) where {S <: Union{Bool, _KeyInt}, T <: _KeyFloat} = _keybits(S) <= precision(T)
_keyfits(::Type, ::Type) = false

# An integer (or Bool) paired with an IEEE float, either way round (★ K4).
_intfloat(Sx::Type, Sy::Type) =
    (Sx <: Union{Bool, _KeyInt} && Sy <: _KeyFloat) || (Sx <: _KeyFloat && Sy <: Union{Bool, _KeyInt})

"""
    _lossless_key_promotion(Sx::Type, Sy::Type) -> Bool

Whether two non-missing numeric key types may be compared as join keys after promotion (phase-4
spec §1.1, critic N1, amended by the user's ★ K4 answer of 2026-10-26): both are in
`Union{Bool, Base.BitInteger, Base.IEEEFloat}` and

- integer → integer when `typemin`/`typemax` fit in `T = promote_type(Sx, Sy)` (`Int64`/`UInt64`
  and `Int8`/`UInt8` are rejected);
- float → wider float;
- **an integer (or `Bool`) with a float: always allowed (★ K4)**, compared as `Float64` (see
  [`_keypair_compare_type`](@ref)). This one is not lossless above 2^53, as in dplyr.

Identical numeric types are allowed. A side of type `Union{}` (the non-missing type of an
all-missing key column) pairs with any type: its keys can only be `missing`. Anything else is
`false`. It is symmetric.
"""
function _lossless_key_promotion(Sx::Type, Sy::Type)
    (Sx === Union{} || Sy === Union{}) && return true   # an all-missing side: nothing to promote
    (Sx <: _NumKey && Sy <: _NumKey) || return false
    Sx === Sy && return true
    _intfloat(Sx, Sy) && return true                     # ★ K4: compared as Float64
    T = promote_type(Sx, Sy)
    return _keyfits(Sx, T) && _keyfits(Sy, T)
end

"""
    _keypair_compare_type(Sx::Type, Sy::Type) -> Type

The type both sides' keys are converted to before [`typed_keys`](@ref)/[`keyhash`](@ref) in a
join, for an allowed pair of non-missing key types ([`_keypair_allowed`](@ref)):

- an integer (or `Bool`) with a float (★ K4): `Float64`, or the float type when it is wider
  (`promote_type(F, Float64)`; with the IEEE types that is always `Float64`);
- other numeric pairs (lossless integer/integer, float/float): `promote_type(Sx, Sy)`;
- identical types: that type; two string types: `String`;
- a `Union{}` side (an all-missing key column): the other type.

A pair that is not allowed is an `ArgumentError`. **Above 2^53, two different integer keys can
convert to the same `Float64` and then match the same float key** (`Float64(2^53 + 1) ==
2.0^53`), as dplyr's integer/double joins do.
"""
function _keypair_compare_type(Sx::Type, Sy::Type)
    Sx === Union{} && return Sy
    Sy === Union{} && return Sx
    _keypair_allowed(Sx, Sy) || throw(ArgumentError("join keys of types $Sx and $Sy cannot be compared; convert them first"))
    Sx === Sy && return Sx
    Sx <: AbstractString && Sy <: AbstractString && return String
    if _intfloat(Sx, Sy)
        F = Sx <: _KeyFloat ? Sx : Sy
        return promote_type(F, Float64)
    end
    return promote_type(Sx, Sy)
end

"""
    _keypair_allowed(Sx::Type, Sy::Type) -> Bool

The join key-pair rule of phase-4 spec §1.1 (critic N1) on the non-missing key types
`Sx = nonmissingtype(Tx)`, `Sy = nonmissingtype(Ty)`: allowed only when `Sx === Sy`, when both
are `<: AbstractString` (unified to `String`), or when
[`_lossless_key_promotion`](@ref)`(Sx, Sy)`, which since the user's ★ K4 answer includes every
integer (or `Bool`) with a float, compared as `Float64` ([`_keypair_compare_type`](@ref) gives
the type both sides are converted to). For every allowed pair, `isequal(a, b)` implies
`keyhash(a) == keyhash(b)`, also after that conversion. Rejected pairs include `Date`/`DateTime`
(they can be `isequal` but hash differently), `Int64`/`UInt64`, `String`/`Int`, `Rational`,
`BigFloat`.
The caller raises the `ArgumentError` naming the columns.

- A side whose non-missing type is `Union{}` (an all-missing key column) pairs with **any**
  type: it can only match `missing`. This is checked first, before any subtype test (`Union{}`
  is a subtype of everything).
- The string branch relies on each string type's `hash` agreeing with `String`'s for equal
  contents (Base's `AbstractString` contract). That is tested for `String`, `SubString{String}`
  and a `StringColumn`'s `StringView` elements. A string type that hashes differently would
  break `isequal` ⇒ equal `keyhash` and must be converted to `String` first.
"""
function _keypair_allowed(Sx::Type, Sy::Type)
    # Union{} first: it is a subtype of everything, so the tests below would answer vacuously
    (Sx === Union{} || Sy === Union{}) && return true
    return Sx === Sy || (Sx <: AbstractString && Sy <: AbstractString) || _lossless_key_promotion(Sx, Sy)
end

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

# A sample value of a concrete number type, or nothing.
function _sample(S::Type)
    (S !== Union{} && isconcretetype(S) && S <: Number) || return nothing
    return try
        zero(S)
    catch
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

# ---------------------------------------------------------------------------------------------
# The hash-aggregate operator (phase-4 spec §2.3; ADR-0003 rules 5, 6, 9): each task folds a
# contiguous range of morsels into runs (a task's table between two radix flushes); the runs are
# merged per radix partition in (range, seq) order; the groups get their final values and are
# sorted by the keys exactly as the eager group index sorts them.

"""
Groups a task's table holds before it flushes into a run and starts a new table (ADR-0003
rule 9, "adaptive radix switch"). Initially 2^16; p4-bench calibrates it.
"""
const RADIX_SWITCH = 65_536

"""
Test switch (phase-4 spec §0.3): `0` uses [`RADIX_SWITCH`](@ref); a value `> 0` overrides it.
Read once per `collect` (never inside a morsel loop). Set only through `withforce` in tests.
"""
const _FORCE_RADIX_SWITCH = Ref(0)
_radix_limit() = (k = _FORCE_RADIX_SWITCH[]; k > 0 ? k : RADIX_SWITCH)

# Radix bits of the partitioned merge when some task switched: a few partitions per task.
_merge_bits(ntasks::Int) = clamp(ceil(Int, log2(4 * ntasks)), 3, 8)

"""
    HashAggSpec

What the hash-aggregate sink computes: the group `keys` (plain columns of the streamed stage's
output) and `drop` flag, one output per summary (`names`, expression `nodes` for their static
types, aggregators `aggs`, the input column or `nothing` for `n_rows()`), which keys are
dictionary columns remapped through a global dictionary (`dictmode`), and the shape of the
result: summarise's `groups` option and whether it came from `summarise(...; by)`.
"""
struct HashAggSpec
    keys::Vector{Symbol}
    drop::Bool
    names::Vector{Symbol}
    nodes::Vector{Any}
    aggs::Vector{Any}
    cols::Vector{Union{Nothing, Symbol}}
    dictmode::Vector{Bool}
    groups::Symbol
    by::Bool
end

_keytype(::KeyTable{K}) where {K} = K

# The table key type of typed keys: string views (into a morsel's buffer) are stored as String,
# converted once per new key (a table outlives the morsel).
function _tablekey(E::Type)
    E isa DataType && E <: Tuple && return Tuple{map(_tablekey, fieldtypes(E))...}
    return _valtype(E)
end

"`t` rebuilt with key type `K2`: every key reinserted in id order, so the ids are kept."
function _rekey(t::KeyTable, ::Type{K2}) where {K2}
    t2 = KeyTable{K2}(length(t))
    @inbounds for id in 1:length(t)
        getorinsert!(t2, t.keys[id], t.hashes[id])
    end
    return t2
end

"""
A global value-keyed dictionary for a dictionary-encoded key (critic M6): one shared
[`KeyTable`](@ref) of canonical values behind a lock. A morsel's codes are remapped to its ids,
consulted once per distinct code present in the morsel, so partitions with different or permuted
dictionaries group by value and no string is hashed per row.
"""
mutable struct _GlobalDict
    table::KeyTable
    lock::ReentrantLock
end
_GlobalDict() = _GlobalDict(KeyTable{Union{}}(16), ReentrantLock())

function _ensurekey!(gd::_GlobalDict, E::Type)
    K = _keytype(gd.table)
    Kn = _tablekey(E)
    Kn <: K || (gd.table = _rekey(gd.table, _jointype(K, Kn)))
    return gd
end

# Global codes (UInt32, 0 = missing) of a morsel's dictionary column.
function _globalcodes(gd::_GlobalDict, col::DictColumn)
    present = _presentcodes(zeros(Bool, length(col.dict)), col.codes, col.validity)
    gmap = zeros(UInt32, length(col.dict))
    lock(gd.lock) do
        _ensurekey!(gd, eltype(col.dict))
        _mapdict!(gmap, gd.table, col.dict, present)
    end
    return _applygmap!(Vector{UInt32}(undef, length(col.codes)), col.codes, col.validity, gmap)
end
function _applygmap!(out::Vector{UInt32}, codes::Vector{<:Unsigned}, v::Validity, gmap::Vector{UInt32})
    @inbounds for i in eachindex(out)
        out[i] = _isvalid(v, i) ? gmap[Int(codes[i])] : UInt32(0)
    end
    return out
end
# A plain column under a dictionary-mode key (another partition kind): every row through the table.
function _globalcodes(gd::_GlobalDict, col::AbstractVector)
    out = Vector{UInt32}(undef, length(col))
    lock(gd.lock) do
        _ensurekey!(gd, nonmissingtype(eltype(col)))
        _mapvalues!(out, gd.table, col)
    end
    return out
end
function _presentcodes(present::Vector{Bool}, codes::Vector{<:Unsigned}, v::Validity)
    @inbounds for i in eachindex(codes)
        _isvalid(v, i) && (present[Int(codes[i])] = true)
    end
    return present
end
function _globalid(t::KeyTable, x)
    id = getorinsert!(t, x, keyhash(x))
    id <= typemax(UInt32) || throw(ArgumentError("hash aggregate: more than $(typemax(UInt32)) dictionary values"))
    return id % UInt32
end
function _mapdict!(gmap::Vector{UInt32}, t::KeyTable, dict::AbstractVector, present::Vector{Bool})
    @inbounds for j in eachindex(present)
        present[j] && (gmap[j] = _globalid(t, dict[j]))
    end
    return gmap
end
function _mapvalues!(out::Vector{UInt32}, t::KeyTable, col::AbstractVector)
    @inbounds for (o, i) in zip(eachindex(out), eachindex(col))
        x = col[i]
        out[o] = ismissing(x) ? UInt32(0) : _globalid(t, x)
    end
    return out
end

# The keys of one morsel: canonical typed values per key column (global codes for a
# dictionary-mode key), a concrete Tuple per row for several columns.
function _sinkkeys(cols::Vector{AbstractVector}, n::Int, dictmode::Vector{Bool}, gds::Vector{Union{Nothing, _GlobalDict}})
    length(cols) == 1 && return _sinkkey1(cols[1], n, dictmode[1], gds[1])
    ks = Vector{AbstractVector}(undef, length(cols))
    for j in eachindex(cols)
        ks[j] = _sinkkey1(cols[j], n, dictmode[j], gds[j])
    end
    return _tuplekeys(Tuple(ks), n)
end
function _sinkkey1(col::AbstractVector, n::Int, dm::Bool, gd::Union{Nothing, _GlobalDict})
    dm && return _globalcodes(gd::_GlobalDict, col)
    k = typed_keys(AbstractVector[col], n; codes = false)
    return k === nothing ? Any[_canon(x) for x in col] : k
end

"A task's table and accumulators between two radix flushes, with each group's first row (`firstpos`, into the task's key chunks)."
mutable struct _Run
    table::KeyTable
    accs::Vector{_Acc}
    firstpos::Vector{Int}
end

"""
One task's partial state: its finished runs (flushed in `seq` order) and the current one, the
key columns of each new group's first row (`keychunks`, one chunk per non-empty morsel and key,
taken from the morsel, so their concatenation has the column kinds the gathered frame would
have), zero-row chunks of each output's input column (for the gathered element types), zero-row
chunks of the key columns of every morsel that was not pruned, empty ones included (`keykinds`,
for `_gathered_kind`), whether it switched to radix mode, and morsel 1's empty output (the
gather's result when no morsel has rows).
"""
mutable struct _AggTask
    runs::Vector{_Run}
    cur::Union{Nothing, _Run}
    keychunks::Vector{Vector{AbstractColumn}}
    colchunks::Vector{Vector{AbstractColumn}}
    keykinds::Vector{Vector{AbstractColumn}}
    nkeyrows::Int
    switched::Bool
    first::Union{Nothing, Frame}
end
_AggTask(spec::HashAggSpec) = _AggTask(
    _Run[], nothing, [AbstractColumn[] for _ in spec.keys], [AbstractColumn[] for _ in spec.cols],
    [AbstractColumn[] for _ in spec.keys], 0, false, nothing,
)

"Note the key columns' kinds of a morsel that was not pruned (see `_gathered_kind`)."
function _notekinds!(st::_AggTask, spec::HashAggSpec, f::Frame)
    for (j, k) in enumerate(spec.keys)
        push!(st.keykinds[j], take(getcol(f, k), Int[]))
    end
    return st
end

_ineltype(f::Frame, c::Union{Nothing, Symbol}) = c === nothing ? Any : eltype(getcol(f, c))

"""
    _consume!(st::_AggTask, spec, f::Frame, gds, limit) -> st

Fold one morsel (the streamed stage's output `f`) into the task's current run: typed keys, one
probe per row in the run's [`KeyTable`](@ref) (new groups record their first row), then each
accumulator over its column. A run whose table passes `limit` groups is flushed (`seq` + 1) and
the task is in radix mode from then on.
"""
function _consume!(st::_AggTask, spec::HashAggSpec, f::Frame, gds::Vector{Union{Nothing, _GlobalDict}}, limit::Int)
    n = f.nrow
    n == 0 && return st
    kcols = AbstractVector[getcol(f, k) for k in spec.keys]
    tk = _sinkkeys(kcols, n, spec.dictmode, gds)
    K = _tablekey(eltype(tk))
    run = st.cur
    if run === nothing
        accs = _Acc[_newacc(spec.aggs[o], _ineltype(f, spec.cols[o])) for o in eachindex(spec.aggs)]
        run = _Run(KeyTable{K}(min(n, 1024)), accs, Int[])
        st.cur = run
    elseif !(K <: _keytype(run.table))
        run.table = _rekey(run.table, _jointype(_keytype(run.table), K))
    end
    ids = Vector{Int}(undef, n)
    newrows = Int[]
    keyids!(ids, run.table, tk, keyhashes(tk), newrows)
    for k in eachindex(newrows)
        push!(run.firstpos, st.nkeyrows + k)
    end
    st.nkeyrows += length(newrows)
    for j in eachindex(kcols)
        push!(st.keychunks[j], take(kcols[j], newrows))
    end
    m = length(run.table)
    for o in eachindex(spec.aggs)
        c = spec.cols[o]
        col = c === nothing ? nothing : getcol(f, c)
        acc = run.accs[o]
        if col !== nothing
            push!(st.colchunks[o], take(col, Int[]))
            _accepts(acc, eltype(col)) || (acc = _widen(acc, eltype(col)); run.accs[o] = acc)
        end
        _grow!(acc, m)
        _fold!(acc, ids, col)
    end
    if m > limit
        push!(st.runs, run)
        st.cur = nothing
        st.switched = true
    end
    return st
end

# Insert run `s`'s groups `lids` into the partition table `t`; new groups record their first row.
function _mergekeys!(t::KeyTable, s::KeyTable, lids::AbstractVector{Int}, gfirst::Vector{Int}, firstpos::Vector{Int}, off::Int)
    gids = Vector{Int}(undef, length(lids))
    @inbounds for (k, l) in enumerate(lids)
        n0 = length(t)
        g = getorinsert!(t, s.keys[l], s.hashes[l])
        g > n0 && push!(gfirst, off + firstpos[l])
        gids[k] = g
    end
    return gids
end

_jointypes(ts) = isempty(ts) ? Any : foldl(_jointype, ts)

# Run f(j) for the partitions j in 1:np: on contiguous ranges over the threads, or inline.
function _foreach_partition(f::F, np::Int, threads::Bool) where {F}
    nt = threads ? min(Threads.nthreads(), np) : 1
    nt <= 1 && return (foreach(f, 1:np); nothing)
    _radix_foreach(nt) do t
        foreach(f, _radix_range(np, nt, t))
    end
    return nothing
end

"""
    _hashagg_merge(tasks, spec; radix, threads) -> Vector{(gfirst, accs)}

The merge (phase-4 spec §2.3): every run, in (range, seq) order, is radix-partitioned by the
high bits of its group hashes (`radix_partition`; one partition when no task switched and
`radix` is false); per partition, one task combines each group's accumulators in that order
(CC-005, so `first`, `last` and `reduce` see the rows in row order). Returns, per partition, each
group's first-row position (into the concatenated key chunks) and the merged accumulators.
"""
function _hashagg_merge(tasks::Vector{_AggTask}, spec::HashAggSpec; radix::Bool, threads::Bool)
    runs = _Run[]
    offs = Int[]
    off = 0
    for st in tasks
        for r in st.runs
            push!(runs, r)
            push!(offs, off)
        end
        st.cur === nothing || (push!(runs, st.cur); push!(offs, off))
        off += st.nkeyrows
    end
    p = (radix || any(st -> st.switched, tasks)) ? _merge_bits(length(tasks)) : 0
    np = 1 << p
    parts = [radix_partition(r.table.hashes, p) for r in runs]
    K = _jointypes([_keytype(r.table) for r in runs])
    Tin = Type[_jointypes(Type[_intype(r.accs[o]) for r in runs]) for o in eachindex(spec.aggs)]
    results = Vector{Tuple{Vector{Int}, Vector{_Acc}}}(undef, np)
    _foreach_partition(np, threads) do j
        results[j] = _mergepart(j, runs, offs, parts, K, Tin, spec)
    end
    return results
end

function _mergepart(j::Int, runs::Vector{_Run}, offs::Vector{Int}, parts, K::Type, Tin::Vector{Type}, spec::HashAggSpec)
    t = KeyTable{K}(16)
    gaccs = _Acc[_newacc(spec.aggs[o], Tin[o]) for o in eachindex(spec.aggs)]
    gfirst = Int[]
    for (r, run) in enumerate(runs)
        offsets, perm = parts[r]
        lids = view(perm, offsets[j]:(offsets[j + 1] - 1))
        isempty(lids) && continue
        gids = _mergekeys!(t, run.table, lids, gfirst, run.firstpos, offs[r])
        m = length(t)
        for o in eachindex(gaccs)
            _grow!(gaccs[o], m)
            _mergeinto!(gaccs[o], gids, run.accs[o], lids)
        end
    end
    return gfirst, gaccs
end

"""
    _gathered_kind(col, parts) -> AbstractColumn

The gathered column `col` with the kind the eager read gives it: `read_source` concatenates the
raw partitions with `vcat_columns`, which keeps a dictionary column only when every partition's
column shares its dictionary (`===`) and otherwise decodes to the values (element type the
`Union` of the parts'). `parts` are the morsels' columns (empty morsels included, pruned ones
not), so a lone non-empty morsel of a source with per-partition dictionaries is decoded too, and
`group_by(drop = false)` shows the levels eager shows. Used by the lazy gather and the
hash-aggregate sink.
"""
function _gathered_kind(col::AbstractColumn, parts::Vector{AbstractColumn})
    (col isa DictColumn && !isempty(parts)) || return col
    p1 = parts[1]
    p1 isa DictColumn && all(p -> p isa typeof(p1) && p.dict === p1.dict, parts) && return col
    E = Union{map(eltype, parts)...}
    v = Vector{E}(undef, length(col))
    for i in eachindex(col)
        v[i] = col[i]
    end
    return column(v)
end

"""
    _hashagg_finish(results, tasks, spec, fallback) -> Frame

The summary frame, as eager `summarise` builds it on the gathered frame: the distinct keys (each
group's raw first-seen key row, from the key chunks concatenated as the gather concatenates
columns, so the column kinds and a dictionary's levels are the gathered frame's) are indexed with
[`build_gindex`](@ref) (`drop = false` adds the empty groups of absent dictionary levels, CC-006
for their values), which sorts them by CF-008's key order; each output column gets its static
type from the gathered element types (`typed_column`). `fallback()` is the gather's result when
no morsel has rows.
"""
function _hashagg_finish(results, tasks::Vector{_AggTask}, spec::HashAggSpec, fallback)
    G = sum(r -> length(r[1]), results; init = 0)
    pos = Vector{Int}(undef, G)
    part = Vector{Int}(undef, G)
    gid = Vector{Int}(undef, G)
    k = 0
    for (j, (gfirst, _)) in enumerate(results), (g, q) in enumerate(gfirst)
        k += 1
        pos[k], part[k], gid[k] = q, j, g
    end
    order = sortperm(pos)                      # global first-seen order of the groups
    fb = nothing
    getfb() = (fb === nothing && (fb = fallback()); fb::Frame)
    keycat = AbstractColumn[]
    for j in eachindex(spec.keys)
        chunks = AbstractColumn[c for st in tasks for c in st.keychunks[j]]
        col = isempty(chunks) ? getcol(getfb(), spec.keys[j]) : vcat_columns(chunks)
        push!(keycat, _gathered_kind(col, AbstractColumn[c for st in tasks for c in st.keykinds[j]]))
    end
    kf = Frame(copy(spec.keys), AbstractColumn[take(c, pos[order]) for c in keycat])
    gi = build_gindex(kf, spec.keys; drop = spec.drop)
    ng = ngroups(gi)
    src = zeros(Int, ng)                       # the group's index in `order`, 0 for an empty group
    for g in 1:ng
        rows = group_rows(gi, g)
        isempty(rows) || (src[g] = rows[1])
    end
    # the gathered frame's element types (static types of the outputs, eager's empty groups)
    ctxnames = copy(spec.keys)
    ctxtypes = Type[eltype(c) for c in keycat]
    coltype = Vector{Type}(undef, length(spec.aggs))
    for o in eachindex(spec.aggs)
        c = spec.cols[o]
        c === nothing && (coltype[o] = Any; continue)
        chunks = AbstractColumn[x for st in tasks for x in st.colchunks[o]]
        coltype[o] = eltype(isempty(chunks) ? getcol(getfb(), c) : vcat_columns(chunks))
        c in ctxnames || (push!(ctxnames, c); push!(ctxtypes, coltype[o]))
    end
    ctx = SelectCtx(ctxnames, ctxtypes, copy(spec.keys))
    outcols = AbstractColumn[]
    for o in eachindex(spec.aggs)
        fv = [_finals(r[2][o]) for r in results]
        v = Vector{Any}(undef, ng)
        for g in 1:ng
            q = src[g]
            v[g] = q == 0 ? _emptyfinal(spec.aggs[o], coltype[o]) : fv[part[order[q]]][gid[order[q]]]
        end
        T = static_type(spec.nodes[o], ctx)
        push!(outcols, ng == 0 ? column(Vector{isconcretetype(nonmissingtype(T)) ? T : Any}()) : typed_column(v, T))
    end
    keycols = AbstractColumn[take(c, collect(1:ng)) for c in gi.keys]
    out = Frame([spec.keys; spec.names], AbstractColumn[keycols; outcols], Symbol[], nothing, ng)
    groups = spec.by || spec.groups === :drop ? Symbol[] : spec.groups === :keep ? copy(spec.keys) : spec.keys[1:(end - 1)]
    return isempty(groups) ? out : regroup(out, groups; drop = spec.drop)
end
