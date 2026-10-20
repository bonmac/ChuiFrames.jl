# Column types over Arrow-layout buffers (ADR-0001 rules 1-9 and 12).
#
# Every column is an immutable `AbstractVector` whose element type comes from its declared
# schema: `Union{Missing,T}` when nullable (even with no `missing` present), `T` otherwise.
# Null slots always hold `nullvalue(T)` (the zero-null-slot invariant, rule 2); kernels may
# rely on it. Validity is a `BitVector` (byte-identical to an Arrow validity bitmap on
# little-endian machines, ST-06), or `nothing` for a non-nullable column.

"""
    AbstractColumn{E} <: AbstractVector{E}

Supertype of ChuiFrames' immutable columns. `E` is the declared element type: `Union{Missing,T}`
for a nullable column, `T` otherwise (ADR-0001 rule 1).
"""
abstract type AbstractColumn{E} <: AbstractVector{E} end

const Validity = Union{Nothing, BitVector}

"""
    StrView

The element type of string columns: a `StringViews.StringView` over a view of the column's
data buffer (ADR-0001 rule 3). It compares and hashes equal to the `String` with the same
bytes. An element keeps its column's data buffer alive; `String(x)` detaches it.
"""
const StrView = StringView{SubArray{UInt8, 1, Vector{UInt8}, Tuple{UnitRange{Int64}}, true}}

"The element type of binary columns: a view of the column's data buffer (ADR-0001 rule 4)."
const ByteView = SubArray{UInt8, 1, Vector{UInt8}, Tuple{UnitRange{Int64}}, true}

"""
    nullvalue(T)

The value written into a null slot of a column with value type `T` (ADR-0001 rule 2):
`zero(T)` for numbers, a fixed value for `Date`/`DateTime`.
"""
nullvalue(::Type{T}) where {T <: Number} = zero(T)
nullvalue(::Type{Date}) = Date(0, 12, 31)          # rata die 0
nullvalue(::Type{DateTime}) = DateTime(0, 12, 31)  # instant 0

_eltype(::Type{T}, ::Nothing) where {T} = T
_eltype(::Type{T}, ::BitVector) where {T} = Union{Missing, T}

"""
    isnullable(col) -> Bool

`true` when the column's declared element type admits `missing`.
"""
isnullable(col::AbstractColumn) = validity(col) !== nothing

"""
    validity(col) -> Union{Nothing,BitVector}

The validity bitmap (`true` = valid), or `nothing` for a non-nullable column.
"""
function validity end

@inline _isvalid(::Nothing, i) = true
@inline _isvalid(v::BitVector, i) = @inbounds v[i]

function _checkvalidity(v::Validity, n::Int)
    v === nothing || length(v) == n ||
        throw(ArgumentError("validity has length $(length(v)), expected $n"))
    return v
end

Base.IndexStyle(::Type{<:AbstractColumn}) = IndexLinear()

# ---------------------------------------------------------------------------------------------
# Primitive columns: fixed-width values (integers, floats, Date, DateTime).

"""
    PrimitiveColumn(values::Vector{T}, validity = nothing)

A fixed-width column. Null slots of `values` must hold `nullvalue(T)`; the constructor writes
it (it copies `values` only when a null slot needs fixing).
"""
struct PrimitiveColumn{E, T, V <: Validity} <: AbstractColumn{E}
    values::Vector{T}
    validity::V
    function PrimitiveColumn{E, T, V}(values::Vector{T}, validity::V) where {E, T, V <: Validity}
        _checkvalidity(validity, length(values))
        if validity !== nothing
            z = nullvalue(T)
            fixed = false
            @inbounds for i in eachindex(values)
                if !validity[i] && !isequal(values[i], z)
                    fixed || (values = copy(values); fixed = true)
                    values[i] = z
                end
            end
        end
        return new{E, T, V}(values, validity)
    end
end
PrimitiveColumn(values::Vector{T}, validity::V = nothing) where {T, V <: Validity} =
    PrimitiveColumn{_eltype(T, validity), T, V}(values, validity)

validity(c::PrimitiveColumn) = c.validity
Base.size(c::PrimitiveColumn) = (length(c.values),)
@inline function Base.getindex(c::PrimitiveColumn{E}, i::Int) where {E}
    @boundscheck checkbounds(c, i)
    return (@inbounds _isvalid(c.validity, i)) ? (@inbounds c.values[i]) : (missing::E)
end

