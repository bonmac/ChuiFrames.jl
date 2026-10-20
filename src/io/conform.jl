# Converting a partition to a sink's declared schema (ADR-0004 rule 7): every column becomes a
# ChuiFrames column with the declared element type, or an `ArgumentError` is raised. No sink
# ever hands a mismatched batch to a writer (Arrow.jl corrupts silently, ADR-0004 Context).

"""
    kind_type(T) -> Type

The value kind of element type `T` for schema comparison: every `AbstractString` is one kind,
every byte vector is one (binary), lists and named tuples compare by their element kinds.
Nullability is kept at the top level only; nested nullability is settled by
[`conform_column`](@ref).
"""
function kind_type(::Type{T}) where {T}
    S = nonmissingtype(T)
    K = _kind(S)
    return S === T ? K : Union{Missing, K}
end
_kind(::Type{T}) where {T} =
    T === Union{} ? Union{} :
    T <: AbstractString ? AbstractString :
    T <: AbstractVector{UInt8} ? AbstractVector{UInt8} :
    T <: AbstractVector ? Vector{_kind(nonmissingtype(eltype(T)))} :
    (T <: NamedTuple && isconcretetype(T)) ? NamedTuple{fieldnames(T), Tuple{map(t -> _kind(nonmissingtype(t)), fieldtypes(T))...}} :
    T

# Nested nullability follows the declared type: a list's child, or a struct's field, is
# nullable when its declared element type admits `missing`. The children of a nullable struct
# are always nullable (a null parent makes its children's slots null, ADR-0001 rule 6).
_conform_nested(c::AbstractColumn, ::Type) = c
function _conform_nested(c::ListColumn, ::Type{T}) where {T}
    (T <: AbstractVector && !(T <: AbstractVector{UInt8})) || return c
    ch = _conform_child(c.child, eltype(T), false)
    return ch === c.child ? c : ListColumn(c.offsets, ch, c.validity)
end
function _conform_nested(c::StructColumn, ::Type{T}) where {T}
    (T <: NamedTuple && isconcretetype(T) && fieldnames(T) == keys(c.children)) || return c
    force = isnullable(c)
    chs = map((ch, ET) -> _conform_child(ch, ET, force), values(c.children), fieldtypes(T))
    return StructColumn(NamedTuple{keys(c.children)}(chs), c.validity; length = length(c))
end
function _conform_child(ch::AbstractColumn, ::Type{ET}, force::Bool) where {ET}
    S = nonmissingtype(ET)
    if force || ET !== S
        ch = with_validity(ch)
    elseif isnullable(ch)
        any(ismissing, ch) && _nomissing("(nested)", S)
        ch = without_validity(ch)
    end
    return _conform_nested(ch, S)
end

_nullable_like(c::PrimitiveColumn, v) = PrimitiveColumn(c.values, v)
_nullable_like(c::BoolColumn, v) = BoolColumn(c.values, v)
_nullable_like(c::StringColumn, v) = StringColumn(c.offsets, c.data, v)
_nullable_like(c::BinaryColumn, v) = BinaryColumn(c.offsets, c.data, v)
_nullable_like(c::DictColumn, v) = DictColumn(c.codes, c.dict, v)
_nullable_like(c::ListColumn, v) = ListColumn(c.offsets, c.child, v)
_nullable_like(c::StructColumn, v) = StructColumn(c.children, v; length = length(c))
_nullable_like(c::ObjectColumn, v) = ObjectColumn(c.values, v)

"`c` with a validity bitmap (all valid) or without one (it must hold no `missing`)."
with_validity(c::AbstractColumn) = isnullable(c) ? c : _nullable_like(c, trues(length(c)))
without_validity(c::AbstractColumn) = isnullable(c) ? _nullable_like(c, nothing) : c

_noconvert(name, from, to) =
    throw(ArgumentError("column $(repr(name)): cannot convert element type $from to the declared $to"))
_nomissing(name, T) =
    throw(ArgumentError("column $(repr(name)) holds missing but is declared non-nullable $T"))

"""
    conform_column(name, v, E) -> AbstractColumn

Column `v` as a ChuiFrames column with declared element type `E`, or an `ArgumentError`.
Numbers convert only exactly (`Int` to `Float64` yes, `2.5` to `Int` no); other kinds must
match (any string type is a string).
"""
function conform_column(name, v::AbstractVector, ::Type{E}) where {E}
    T = nonmissingtype(E)
    nullable = E !== T
    c = column(v)
    n = length(c)
    cT = nonmissingtype(eltype(c))
    if cT === Union{} || cT === Missing          # an all-missing (or empty untyped) column
        n == 0 && return column(Vector{E}())
        nullable || _nomissing(name, T)
        return column(Vector{E}(fill(missing, n)))
    end
    if kind_type(cT) == kind_type(T)
        if nullable
            c = with_validity(c)
        elseif isnullable(c)
            any(ismissing, c) && _nomissing(name, T)
            c = without_validity(c)
        end
        return _conform_nested(c, T)
    end
    (T <: Real && cT <: Real) || _noconvert(name, cT, T)
    vals = Vector{E}(undef, n)
    for i in 1:n
        x = c[i]
        if ismissing(x)
            nullable || _nomissing(name, T)
            vals[i] = missing
        else
            y = try
                convert(T, x)
            catch
                _noconvert(name, cT, T)
            end
            (isequal(y, x) || y == x) || throw(ArgumentError("column $(repr(name)): value $x is not exactly representable as the declared $T"))
            vals[i] = y
        end
    end
    return column(vals)
end
conform_column(name, v, ::Type) = throw(ArgumentError("column $(repr(name)) is a $(typeof(v)), not an AbstractVector"))

"""
    conform_partition(part, schema::Tables.Schema) -> Frame

The partition `part` (any Tables.jl table) as a frame whose columns are those of `schema`, in
its order, each with the declared element type; an `ArgumentError` otherwise.
"""
function conform_partition(part, schema::Tables.Schema)
    cols = Tables.columns(part)
    have = collect(Symbol, Tables.columnnames(cols))
    want = collect(Symbol, schema.names)
    (length(have) == length(want) && Set(have) == Set(want)) ||
        throw(ArgumentError("partition columns $have do not match the declared columns $want"))
    out = AbstractColumn[conform_column(n, Tables.getcolumn(cols, n), E) for (n, E) in zip(want, schema_types(schema))]
    nrow = isempty(want) ? Tables.rowcount(cols) : -1
    return Frame(want, out, Symbol[], nothing, nrow)
end

"Raise an `ArgumentError` naming the type when `c` (or a nested child) is an object column."
check_writable(name, c::ObjectColumn, fmt) =
    throw(ArgumentError("column $(repr(name)) is an object column of element type $(nonmissingtype(eltype(c))), which cannot be written to $fmt"))
check_writable(name, c::DictColumn, fmt) = check_writable(name, c.dict, fmt)
check_writable(name, c::ListColumn, fmt) = check_writable(name, c.child, fmt)
function check_writable(name, c::StructColumn, fmt)
    foreach(ch -> check_writable(name, ch, fmt), values(c.children))
    return nothing
end
check_writable(name, ::AbstractColumn, fmt) = nothing
