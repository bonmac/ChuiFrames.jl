# A minimal, bounds-checked FlatBuffers table reader for the Arrow metadata (ADR-0001 rule 10).
#
# FlatBuffers layout: a buffer starts with a `uoffset` (UInt32) to the root table. A table
# starts with an `soffset` (Int32): its vtable is at `table - soffset`. A vtable is UInt16s:
# its own size in bytes, the table's inline size, then one offset per field id (0 = absent,
# so the default applies). Strings, vectors and sub-tables are stored behind a `uoffset`
# relative to the field's own position; vectors start with a UInt32 element count.
# Every read is checked against the buffer, so a corrupt file raises `ArgumentError`.

_ipcerr(msg) = throw(ArgumentError("Arrow IPC: " * msg))

"Read a little-endian bits type `T` at zero-based byte position `pos` of `b`, bounds-checked."
@inline function _rd(::Type{T}, b::AbstractVector{UInt8}, pos::Integer) where {T <: Union{Integer, Float32, Float64, Bool}}
    n = sizeof(T)
    (pos >= 0 && pos + n <= length(b)) || _ipcerr("read of $n bytes at offset $pos is out of range (buffer of $(length(b)) bytes)")
    U = n == 1 ? UInt8 : n == 2 ? UInt16 : n == 4 ? UInt32 : UInt64
    x = zero(U)
    @inbounds for k in 0:(n - 1)
        x |= U(b[firstindex(b) + pos + k]) << (8k)
    end
    return T === Bool ? x != 0 : reinterpret(T, x)
end

"A FlatBuffers table: the buffer, the table's position and its vtable's position and size."
struct FBTable
    buf::Vector{UInt8}
    pos::Int
    vt::Int
    vtlen::Int
end

function FBTable(buf::Vector{UInt8}, pos::Integer)
    vt = Int(pos) - Int(_rd(Int32, buf, pos))
    vtlen = Int(_rd(UInt16, buf, vt))
    (vtlen >= 4 && iseven(vtlen)) || _ipcerr("corrupt FlatBuffers vtable")
    _rd(UInt8, buf, vt + vtlen - 1)             # the whole vtable is inside the buffer
    return FBTable(buf, Int(pos), vt, vtlen)
end

"The root table of a FlatBuffers buffer."
fb_root(buf::Vector{UInt8}) = FBTable(buf, Int(_rd(UInt32, buf, 0)))

"Byte offset (from the table start) of field `id`, or 0 when absent."
@inline function _fieldoff(t::FBTable, id::Int)
    slot = 4 + 2id
    return slot + 2 <= t.vtlen ? Int(_rd(UInt16, t.buf, t.vt + slot)) : 0
end

"Scalar field `id` of type `T`, or `default` when absent."
function fb_scalar(t::FBTable, id::Int, ::Type{T}, default) where {T}
    o = _fieldoff(t, id)
    return o == 0 ? T(default) : _rd(T, t.buf, t.pos + o)
end

# Position that a uoffset field points at, or -1 when absent.
function _deref(t::FBTable, id::Int)
    o = _fieldoff(t, id)
    o == 0 && return -1
    p = t.pos + o
    return p + Int(_rd(UInt32, t.buf, p))
end

"Sub-table field `id`, or `nothing` when absent."
function fb_table(t::FBTable, id::Int)
    p = _deref(t, id)
    return p < 0 ? nothing : FBTable(t.buf, p)
end

"String field `id` (empty when absent)."
function fb_string(t::FBTable, id::Int)
    p = _deref(t, id)
    p < 0 && return ""
    n = Int(_rd(UInt32, t.buf, p))
    p + 4 + n <= length(t.buf) || _ipcerr("string out of range")
    return String(t.buf[(p + 5):(p + 4 + n)])
end

"Vector field `id` with elements of `elsize` bytes: `(start, count)`, or `nothing` when absent."
function fb_vector(t::FBTable, id::Int, elsize::Int)
    p = _deref(t, id)
    p < 0 && return nothing
    n = Int(_rd(UInt32, t.buf, p))
    p + 4 + n * elsize <= length(t.buf) || _ipcerr("vector of $n elements out of range")
    return (p + 4, n)
end

"Vector of tables field `id` (empty when absent)."
function fb_tables(t::FBTable, id::Int)
    v = fb_vector(t, id, 4)
    v === nothing && return FBTable[]
    start, n = v
    return FBTable[FBTable(t.buf, start + 4(k - 1) + Int(_rd(UInt32, t.buf, start + 4(k - 1)))) for k in 1:n]
end

"Vector of scalars `T` field `id` (empty when absent)."
function fb_scalars(t::FBTable, id::Int, ::Type{T}) where {T}
    v = fb_vector(t, id, sizeof(T))
    v === nothing && return T[]
    start, n = v
    return T[_rd(T, t.buf, start + sizeof(T) * (k - 1)) for k in 1:n]
end