# ---------------------------------------------------------------------------------------------
# Bool columns: a value bitmap plus validity; null value bits are cleared (rule 2).

"""
    BoolColumn(values::BitVector, validity = nothing)

A Boolean column stored as a bitmap; null value bits are cleared.
"""
struct BoolColumn{E, V <: Validity} <: AbstractColumn{E}
    values::BitVector
    validity::V
    function BoolColumn{E, V}(values::BitVector, validity::V) where {E, V <: Validity}
        _checkvalidity(validity, length(values))
        if validity !== nothing && any(values .& .!validity)
            values = values .& validity
        end
        return new{E, V}(values, validity)
    end
end
BoolColumn(values::BitVector, validity::V = nothing) where {V <: Validity} =
    BoolColumn{_eltype(Bool, validity), V}(values, validity)

validity(c::BoolColumn) = c.validity
Base.size(c::BoolColumn) = (length(c.values),)
@inline function Base.getindex(c::BoolColumn{E}, i::Int) where {E}
    @boundscheck checkbounds(c, i)
    return (@inbounds _isvalid(c.validity, i)) ? (@inbounds c.values[i]) : (missing::E)
end

# ---------------------------------------------------------------------------------------------
# Variable-width columns: strings and binary, as offsets + data + validity (rules 3-4).

"""
    StringColumn(offsets::Vector{O}, data::Vector{UInt8}, validity = nothing)

A UTF-8 string column in the Arrow offsets layout (`O` is `Int32` for Utf8, `Int64` for
LargeUtf8). `offsets` has `n + 1` zero-based entries; null slots are empty (zero length).
Elements are [`StrView`](@ref)s.
"""
struct StringColumn{E, O <: Union{Int32, Int64}, V <: Validity} <: AbstractColumn{E}
    offsets::Vector{O}
    data::Vector{UInt8}
    validity::V
    function StringColumn{E, O, V}(offsets::Vector{O}, data::Vector{UInt8}, validity::V) where {E, O, V}
        _checkoffsets(offsets, data, validity)
        return new{E, O, V}(offsets, data, validity)
    end
end
StringColumn(offsets::Vector{O}, data::Vector{UInt8}, validity::V = nothing) where {O, V <: Validity} =
    StringColumn{_eltype(StrView, validity), O, V}(offsets, data, validity)

"""
    BinaryColumn(offsets::Vector{O}, data::Vector{UInt8}, validity = nothing)

A binary column in the Arrow offsets layout. Elements are [`ByteView`](@ref)s (never strings).
"""
struct BinaryColumn{E, O <: Union{Int32, Int64}, V <: Validity} <: AbstractColumn{E}
    offsets::Vector{O}
    data::Vector{UInt8}
    validity::V
    function BinaryColumn{E, O, V}(offsets::Vector{O}, data::Vector{UInt8}, validity::V) where {E, O, V}
        _checkoffsets(offsets, data, validity)
        return new{E, O, V}(offsets, data, validity)
    end
end
BinaryColumn(offsets::Vector{O}, data::Vector{UInt8}, validity::V = nothing) where {O, V <: Validity} =
    BinaryColumn{_eltype(ByteView, validity), O, V}(offsets, data, validity)

const VarColumn = Union{StringColumn, BinaryColumn}

function _checkoffsets(offsets, data, validity)
    isempty(offsets) && throw(ArgumentError("offsets must have n + 1 entries"))
    n = length(offsets) - 1
    _checkvalidity(validity, n)
    first(offsets) >= 0 && last(offsets) <= length(data) ||
        throw(ArgumentError("offsets out of range of the data buffer"))
    @inbounds for i in 1:n
        offsets[i + 1] >= offsets[i] || throw(ArgumentError("offsets must be non-decreasing"))
        if validity !== nothing && !validity[i] && offsets[i + 1] != offsets[i]
            throw(ArgumentError("null slot $i must be empty (zero-null-slot invariant)"))
        end
    end
    return nothing
end

validity(c::VarColumn) = c.validity
Base.size(c::VarColumn) = (length(c.offsets) - 1,)
@inline _bytes(c::VarColumn, i::Int) =
    @inbounds view(c.data, (Int(c.offsets[i]) + 1):Int(c.offsets[i + 1]))
@inline function Base.getindex(c::StringColumn{E}, i::Int) where {E}
    @boundscheck checkbounds(c, i)
    return (@inbounds _isvalid(c.validity, i)) ? StringView(_bytes(c, i)) : (missing::E)
