# Decoding record-batch bodies into ChuiFrames columns (ADR-0001 rules 2-6, 10).
#
# Buffers are copied out of the input into fresh `Vector`s (rule 8), with every offset and
# length checked first. Null slots are then zeroed (rule 2): zero values, cleared Bool bits,
# empty strings and lists, dictionary code 0.

"A byte range of a decoded buffer: `data[off+1 : off+len]`."
struct BufRef
    data::Vector{UInt8}
    off::Int
    len::Int
end
const _NOBUF = BufRef(UInt8[], 0, 0)

"The dictionary in force for one id: deduplicated values plus the raw-index -> code map."
mutable struct DictState
    values::AbstractColumn      # unique, non-null values (the DictColumn's dictionary)
    codes::Vector{Int}          # raw dictionary index + 1 -> 1-based code, 0 for a null entry
    seen::Dict                  # value -> code
end

"Cursor over one record batch's nodes, buffers and variadic counts (pre-order, as written)."
mutable struct BatchCursor
    bytes::Vector{UInt8}
    msg::IPCMessage
    batch::IPCBatch
    node::Int
    buf::Int
    variadic::Int
    dicts::Dict{Int64, DictState}
end
BatchCursor(bytes, msg, batch, dicts) = BatchCursor(bytes, msg, batch, 0, 0, 0, dicts)

function _nextnode!(c::BatchCursor)
    c.node += 1
    c.node <= length(c.batch.nodes) || _ipcerr("record batch has too few field nodes for the schema")
    nd = c.batch.nodes[c.node]
    # every size computed from a node length (n + 1 offsets, 16n view bytes) stays far from overflow
    (0 <= nd.length <= _MAX_LEN && 0 <= nd.null_count <= nd.length) ||
        _ipcerr("bad field node (length $(nd.length), null count $(nd.null_count))")
    return Int(nd.length), Int(nd.null_count)
end

const _LZ4 = Int8(0)

function _nextbuf!(c::BatchCursor)
    c.buf += 1
    c.buf <= length(c.batch.buffers) || _ipcerr("record batch has too few buffers for the schema")
    off, len = c.batch.buffers[c.buf]
    (0 <= off <= c.msg.bodylength && 0 <= len <= c.msg.bodylength - off) ||   # no overflow
        _ipcerr("buffer (offset $off, length $len) lies outside the message body of $(c.msg.bodylength) bytes")
    len == 0 && return _NOBUF
    start = c.msg.bodystart + Int(off)
    c.batch.codec < 0 && return BufRef(c.bytes, start, Int(len))
    # BodyCompression BUFFER: an Int64 uncompressed length, then the codec frame (-1: stored raw).
    len >= 8 || _ipcerr("compressed buffer shorter than its length prefix")
    ulen = _rd(Int64, c.bytes, start)
    payload = c.bytes[(start + 9):(start + Int(len))]
    ulen == -1 && return BufRef(payload, 0, length(payload))
    ulen >= 0 || _ipcerr("bad uncompressed buffer length $ulen")
    out = try
        c.batch.codec == _LZ4 ? transcode(LZ4FrameDecompressor, payload) : transcode(ZstdDecompressor, payload)
    catch e
        e isa InterruptException && rethrow()
        _ipcerr("$(c.batch.codec == _LZ4 ? "LZ4" : "Zstd") decompression failed: $(sprint(showerror, e))")
    end
    length(out) == ulen || _ipcerr("decompressed buffer has $(length(out)) bytes, the prefix says $ulen")
    return BufRef(out, 0, length(out))
end

const _MAX_LEN = Int64(2)^40    # rows per node: far beyond any real batch, and n * 16 cannot overflow

"Check that `r` holds `n` elements of `elsize` bytes (compared by division: no overflow)."
_need(r::BufRef, n::Integer, elsize::Integer, what) =
    (n >= 0 && n <= r.len ÷ elsize) || _ipcerr("$what buffer has $(r.len) bytes, $(big(n) * elsize) needed")

"Copy `n` values of bits type `T` from the start of `r` (bounds-checked first)."
function _copyvals(::Type{T}, r::BufRef, n::Int, what) where {T}
    _need(r, n, sizeof(T), what)
    nb = n * sizeof(T)
    v = Vector{T}(undef, n)
    if nb > 0
        r.off + nb <= length(r.data) || _ipcerr("$what buffer out of range")
        GC.@preserve v r unsafe_copyto!(Ptr{UInt8}(pointer(v)), pointer(r.data, r.off + 1), nb)
    end
    return v
