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

"""
    _lossless_key_promotion(Sx::Type, Sy::Type) -> Bool

Whether two non-missing numeric key types promote without loss (phase-4 spec §1.1, critic N1):
both are in `Union{Bool, Base.BitInteger, Base.IEEEFloat}` and `T = promote_type(Sx, Sy)` keeps
every value of both:

- integer → integer when `typemin`/`typemax` fit in `T` (`Int64`/`UInt64` and `Int8`/`UInt8`
  are rejected);
- integer → float when the integer's bit width (`Bool`: 1) is ≤ the float's `precision`
  (significand bits + 1): `Int32`/`Float64` is allowed, `Int64`/`Float64` and `Int32`/`Float32`
  are rejected;
- float → wider float.

Identical numeric types are lossless. A side of type `Union{}` (the non-missing type of an
all-missing key column) is lossless with any type: its keys can only be `missing`. Anything else
is `false`. It is symmetric.
"""
function _lossless_key_promotion(Sx::Type, Sy::Type)
    (Sx === Union{} || Sy === Union{}) && return true   # an all-missing side: nothing to promote
    (Sx <: _NumKey && Sy <: _NumKey) || return false
    Sx === Sy && return true
    T = promote_type(Sx, Sy)
    return _keyfits(Sx, T) && _keyfits(Sy, T)
end

"""
    _keypair_allowed(Sx::Type, Sy::Type) -> Bool

The join key-pair rule of phase-4 spec §1.1 (critic N1) on the non-missing key types
`Sx = nonmissingtype(Tx)`, `Sy = nonmissingtype(Ty)`: allowed only when `Sx === Sy`, when both
are `<: AbstractString` (unified to `String`), or when
[`_lossless_key_promotion`](@ref)`(Sx, Sy)`. For every allowed pair, `isequal(a, b)` implies
`keyhash(a) == keyhash(b)`. Rejected pairs include `Date`/`DateTime` (they can be `isequal` but
hash differently), `Int64`/`Float64`, `Int64`/`UInt64`, `String`/`Int`, `Rational`, `BigFloat`.
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