end
@inline function Base.getindex(c::BinaryColumn{E}, i::Int) where {E}
    @boundscheck checkbounds(c, i)
    return (@inbounds _isvalid(c.validity, i)) ? _bytes(c, i) : (missing::E)
end

"""
    widen_offsets(offsets::Vector{Int32}, extra::Integer) -> Vector{Int32} or Vector{Int64}

Offset-builder overflow check (ADR-0001 rule 3): returns `offsets` unchanged when
`last(offsets) + extra` fits in `Int32`, else a widened `Vector{Int64}` copy (LargeUtf8).
"""
function widen_offsets(offsets::Vector{Int32}, extra::Integer)
    Int64(last(offsets)) + Int64(extra) <= typemax(Int32) && return offsets
    return Vector{Int64}(offsets)
end
widen_offsets(offsets::Vector{Int64}, ::Integer) = offsets

# Build a variable-width column from byte sequences (nothing = null), widening offsets on
# overflow instead of wrapping.
function _build_var(::Type{C}, items, nullable::Bool) where {C}
    n = length(items)
    offsets = Vector{Int32}(undef, n + 1)
    offsets[1] = 0
    total = 0
    for (i, x) in enumerate(items)
        total += x === nothing ? 0 : sizeof(x)
    end
    offs = total > typemax(Int32) ? Vector{Int64}(undef, n + 1) : offsets
    offs[1] = 0
    data = Vector{UInt8}(undef, total)
    val = nullable ? trues(n) : nothing
    pos = 0
    for (i, x) in enumerate(items)
        if x === nothing
            val[i] = false
        else
            k = sizeof(x)
            k > 0 && copyto!(data, pos + 1, codeunits_of(x), 1, k)
            pos += k
        end
        offs[i + 1] = pos
    end
    return C(offs, data, val)
end
codeunits_of(x::AbstractString) = codeunits(String(x))
codeunits_of(x::Base.CodeUnits) = x
codeunits_of(x::AbstractVector{UInt8}) = x

# ---------------------------------------------------------------------------------------------
# Dictionary columns (rule 5): 1-based codes (0 in null slots), a dictionary of unique values.

"""
    DictColumn(codes::Vector{C}, dict::AbstractColumn, validity = nothing)

A dictionary-encoded column. `codes` are **1-based** indices into `dict` (`DataAPI.refarray`
returns them as is, as Arrow.jl's writer expects); null slots hold code `0`. `dict` holds
unique, non-missing values. Codes are compared only between columns sharing an identical
dictionary (ADR-0003 rule 8). v0 dictionaries are unordered.
"""
struct DictColumn{E, C <: Unsigned, D <: AbstractColumn, V <: Validity} <: AbstractColumn{E}
    codes::Vector{C}
    dict::D
    validity::V
    function DictColumn{E, C, D, V}(codes::Vector{C}, dict::D, validity::V) where {E, C, D, V}
        _checkvalidity(validity, length(codes))
        isnullable(dict) && throw(ArgumentError("a dictionary must not hold missing values"))
        nd = length(dict)
        fixed = false
        @inbounds for i in eachindex(codes)
            if _isvalid(validity, i)
                1 <= codes[i] <= nd || throw(ArgumentError("code $(codes[i]) out of range 1:$nd"))
            elseif codes[i] != 0
                fixed || (codes = copy(codes); fixed = true)
                codes[i] = 0
            end
        end
        return new{E, C, D, V}(codes, dict, validity)
    end
end
DictColumn(codes::Vector{C}, dict::D, validity::V = nothing) where {C <: Unsigned, D <: AbstractColumn, V <: Validity} =
    DictColumn{_eltype(eltype(dict), validity), C, D, V}(codes, dict, validity)

validity(c::DictColumn) = c.validity
Base.size(c::DictColumn) = (length(c.codes),)
@inline function Base.getindex(c::DictColumn{E}, i::Int) where {E}
    @boundscheck checkbounds(c, i)
    return (@inbounds _isvalid(c.validity, i)) ? (@inbounds c.dict[Int(c.codes[i])]) : (missing::E)
end

# ---------------------------------------------------------------------------------------------
# Nested columns (rule 6): lists (offsets + child) and structs (named children + validity).