end

"A bitmap of `n` bits (LSB first, Arrow order) as a `BitVector`, unused tail bits cleared."
function _bitmap(r::BufRef, n::Int, what)
    nb = cld(n, 8)
    _need(r, nb, 1, what)
    bv = falses(n)
    if nb > 0
        r.off + nb <= length(r.data) || _ipcerr("$what buffer out of range")
        ch = bv.chunks
        GC.@preserve ch r unsafe_copyto!(Ptr{UInt8}(pointer(ch)), pointer(r.data, r.off + 1), nb)
        rem = n % 64
        rem == 0 || (ch[end] &= (UInt64(1) << rem) - UInt64(1))
    end
    return bv
end

"""
Validity of a node: `effective` (own nulls and the parent mask, `nothing` = all valid) and
`stored` (what the column keeps: a `BitVector` for a nullable field, else `nothing`).
"""
function _validity(r::BufRef, n, nulls, f::IPCField, mask, path)
    own = nulls == 0 ? nothing : _bitmap(r, n, "validity")
    if own !== nothing && !f.nullable
        _ipcerr("non-nullable column $(repr(path)) holds $nulls null(s)")
    end
    eff = own === nothing ? (mask === nothing ? nothing : copy(mask)) : (mask === nothing ? own : own .& mask)
    stored = f.nullable ? (eff === nothing ? trues(n) : eff) : nothing
    return eff, stored
end

_childpath(path::String, f::IPCField) = isempty(path) ? f.name : path * "." * f.name

const _EPOCH_DATE = Date(1970)
const _EPOCH_DATETIME = DateTime(1970)
const _MAX_MS = Int64(2)^62     # |ms| beyond this would overflow DateTime's Int64 instant

_storage(::Type{Date}) = Int32
_storage(::Type{DateTime}) = Int64
_storage(::Type{<:ArrowTimestamp}) = Int64
_storage(::Type{T}) where {T} = T
_fromraw(::Type{T}, x::Int64) where {T <: ArrowTimestamp} = T(x)   # raw count, unit and zone kept (ADR-0021)
_fromraw(::Type{Date}, x::Int32) = _EPOCH_DATE + Dates.Day(x)       # Date32: days since 1970-01-01
function _fromraw(::Type{DateTime}, x::Int64)                       # Timestamp(ms): ms since the epoch
    -_MAX_MS <= x <= _MAX_MS || _ipcerr("timestamp $x ms is out of the DateTime range")
    return _EPOCH_DATETIME + Dates.Millisecond(x)
end

"Decode the next field of the batch (pre-order) into a column; `mask` is the parent struct's validity."
function _decode(c::BatchCursor, f::IPCField, mask, path::String)
    n, nulls = _nextnode!(c)
    mask === nothing || length(mask) == n || _ipcerr("struct child $(repr(path)) has length $n, its parent $(length(mask))")
    vbuf = _nextbuf!(c)
    f.dict !== nothing && return _decode_dict(c, f, n, nulls, vbuf, mask, path)
    k = f.kind
    if k === :prim
        return _decode_prim(f.T, c, f, n, nulls, vbuf, mask, path)
    elseif k === :bool
        vals = _bitmap(_nextbuf!(c), n, "Bool values")
        eff, stored = _validity(vbuf, n, nulls, f, mask, path)
        eff === nothing || (vals .&= eff)
        return BoolColumn(vals, stored)
    elseif k === :utf8 || k === :binary
        return _decode_var(f.T, c, f, n, nulls, vbuf, mask, path)
    elseif k === :utf8view || k === :binaryview
        return _decode_view(c, f, n, nulls, vbuf, mask, path)
    elseif k === :list
        return _decode_list(f.T, c, f, n, nulls, vbuf, mask, path)
    else # :struct
        return _decode_struct(c, f, n, nulls, vbuf, mask, path)
    end
end

function _decode_prim(::Type{T}, c, f, n, nulls, vbuf, mask, path) where {T}
    raw = _copyvals(_storage(T), _nextbuf!(c), n, "values")
    eff, stored = _validity(vbuf, n, nulls, f, mask, path)
    if eff !== nothing
        z = zero(eltype(raw))
        @inbounds for i in 1:n
            eff[i] || (raw[i] = z)
        end
    end
    vals = T === _storage(T) ? raw : T[_fromraw(T, x) for x in raw]
    if eff !== nothing && T !== _storage(T)
        z = nullvalue(T)
        @inbounds for i in 1:n
            eff[i] || (vals[i] = z)
        end
    end
    return PrimitiveColumn(vals, stored)
