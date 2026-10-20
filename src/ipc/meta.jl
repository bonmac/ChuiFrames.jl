# Arrow IPC metadata (Schema.fbs, Message.fbs, File.fbs) parsed into small Julia structs.
# Field ids follow the .fbs declaration order; a union occupies two ids (type, value).

"A field's dictionary encoding: the dictionary id and the index type (rule 5: unordered only)."
struct IPCDict
    id::Int64
    index::DataType          # Int8 ... UInt64
end

"""
One schema field. `kind` is one of `:prim` (`T` is the value type: an integer, float,
`Date` (Date32) or `DateTime` (Timestamp(ms))), `:bool`, `:utf8`/`:binary` (`T` is the offset
type, `Int32` or `Int64`), `:utf8view`/`:binaryview`, `:list` (`T` is the offset type) or
`:struct`. A dictionary-encoded field describes its value type and has `dict` set.
"""
struct IPCField
    name::String
    nullable::Bool
    kind::Symbol
    T::DataType
    children::Vector{IPCField}
    dict::Union{Nothing, IPCDict}
end

const _TYPE_NAMES = Dict{UInt8, String}(
    1 => "Null", 2 => "Int", 3 => "FloatingPoint", 4 => "Binary", 5 => "Utf8", 6 => "Bool",
    7 => "Decimal", 8 => "Date", 9 => "Time", 10 => "Timestamp", 11 => "Interval", 12 => "List",
    13 => "Struct", 14 => "Union", 15 => "FixedSizeBinary", 16 => "FixedSizeList", 17 => "Map",
    18 => "Duration", 19 => "LargeBinary", 20 => "LargeUtf8", 21 => "LargeList",
    22 => "RunEndEncoded", 23 => "BinaryView", 24 => "Utf8View", 25 => "ListView", 26 => "LargeListView",
)
const _UNITS = ("SECOND", "MILLISECOND", "MICROSECOND", "NANOSECOND")
_unit(u) = 0 <= u <= 3 ? _UNITS[u + 1] : "unit $u"

_unsupported(path, tname, why = "") = throw(
    ArgumentError(
        "Arrow IPC: column $(repr(path)) has Arrow type $tname, which ChuiFrames does not read yet " *
            "(ADR-0001 rule 6$why)"
    )
)

_sc(t::Union{Nothing, FBTable}, id, ::Type{T}, d) where {T} = t === nothing ? T(d) : fb_scalar(t, id, T, d)

function _inttype(bits, signed)
    bits == 8 && return signed ? Int8 : UInt8
    bits == 16 && return signed ? Int16 : UInt16
    bits == 32 && return signed ? Int32 : UInt32
    bits == 64 && return signed ? Int64 : UInt64
    return nothing
end

const _MAX_DEPTH = 64

function _parse_field(t::FBTable, parent::String, depth::Int)
    depth > _MAX_DEPTH && _ipcerr("schema nested deeper than $_MAX_DEPTH levels")
    name = fb_string(t, 0)
    path = isempty(parent) ? name : parent * "." * name
    nullable = fb_scalar(t, 1, Bool, false)
    tt = fb_scalar(t, 2, UInt8, 0)
    ty = fb_table(t, 3)
    for kv in fb_tables(t, 6)                     # custom_metadata
        if fb_string(kv, 0) == "ARROW:extension:name"
            _unsupported(path, "extension<$(fb_string(kv, 1))>")
        end
    end
    children = IPCField[_parse_field(c, path, depth + 1) for c in fb_tables(t, 5)]
    d = fb_table(t, 4)
    dict = nothing
    if d !== nothing
        it = fb_table(d, 1)
        index = _inttype(_sc(it, 0, Int32, 32), _sc(it, 1, Bool, true))
        index === nothing && _ipcerr("column $(repr(path)): bad dictionary index type")
        fb_scalar(d, 2, Bool, false) && throw(
            ArgumentError(
                "Arrow IPC: column $(repr(path)) is an ordered dictionary (isOrdered = true), which " *
                    "ChuiFrames does not read yet (ADR-0001 rules 5 and 10: ordered levels wait for phase 6)"
            )
        )
        dict = IPCDict(fb_scalar(d, 0, Int64, 0), index)
    end
    kind, T = _parse_type(tt, ty, path, children)
    f = IPCField(name, nullable, kind, T, children, dict)
    if dict !== nothing
        kind in (:prim, :bool, :utf8, :binary, :utf8view, :binaryview) ||
            _unsupported(path, "Dictionary of $(_TYPE_NAMES[tt]) values")
    end
    return f
end