"""
    ListColumn(offsets::Vector{O}, child::AbstractColumn, validity = nothing)

A list column (Arrow List / LargeList). Elements are views of `child`.
"""
struct ListColumn{E, O <: Union{Int32, Int64}, C <: AbstractColumn, V <: Validity} <: AbstractColumn{E}
    offsets::Vector{O}
    child::C
    validity::V
    function ListColumn{E, O, C, V}(offsets::Vector{O}, child::C, validity::V) where {E, O, C, V}
        isempty(offsets) && throw(ArgumentError("offsets must have n + 1 entries"))
        _checkvalidity(validity, length(offsets) - 1)
        last(offsets) <= length(child) || throw(ArgumentError("offsets out of range of the child"))
        return new{E, O, C, V}(offsets, child, validity)
    end
end
_listelt(::Type{C}) where {C} = SubArray{eltype(C), 1, C, Tuple{UnitRange{Int64}}, true}
ListColumn(offsets::Vector{O}, child::C, validity::V = nothing) where {O, C <: AbstractColumn, V <: Validity} =
    ListColumn{_eltype(_listelt(C), validity), O, C, V}(offsets, child, validity)

validity(c::ListColumn) = c.validity
Base.size(c::ListColumn) = (length(c.offsets) - 1,)
@inline function Base.getindex(c::ListColumn{E}, i::Int) where {E}
    @boundscheck checkbounds(c, i)
    _isvalid(c.validity, i) || return missing::E
    return @inbounds view(c.child, (Int(c.offsets[i]) + 1):Int(c.offsets[i + 1]))
end

"""
    StructColumn(children::NamedTuple of AbstractColumn, validity = nothing)

A struct column. Elements are `NamedTuple`s of the children's elements.
"""
struct StructColumn{E, C <: NamedTuple, V <: Validity} <: AbstractColumn{E}
    children::C
    length::Int
    validity::V
    function StructColumn{E, C, V}(children::C, n::Int, validity::V) where {E, C, V}
        all(ch -> length(ch) == n, values(children)) ||
            throw(ArgumentError("struct children must all have length $n"))
        _checkvalidity(validity, n)
        return new{E, C, V}(children, n, validity)
    end
end
function StructColumn(children::NamedTuple{names}, validity::V = nothing; length::Int = _nt_len(children, validity)) where {names, V <: Validity}
    T = NamedTuple{names, Tuple{map(eltype, values(children))...}}
    return StructColumn{_eltype(T, validity), typeof(children), V}(children, length, validity)
end
_nt_len(ch, v) = isempty(ch) ? (v === nothing ? 0 : Base.length(v)) : Base.length(first(values(ch)))

validity(c::StructColumn) = c.validity
Base.size(c::StructColumn) = (c.length,)
@inline function Base.getindex(c::StructColumn{E}, i::Int) where {E}
    @boundscheck checkbounds(c, i)
    _isvalid(c.validity, i) || return missing::E
    return map(ch -> @inbounds(ch[i]), c.children)
end

# ---------------------------------------------------------------------------------------------
# Object columns (rule 12): any other element type, carried through verbs by the interpreter.

"""
    ObjectColumn(values::Vector{T}, validity = nothing)

A column of arbitrary Julia values (`Any`, `Symbol`, `Rational`, user structs, nested
vectors of mixed types, …). Never compiled into kernels; raises an `ArgumentError` when
written to Arrow, CSV or Parquet.
"""
struct ObjectColumn{E, T, V <: Validity} <: AbstractColumn{E}
    values::Vector{T}
    validity::V
    function ObjectColumn{E, T, V}(values::Vector{T}, validity::V) where {E, T, V <: Validity}
        _checkvalidity(validity, length(values))
        return new{E, T, V}(values, validity)
    end
end
ObjectColumn(values::Vector{T}, validity::V = nothing) where {T, V <: Validity} =
    ObjectColumn{_eltype(T, validity), T, V}(values, validity)

validity(c::ObjectColumn) = c.validity
Base.size(c::ObjectColumn) = (length(c.values),)
@inline function Base.getindex(c::ObjectColumn{E}, i::Int) where {E}
    @boundscheck checkbounds(c, i)
    return (@inbounds _isvalid(c.validity, i)) ? (@inbounds c.values[i]) : (missing::E)
end

# ---------------------------------------------------------------------------------------------
# DataAPI: dictionary codes as refarray (1-based), the dictionary as refpool.

DataAPI.refarray(c::DictColumn) = c.codes
DataAPI.refpool(c::DictColumn) = c.dict
DataAPI.refvalue(c::DictColumn, i::Integer) = i == 0 ? missing : c.dict[Int(i)]