end

_varcol(f::IPCField) = f.kind === :utf8 || f.kind === :utf8view ? StringColumn : BinaryColumn

function _decode_var(::Type{O}, c, f, n, nulls, vbuf, mask, path) where {O}
    obuf = _nextbuf!(c)
    dbuf = _nextbuf!(c)
    offs = (n == 0 && obuf.len == 0) ? O[0] : _copyvals(O, obuf, n + 1, "offsets")
    eff, stored = _validity(vbuf, n, nulls, f, mask, path)
    (offs[1] >= 0 && offs[end] <= dbuf.len) || _ipcerr("offsets of $(repr(path)) out of range of its data buffer")
    @inbounds for i in 1:n
        offs[i + 1] >= offs[i] || _ipcerr("offsets of $(repr(path)) decrease at row $i")
    end
    clean = offs[1] == 0 && (eff === nothing || all(eff[i] || offs[i] == offs[i + 1] for i in 1:n))
    if clean
        data = dbuf.data[(dbuf.off + 1):(dbuf.off + Int(offs[end]))]
        return _varcol(f)(offs, data, stored)
    end
    # Rebase (the offsets do not start at 0) and empty the null slots.
    newoffs = Vector{O}(undef, n + 1)
    newoffs[1] = 0
    total = 0
    for i in 1:n
        (eff === nothing || eff[i]) && (total += Int(offs[i + 1] - offs[i]))
        newoffs[i + 1] = total
    end
    data = Vector{UInt8}(undef, total)
    pos = 0
    for i in 1:n
        k = Int(offs[i + 1] - offs[i])
        if (eff === nothing || eff[i]) && k > 0
            copyto!(data, pos + 1, dbuf.data, dbuf.off + Int(offs[i]) + 1, k)
            pos += k
        end
    end
    return _varcol(f)(newoffs, data, stored)
end

# Utf8View / BinaryView: 16-byte views (Int32 length; <= 12 bytes inline, else a 4-byte
# prefix, an Int32 buffer index and an Int32 offset into a variadic data buffer). Converted to
# the offsets layout (rule 3).
function _decode_view(c, f, n, nulls, vbuf, mask, path)
    views = _nextbuf!(c)
    _need(views, n, 16, "views")
    c.variadic += 1
    c.variadic <= length(c.batch.variadic) || _ipcerr("record batch lacks variadicBufferCounts for view column $(repr(path))")
    nvar = c.batch.variadic[c.variadic]
    0 <= nvar <= length(c.batch.buffers) || _ipcerr("bad variadic buffer count $nvar")
    vars = BufRef[_nextbuf!(c) for _ in 1:nvar]
    eff, stored = _validity(vbuf, n, nulls, f, mask, path)
    V, b0 = views.data, views.off
    total = 0
    for i in 1:n
        (eff === nothing || eff[i]) || continue
        len = Int(_rd(Int32, V, b0 + 16(i - 1)))
        len >= 0 || _ipcerr("negative view length in $(repr(path))")
        total += len
    end
    offs = Vector{Int32}(undef, n + 1)
    offs[1] = 0
    total > typemax(Int32) && _ipcerr("view column $(repr(path)) holds more than 2 GiB of data in one batch")
    data = Vector{UInt8}(undef, total)
    pos = 0
    for i in 1:n
        if eff === nothing || eff[i]
            p = b0 + 16(i - 1)
            len = Int(_rd(Int32, V, p))
            if len <= 12
                len > 0 && copyto!(data, pos + 1, V, p + 5, len)
            else
                bi, bo = Int(_rd(Int32, V, p + 8)), Int(_rd(Int32, V, p + 12))
                (0 <= bi < nvar) || _ipcerr("view in $(repr(path)) points at variadic buffer $bi of $nvar")
                b = vars[bi + 1]
                (bo >= 0 && bo + len <= b.len) || _ipcerr("view in $(repr(path)) runs past its data buffer")
                copyto!(data, pos + 1, b.data, b.off + bo + 1, len)
            end
            pos += len
        end
        offs[i + 1] = pos
    end
    return _varcol(f)(offs, data, stored)
end