function _parse_type(tt::UInt8, ty, path, children)
    tname = get(_TYPE_NAMES, tt, "")
    isempty(tname) && _ipcerr("column $(repr(path)) has unknown Arrow type id $tt")
    if tt == 2
        bits, signed = _sc(ty, 0, Int32, 0), _sc(ty, 1, Bool, false)
        T = _inttype(bits, signed)
        T === nothing && _unsupported(path, "Int(bitWidth = $bits)")
        return :prim, T
    elseif tt == 3
        p = _sc(ty, 0, Int16, 0)
        p == 1 && return :prim, Float32
        p == 2 && return :prim, Float64
        return _unsupported(path, p == 0 ? "Float16 (HALF)" : "FloatingPoint(precision $p)")
    elseif tt == 6
        return :bool, Bool
    elseif tt in (4, 5, 19, 20)
        return (tt in (5, 20) ? :utf8 : :binary), (tt in (4, 5) ? Int32 : Int64)
    elseif tt == 23 || tt == 24
        return (tt == 24 ? :utf8view : :binaryview), Int32
    elseif tt == 8
        u = _sc(ty, 0, Int16, 1)
        u == 0 && return :prim, Date
        return _unsupported(path, "Date64 (Date with unit MILLISECOND)")
    elseif tt == 10
        u, tz = _sc(ty, 0, Int16, 0), (ty === nothing ? "" : fb_string(ty, 1))
        (u == 1 && isempty(tz)) && return :prim, DateTime
        return _unsupported(
            path, "Timestamp($(_unit(u))$(isempty(tz) ? "" : ", timezone = $(repr(tz))"))",
            ": µs/ns/zoned timestamps need the ArrowTimestamp type of a phase-2 ADR"
        )
    elseif tt == 12 || tt == 21
        length(children) == 1 || _ipcerr("column $(repr(path)): a $tname needs exactly one child")
        return :list, (tt == 12 ? Int32 : Int64)
    elseif tt == 13
        return :struct, Nothing
    elseif tt == 7
        p, s, w = _sc(ty, 0, Int32, 0), _sc(ty, 1, Int32, 0), _sc(ty, 2, Int32, 128)
        return _unsupported(path, "Decimal$w($p, $s)")
    elseif tt == 9
        u, w = _sc(ty, 0, Int16, 1), _sc(ty, 1, Int32, 32)
        return _unsupported(path, "Time$w($(_unit(u)))")
    elseif tt == 18
        return _unsupported(path, "Duration($(_unit(_sc(ty, 0, Int16, 1))))")
    elseif tt == 15
        return _unsupported(path, "FixedSizeBinary($(_sc(ty, 0, Int32, 0)))")
    elseif tt == 16
        return _unsupported(path, "FixedSizeList($(_sc(ty, 0, Int32, 0)))")
    end
    return _unsupported(path, tname)   # Null, Interval, Union, Map, RunEndEncoded, ListView, LargeListView
end

"Parse a Schema table: the top-level fields. Raises for a big-endian schema (rule 10)."
function _parse_schema(s::FBTable)
    fb_scalar(s, 0, Int16, 0) == 1 &&
        throw(ArgumentError("Arrow IPC: the schema is big-endian; ChuiFrames reads little-endian Arrow data only (ADR-0001 rule 10)"))
    fields = IPCField[_parse_field(f, "", 1) for f in fb_tables(s, 1)]
    return fields
end

# ---------------------------------------------------------------------------------------------
# Messages.

struct IPCNode
    length::Int64
    null_count::Int64
end

"A RecordBatch table: row count, field nodes, buffers, codec (-1 none, 0 LZ4 frame, 1 Zstd)."
struct IPCBatch
    length::Int64
    nodes::Vector{IPCNode}
    buffers::Vector{Tuple{Int64, Int64}}
    codec::Int8
    variadic::Vector{Int64}
end

function _parse_batch(t::FBTable)
    len = fb_scalar(t, 0, Int64, 0)
    len >= 0 || _ipcerr("negative record batch length $len")
    nodes = IPCNode[]
    v = fb_vector(t, 1, 16)
    if v !== nothing
        start, n = v
        for k in 0:(n - 1)
            push!(nodes, IPCNode(_rd(Int64, t.buf, start + 16k), _rd(Int64, t.buf, start + 16k + 8)))
        end
    end
    bufs = Tuple{Int64, Int64}[]
    v = fb_vector(t, 2, 16)
    if v !== nothing
        start, n = v
        for k in 0:(n - 1)
            push!(bufs, (_rd(Int64, t.buf, start + 16k), _rd(Int64, t.buf, start + 16k + 8)))
        end
    end
    c = fb_table(t, 3)
    codec = Int8(-1)
    if c !== nothing
        codec = fb_scalar(c, 0, Int8, 0)
        codec in (0, 1) || _ipcerr("unknown compression codec $codec")
        fb_scalar(c, 1, Int8, 0) == 0 || _ipcerr("unknown body compression method")
    end
    return IPCBatch(len, nodes, bufs, codec, fb_scalars(t, 4, Int64))