# ---------------------------------------------------------------------------------------------
# Ingest: any AbstractVector -> a column (rule 12). The declared element type is `eltype(v)`.

const _PRIM = Union{Int8, Int16, Int32, Int64, UInt8, UInt16, UInt32, UInt64, Float32, Float64, Date, DateTime}

"""
    column(v::AbstractVector) -> AbstractColumn

Convert a vector to the matching ChuiFrames column (ADR-0001 rule 12). The declared element
type is `eltype(v)`: a `Union{Missing,T}` eltype gives a nullable column even with no
`missing` present. Columns are returned unchanged (they are immutable).
"""
column(c::AbstractColumn) = c
function column(v::AbstractVector)
    E = eltype(v)
    T = nonmissingtype(E)
    nullable = E !== T
    return _column(T, v, nullable)
end

function _validity_of(v, nullable::Bool)
    nullable || return nothing
    return BitVector(!ismissing(x) for x in v)
end

function _column(::Type{T}, v, nullable) where {T <: _PRIM}
    isconcretetype(T) || return _column_other(T, v, nullable)   # e.g. Union{Int,Float64}
    vals = Vector{T}(undef, length(v))
    z = nullvalue(T)
    @inbounds for (i, x) in enumerate(v)
        vals[i] = ismissing(x) ? z : x
    end
    return PrimitiveColumn(vals, _validity_of(v, nullable))
end
function _column(::Type{Bool}, v, nullable)
    vals = BitVector(x === true for x in v)
    return BoolColumn(vals, _validity_of(v, nullable))
end
function _column(::Type{T}, v, nullable) where {T <: AbstractString}
    return _build_var(StringColumn, (ismissing(x) ? nothing : x for x in v), nullable)
end
function _column(::Type{T}, v, nullable) where {T <: AbstractVector{UInt8}}
    return _build_var(BinaryColumn, (ismissing(x) ? nothing : x for x in v), nullable)
end
_column(::Type{Union{}}, v, nullable) = _column(Missing, v, nullable)
_column(::Type{Missing}, v, nullable) = ObjectColumn(Vector{Missing}(v), falses(length(v)))

_column(::Type{T}, v, nullable) where {T} = _column_other(T, v, nullable)
function _column_other(::Type{T}, v, nullable) where {T}
    if T isa Union && T <: Real
        P = promote_type(_uniontypes(T)...)
        if P <: _PRIM && _lossless(P, v)
            return _column(P, map(x -> ismissing(x) ? missing : convert(P, x), v), nullable)
        end
    elseif T <: NamedTuple && isconcretetype(T)
        return _struct_column(T, v, nullable)
    elseif T <: AbstractVector && isconcretetype(T)
        return _list_column(T, v, nullable)
    end
    vals = Vector{T}(undef, length(v))
    for (i, x) in enumerate(v)
        # an `Any`-like T is not "nullable" (nonmissingtype(Any) === Any), so `missing` is a value
        (ismissing(x) && !(Missing <: T)) || (vals[i] = x)
    end
    return ObjectColumn(vals, _validity_of(v, nullable))
end

_uniontypes(T) = T isa Union ? Any[_uniontypes(T.a)..., _uniontypes(T.b)...] : Any[T]

function _lossless(::Type{P}, v) where {P}
    for x in v
        ismissing(x) && continue
        try
            y = convert(P, x)
            y == x || return false
        catch
            return false
        end
    end
    return true
end

function _struct_column(::Type{NamedTuple{names, Ts}}, v, nullable) where {names, Ts}
    n = length(v)
    children = map(enumerate(names)) do (k, nm)
        Tk = fieldtype(Ts, k)
        col = Vector{Tk}(undef, n)
        okk = trues(n)
        for (i, x) in enumerate(v)
            if ismissing(x)
                if Missing <: Tk
                    col[i] = missing
                else
                    okk[i] = false
                    col[i] = _placeholder(Tk)
                end
            else
                col[i] = getfield(x, nm)
            end
        end
        # a parent null makes this child slot null as well, so the child stays zero-null-slot
        all(okk) ? column(col) : column(Vector{Union{Missing, Tk}}([okk[i] ? col[i] : missing for i in 1:n]))
    end
    return StructColumn(NamedTuple{names}(Tuple(children)), _validity_of(v, nullable); length = n)
end
_placeholder(::Type{T}) where {T <: Number} = zero(T)
_placeholder(::Type{T}) where {T <: AbstractString} = T("")
_placeholder(::Type{T}) where {T} = (T <: _PRIM ? nullvalue(T) : throw(ArgumentError("cannot build a struct column of $T with null parents")))