function _decode_list(::Type{O}, c, f, n, nulls, vbuf, mask, path) where {O}
    obuf = _nextbuf!(c)
    offs = (n == 0 && obuf.len == 0) ? O[0] : _copyvals(O, obuf, n + 1, "list offsets")
    eff, stored = _validity(vbuf, n, nulls, f, mask, path)
    child = _decode(c, f.children[1], nothing, _childpath(path, f.children[1]))
    (offs[1] >= 0 && offs[end] <= length(child)) || _ipcerr("list offsets of $(repr(path)) out of range of the child")
    @inbounds for i in 1:n
        offs[i + 1] >= offs[i] || _ipcerr("list offsets of $(repr(path)) decrease at row $i")
    end
    clean = offs[1] == 0 && (eff === nothing || all(eff[i] || offs[i] == offs[i + 1] for i in 1:n))
    clean && return ListColumn(offs, child, stored)
    newoffs = Vector{O}(undef, n + 1)
    newoffs[1] = 0
    rows = Int[]
    for i in 1:n
        if eff === nothing || eff[i]
            append!(rows, (Int(offs[i]) + 1):Int(offs[i + 1]))
        end
        newoffs[i + 1] = length(rows)
    end
    return ListColumn(newoffs, _gather(child, rows), stored)
end

function _decode_struct(c, f, n, nulls, vbuf, mask, path)
    # Only a childless struct has no buffer whose size bounds `n`: refuse absurd lengths.
    isempty(f.children) && nulls == 0 && n > (1 << 24) &&
        _ipcerr("struct column $(repr(path)) without children claims $n rows")
    names = Symbol[Symbol(ch.name) for ch in f.children]
    allunique(names) || _ipcerr("struct column $(repr(path)) has duplicate child names")
    own = nulls == 0 ? nothing : _bitmap(vbuf, n, "validity")
    own !== nothing && !f.nullable && _ipcerr("non-nullable column $(repr(path)) holds $nulls null(s)")
    eff = own === nothing ? mask : (mask === nothing ? own : own .& mask)
    kids = AbstractColumn[]
    for ch in f.children
        kid = _decode(c, ch, eff, _childpath(path, ch))
        length(kid) == n || _ipcerr("struct child $(repr(_childpath(path, ch))) has $(length(kid)) rows, its parent $n")
        push!(kids, kid)
    end
    # the children's buffers bound `n` now, so the all-valid bitmap below is safe to allocate
    stored = f.nullable ? (eff === nothing ? trues(n) : copy(eff)) : nothing
    return StructColumn(NamedTuple{Tuple(names)}(Tuple(kids)), stored; length = n)
end

# ---------------------------------------------------------------------------------------------
# Dictionaries (rule 5): deduplicated values, null entries folded into validity, 1-based codes.

"The unsigned code type for a dictionary index type, widened when the dictionary is larger."
_codetype(index::DataType) = sizeof(index) == 1 ? UInt8 : sizeof(index) == 2 ? UInt16 : UInt32
function _codetype(index::DataType, ndict::Int)
    C = _codetype(index)
    ndict <= typemax(UInt8) && return C
    ndict <= typemax(UInt16) && return sizeof(C) >= 2 ? C : UInt16
    ndict <= typemax(UInt32) && return UInt32
    return _ipcerr("dictionary with $ndict entries is too large")
end

function _decode_dict(c, f, n, nulls, vbuf, mask, path)
    d = f.dict
    st = get(c.dicts, d.id, nothing)
    st === nothing && _ipcerr("column $(repr(path)) uses dictionary id $(d.id), which was not sent before the batch")
    raw = _copyvals(d.index, _nextbuf!(c), n, "dictionary indices")
    own = nulls == 0 ? nothing : _bitmap(vbuf, n, "validity")
    own !== nothing && !f.nullable && _ipcerr("non-nullable column $(repr(path)) holds $nulls null(s)")
    eff = own === nothing ? (mask === nothing ? trues(n) : copy(mask)) : (mask === nothing ? own : own .& mask)
    C = _codetype(d.index, length(st.values))
    codes = Vector{C}(undef, n)
    nd = length(st.codes)
    folded = false
    @inbounds for i in 1:n
        if eff[i]
            r = Int(raw[i])
            0 <= r < nd || _ipcerr("dictionary index $r of $(repr(path)) is out of range 0:$(nd - 1)")
            code = st.codes[r + 1]
            code == 0 && (eff[i] = false; folded = true)
            codes[i] = code
        else
            codes[i] = 0
        end
    end
    folded && !f.nullable && _ipcerr("non-nullable column $(repr(path)) points at a null dictionary entry")
    return DictColumn(codes, st.values, f.nullable ? eff : nothing)
