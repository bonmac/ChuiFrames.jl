# Arrow IPC reader: ChuiFrames' own (ADR-0001 rule 10, the phase-2 spike gate).
#
# Reads the Arrow IPC file format (through the footer's block offsets) and the stream format
# (sequentially), with its own FlatBuffers table reader, into ChuiFrames' column types.
# Internal API, not exported: `read_ipc`, `read_ipc_batches`, `read_ipc_schema`, and
# `ipc_messages` (a message summary for tests and diagnostics).

# The codecs are TranscodingStreams codecs; TranscodingStreams adds methods to
# `Base.transcode(codec_type, bytes)`, which is what the reader calls (ADR-0016 to ADR-0018).
using CodecLz4: LZ4FrameDecompressor
using CodecZstd: ZstdDecompressor

include("flatbuf.jl")
include("meta.jl")
include("decode.jl")
include("concat.jl")

_ipcbytes(src::AbstractString) = (isfile(src) || throw(ArgumentError("Arrow IPC: no file $(repr(src))")); read(src))
_ipcbytes(src::Vector{UInt8}) = src
_ipcbytes(src) = throw(ArgumentError("Arrow IPC: expected a path or a Vector{UInt8}, got $(typeof(src))"))

_declared_types(fields) = Type[eltype(_empty(f)) for f in fields]

"""
Read every message of an IPC input: `(fields, frames)`. The file format goes through the
footer's blocks (dictionaries first, then record batches); the stream format is read in order,
and each record batch uses the dictionaries in force when it was written (#610).
"""
function _read_ipc(bytes::Vector{UInt8})
    ENDIAN_BOM == 0x04030201 || throw(ArgumentError("Arrow IPC: the reader needs a little-endian machine"))
    isempty(bytes) && _ipcerr("empty input")
    dicts = Dict{Int64, DictState}()
    frames = Frame[]
    if _isfile(bytes)
        fields, dblocks, rblocks, limit = _parse_footer(bytes)
        dfields = _dict_fields!(Dict{Int64, IPCField}(), fields)
        types = _declared_types(fields)
        for b in dblocks
            msg = _block_message(bytes, b, limit)
            msg.htype == 2 || _ipcerr("a footer dictionary block does not hold a dictionary batch")
            _apply_dictionary!(dicts, dfields, bytes, msg; allow_replace = false)
        end
        for b in rblocks
            msg = _block_message(bytes, b, limit)
            msg.htype == 3 || _ipcerr("a footer record-batch block does not hold a record batch")
            push!(frames, _decode_batch(bytes, msg, fields, dicts, types))
        end
        return fields, frames
    end
    msg, pos = _read_message(bytes, 0)
    (msg === nothing || msg.htype != 1) && _ipcerr("not an Arrow IPC file or stream (no ARROW1 magic and no leading schema message)")
    fields = _parse_schema(msg.header)
    dfields = _dict_fields!(Dict{Int64, IPCField}(), fields)
    types = _declared_types(fields)
    while true
        msg, pos = _read_message(bytes, pos)
        msg === nothing && break
        if msg.htype == 2
            _apply_dictionary!(dicts, dfields, bytes, msg; allow_replace = true)
        elseif msg.htype == 3
            push!(frames, _decode_batch(bytes, msg, fields, dicts, types))
        else
            _ipcerr("a second schema message inside the stream")
        end
    end
    return fields, frames
end

"""
    read_ipc_batches(src) -> Vector{Frame}

Read an Arrow IPC file or stream (`src` is a path or a `Vector{UInt8}`; the format is detected
from the `ARROW1` magic) into one [`Frame`](@ref) per record batch, in order. Every frame has
the same names and the schema's declared element types. A file with no batches gives `Frame[]`.
"""
read_ipc_batches(src) = _read_ipc(_ipcbytes(src))[2]

"""
    read_ipc_schema(src) -> Tables.Schema

The column names and declared element types of an Arrow IPC file or stream: `Union{Missing,T}`
for a nullable field, `T` otherwise (ADR-0001 rule 1). Raises `ArgumentError` for a type
ChuiFrames does not read (rule 6).
"""
function read_ipc_schema(src)
    bytes = _ipcbytes(src)
    isempty(bytes) && _ipcerr("empty input")
    if _isfile(bytes)
        fields = _parse_footer(bytes)[1]
    else
        msg, _ = _read_message(bytes, 0)
        (msg === nothing || msg.htype != 1) && _ipcerr("not an Arrow IPC file or stream")
        fields = _parse_schema(msg.header)
    end
    return Tables.Schema(Symbol[Symbol(f.name) for f in fields], _declared_types(fields))
end

"""
    read_ipc(src) -> Frame

Read an Arrow IPC file or stream into one [`Frame`](@ref): all record batches concatenated in
order, dictionary columns over one unified dictionary. An input with no batches gives a
zero-row frame with the schema's columns and element types.
"""
function read_ipc(src)
    fields, frames = _read_ipc(_ipcbytes(src))
    names = Symbol[Symbol(f.name) for f in fields]
    isempty(frames) && return Frame(names, AbstractColumn[_empty(f) for f in fields])
    length(frames) == 1 && return frames[1]
    cols = AbstractColumn[_concat(AbstractColumn[getcol(fr, j) for fr in frames]) for j in eachindex(fields)]
    return Frame(names, cols, Symbol[], nothing, sum(nrows, frames))
end

"""
    ipc_messages(src) -> Vector{NamedTuple}

A summary of the messages of an IPC input, in reading order: `(kind, id, isdelta, length)`
with `kind` one of `:schema`, `:dictionary`, `:recordbatch` (for tests and diagnostics).
"""
function ipc_messages(src)
    bytes = _ipcbytes(src)
    out = NamedTuple{(:kind, :id, :isdelta, :length), Tuple{Symbol, Int64, Bool, Int64}}[]
    function add(msg)
        h = msg.header
        if msg.htype == 1
            push!(out, (kind = :schema, id = 0, isdelta = false, length = 0))
        elseif msg.htype == 2
            d = fb_table(h, 1)
            push!(out, (kind = :dictionary, id = fb_scalar(h, 0, Int64, 0), isdelta = fb_scalar(h, 2, Bool, false), length = d === nothing ? 0 : fb_scalar(d, 0, Int64, 0)))
        else
            push!(out, (kind = :recordbatch, id = 0, isdelta = false, length = fb_scalar(h, 0, Int64, 0)))
        end
        return
    end
    if _isfile(bytes)
        _, dblocks, rblocks, limit = _parse_footer(bytes)
        foreach(b -> add(_block_message(bytes, b, limit)), dblocks)
        foreach(b -> add(_block_message(bytes, b, limit)), rblocks)
    else
        pos = 0
        while true
            msg, pos = _read_message(bytes, pos)
            msg === nothing && break
            add(msg)
        end
    end
    return out
end