function _list_column(::Type{T}, v, nullable) where {T}
    n = length(v)
    offsets = Vector{Int64}(undef, n + 1)
    offsets[1] = 0
    for (i, x) in enumerate(v)
        offsets[i + 1] = offsets[i] + (ismissing(x) ? 0 : length(x))
    end
    child = column(collect(eltype(T), Iterators.flatten(x for x in v if !ismissing(x))))
    o32 = last(offsets) <= typemax(Int32) ? Vector{Int32}(offsets) : offsets
    return ListColumn(o32, child, _validity_of(v, nullable))
end

# ---------------------------------------------------------------------------------------------
# Generic operations every verb needs: gather (take rows), slice, concatenate.

"""
    take(col, idx::AbstractVector{<:Integer}) -> AbstractColumn

The rows `idx` of `col`, as a column of the same kind and declared element type. `0` in `idx`
means a null row (used by joins and `lag`); it requires a nullable result, which `take` gives.
"""
function take end

_takevalidity(::Nothing, idx) = any(iszero, idx) ? BitVector(i != 0 for i in idx) : nothing
_takevalidity(v::BitVector, idx) = BitVector(i != 0 && v[i] for i in idx)

function take(c::PrimitiveColumn{E, T}, idx::AbstractVector{<:Integer}) where {E, T}
    z = nullvalue(T)
    vals = T[i == 0 ? z : c.values[i] for i in idx]
    return PrimitiveColumn(vals, _takevalidity(c.validity, idx))
end
function take(c::BoolColumn, idx::AbstractVector{<:Integer})
    return BoolColumn(BitVector(i != 0 && c.values[i] for i in idx), _takevalidity(c.validity, idx))
end
function take(c::C, idx::AbstractVector{<:Integer}) where {C <: VarColumn}
    val = _takevalidity(c.validity, idx)
    items = ((i == 0 || (val !== nothing && !val[k])) ? nothing : _bytes(c, Int(i)) for (k, i) in enumerate(idx))
    return _build_var(C.name.wrapper, items, val !== nothing)
end
function take(c::DictColumn, idx::AbstractVector{<:Integer})
    codes = eltype(c.codes)[i == 0 ? 0 : c.codes[i] for i in idx]
    return DictColumn(codes, c.dict, _takevalidity(c.validity, idx))
end
function take(c::ObjectColumn{E, T}, idx::AbstractVector{<:Integer}) where {E, T}
    val = _takevalidity(c.validity, idx)
    vals = Vector{T}(undef, length(idx))
    for (k, i) in enumerate(idx)
        (i != 0 && (val === nothing || val[k])) && (vals[k] = c.values[i])
    end
    return ObjectColumn(vals, val)
end
function take(c::StructColumn, idx::AbstractVector{<:Integer})
    ch = map(x -> take(x, idx), c.children)
    return StructColumn(ch, _takevalidity(c.validity, idx); length = length(idx))
end
function take(c::ListColumn, idx::AbstractVector{<:Integer})
    val = _takevalidity(c.validity, idx)
    n = length(idx)
    offsets = Vector{Int64}(undef, n + 1)
    offsets[1] = 0
    rows = Int[]
    for (k, i) in enumerate(idx)
        if i != 0 && (val === nothing || val[k])
            a, b = Int(c.offsets[i]) + 1, Int(c.offsets[i + 1])
            append!(rows, a:b)
            offsets[k + 1] = offsets[k] + (b - a + 1)
        else
            offsets[k + 1] = offsets[k]
        end
    end
    o = last(offsets) <= typemax(Int32) ? Vector{Int32}(offsets) : offsets
    return ListColumn(o, take(c.child, rows), val)
end

"""
    vcat_columns(cols::AbstractVector{<:AbstractColumn}) -> AbstractColumn

Concatenate columns in order. The result is nullable if any input is; columns of different
kinds or value types go through [`column`](@ref) on the promoted values.
"""
function vcat_columns(cols::AbstractVector)
    isempty(cols) && throw(ArgumentError("vcat_columns needs at least one column"))
    length(cols) == 1 && return cols[1]
    E = mapreduce(eltype, promote_type, cols)
    v = Vector{E}(undef, sum(length, cols))
    k = 0
    for c in cols, x in c
        v[k += 1] = x
    end
    return column(v)
end