end

"The non-dictionary field that a dictionary batch for `f` holds (its values may be null)."
_valuefield(f::IPCField) = IPCField(f.name, true, f.kind, f.T, f.children, nothing)

"A copy of a column without validity (all its rows are valid)."
_strip(c::PrimitiveColumn) = PrimitiveColumn(c.values)
_strip(c::BoolColumn) = BoolColumn(c.values)
_strip(c::StringColumn) = StringColumn(c.offsets, c.data)
_strip(c::BinaryColumn) = BinaryColumn(c.offsets, c.data)
# unreachable: _parse_field admits only primitive, Bool, string and binary dictionary values
_strip(c::AbstractColumn) = _ipcerr("dictionaries of $(nameof(typeof(c))) values are not supported")

"Apply a DictionaryBatch: a new dictionary (replacement), or appended entries (delta)."
function _apply_dictionary!(dicts::Dict{Int64, DictState}, fields::Dict{Int64, IPCField}, bytes, msg::IPCMessage; allow_replace::Bool)
    h = msg.header
    id = fb_scalar(h, 0, Int64, 0)
    isdelta = fb_scalar(h, 2, Bool, false)
    data = fb_table(h, 1)
    data === nothing && _ipcerr("dictionary batch $id has no data")
    f = get(fields, id, nothing)
    f === nothing && _ipcerr("dictionary batch for id $id, which no schema field uses")
    batch = _parse_batch(data)
    cur = BatchCursor(bytes, msg, batch, dicts)
    raw = _decode(cur, _valuefield(f), nothing, f.name)
    length(raw) == batch.length || _ipcerr("dictionary batch $id: node length differs from the batch length")
    st = get(dicts, id, nothing)
    if st === nothing || !isdelta
        st !== nothing && !allow_replace &&
            _ipcerr("dictionary $id is replaced inside a file; the file format allows only delta dictionaries")
        st = _new_dictstate(raw)
        dicts[id] = st
    else
        _append_dict!(st, raw)
    end
    return nothing
end

function _new_dictstate(raw::AbstractColumn)
    empty = _strip(_gather(raw, Int[]))
    st = DictState(empty, Int[], Dict{nonmissingtype(eltype(raw)), Int}())
    _append_dict!(st, raw)
    return st
end

function _append_dict!(st::DictState, raw::AbstractColumn)
    newrows = Int[]
    n0 = length(st.values)
    for i in eachindex(raw)
        x = raw[i]
        if ismissing(x)
            push!(st.codes, 0)
        else
            code = get(st.seen, x, 0)
            if code == 0
                push!(newrows, i)
                code = n0 + length(newrows)
                st.seen[x] = code
            end
            push!(st.codes, code)
        end
    end
    if !isempty(newrows)
        part = _strip(_gather(raw, newrows))
        st.values = n0 == 0 ? part : _concat(AbstractColumn[st.values, part])
    end
    return st
end

"Collect the dictionary-encoded fields of a schema, by dictionary id."
function _dict_fields!(out::Dict{Int64, IPCField}, fields)
    for f in fields
        if f.dict !== nothing
            haskey(out, f.dict.id) && _ipcerr("dictionary id $(f.dict.id) is used by two fields")
            out[f.dict.id] = f
        end
        _dict_fields!(out, f.children)
    end
    return out
end

"Decode one RecordBatch message into a Frame with the schema's declared element types."
function _decode_batch(bytes, msg::IPCMessage, fields::Vector{IPCField}, dicts, types)
    batch = _parse_batch(msg.header)
    c = BatchCursor(bytes, msg, batch, dicts)
    cols = AbstractColumn[]
    for (j, f) in enumerate(fields)
        col = _decode(c, f, nothing, f.name)
        length(col) == batch.length ||
            _ipcerr("column $(repr(f.name)) has $(length(col)) rows, the record batch $(batch.length) (ST-04: the batch length governs)")
        eltype(col) === types[j] || error("ChuiFrames IPC internal error: column $(repr(f.name)) decoded as $(eltype(col)), declared $(types[j])")
        push!(cols, col)
    end
    return Frame(Symbol[Symbol(f.name) for f in fields], cols, Symbol[], nothing, Int(batch.length))
end