end

"One encapsulated message: header type, header table, and the body's position and length."
struct IPCMessage
    htype::UInt8             # 1 Schema, 2 DictionaryBatch, 3 RecordBatch
    header::FBTable
    bodystart::Int           # zero-based position in the input bytes
    bodylength::Int
end

function _parse_message(meta::Vector{UInt8}, bodystart::Int, total::Int)
    m = fb_root(meta)
    version = fb_scalar(m, 0, Int16, 0)
    version >= 3 || _ipcerr("metadata version V$(version + 1) is not supported (V4 or V5 needed)")
    htype = fb_scalar(m, 1, UInt8, 0)
    h = fb_table(m, 2)
    h === nothing && _ipcerr("message without a header")
    blen = fb_scalar(m, 3, Int64, 0)
    # (subtraction, not addition: no Int64 overflow on a corrupt length)
    (0 <= blen <= total - bodystart) || _ipcerr("message body of $blen bytes runs past the end of the input")
    htype in (1, 2, 3) || _ipcerr("unsupported message type $htype (tensors are not Arrow tables)")
    return IPCMessage(htype, h, bodystart, Int(blen))
end

"""
Read the encapsulated message at zero-based `pos`. Returns `(message, next position)`, or
`(nothing, pos)` at end of stream (an explicit zero-length marker or the end of the input).
Handles the continuation marker `0xFFFFFFFF` and the legacy form without it.
"""
function _read_message(bytes::Vector{UInt8}, pos::Int)
    total = length(bytes)
    pos + 4 <= total || return nothing, pos
    w = _rd(UInt32, bytes, pos)
    if w == 0xffffffff
        pos + 8 <= total || return nothing, pos      # a marker with no length: end of stream
        mlen, hdr = Int(_rd(Int32, bytes, pos + 4)), 8
    else
        mlen, hdr = Int(reinterpret(Int32, w)), 4    # legacy (pre-0.15) framing
    end
    mlen == 0 && return nothing, pos + hdr
    (mlen > 0 && pos + hdr + mlen <= total) || _ipcerr("message metadata of $mlen bytes at offset $pos runs past the end of the input")
    mstart = pos + hdr
    meta = bytes[(mstart + 1):(mstart + mlen)]
    msg = _parse_message(meta, mstart + mlen, total)
    return msg, mstart + mlen + msg.bodylength
end

# ---------------------------------------------------------------------------------------------
# The file footer.

const _MAGIC = codeunits("ARROW1")

_isfile(bytes) = length(bytes) >= 6 && view(bytes, 1:6) == _MAGIC

"Parse the footer of a file-format input: `(fields, dictionary blocks, record batch blocks)`."
function _parse_footer(bytes::Vector{UInt8})
    n = length(bytes)
    n >= 8 + 4 + 6 || _ipcerr("file too short to hold an Arrow footer (truncated?)")
    view(bytes, (n - 5):n) == _MAGIC || _ipcerr("missing trailing ARROW1 magic (truncated file?)")
    flen = Int(_rd(Int32, bytes, n - 10))
    fstart = n - 10 - flen
    (flen > 0 && fstart >= 8) || _ipcerr("bad footer length $flen")
    footer = fb_root(bytes[(fstart + 1):(n - 10)])
    s = fb_table(footer, 1)
    s === nothing && _ipcerr("footer has no schema")
    blocks(id) = begin
        v = fb_vector(footer, id, 24)
        v === nothing && return Tuple{Int, Int, Int}[]
        start, k = v
        Tuple{Int, Int, Int}[
            (
                Int(_rd(Int64, footer.buf, start + 24j)), Int(_rd(Int32, footer.buf, start + 24j + 8)),
                Int(_rd(Int64, footer.buf, start + 24j + 16)),
            ) for j in 0:(k - 1)
        ]
    end
    return _parse_schema(s), blocks(2), blocks(3), fstart
end

"The message of a footer block `(offset, metaDataLength, bodyLength)`; its body follows the metadata."
function _block_message(bytes::Vector{UInt8}, block, limit::Int)
    off, mlen, blen = block
    (8 <= off <= limit && 0 < mlen <= limit - off && 0 <= blen <= limit - off - mlen) ||   # no overflow
        _ipcerr("footer block (offset $off, metadata $mlen, body $blen) is out of range")
    msg, _ = _read_message(bytes, off)
    msg === nothing && _ipcerr("footer block at offset $off holds no message")
    return IPCMessage(msg.htype, msg.header, off + mlen, blen)
end
