# Parquet through Parquet2.jl (ADR-0020): the format's Source and Sink, registered from
# `__init__` (ADR-0004 rule 9), so `using ChuiFrames, Parquet2` enables `.parquet` files.
#
# - Source: one partition per row group; projection pushed down (only the needed column chunks
#   are decoded); statistics from `Parquet2.ColumnStatistics` with ADR-0004 rule 4's rules: a
#   NaN or `missing` bound is reported as `nothing`, and `nnan` is always `nothing` (Parquet
#   statistics carry no NaN count, and pyarrow leaves NaN out of min/max, LC-11).
# - Sink: one row group per partition, statistics on. Parquet2 drops min/max for a chunk that
#   holds a `missing` (ADR-0020 rule 3), so pruning on ChuiFrames-written files works only for
#   null-free chunks. Temporary file + rename; abort deletes.
module ChuiFramesParquet2Ext

using ChuiFrames: ChuiFrames, Frame, AbstractColumn, StringColumn, BinaryColumn, DictColumn,
    ListColumn, StructColumn, StrView, conform_column, conform_partition, check_writable,
    pushed_columns, temp_path_for, empty_frame, ArrowTimestamp, timestamp_unit, timestamp_zone
using DataAPI: DataAPI
using Dates: Dates, DateTime
using Parquet2: Parquet2
using Tables: Tables

_pq_eltype(::Type{T}) where {T} = (S = nonmissingtype(T); S === T ? _pq_val(S) : Union{Missing, _pq_val(S)})
_pq_val(::Type{T}) where {T} = T <: AbstractString ? StrView : T

"""
    ParquetSource(src; kw...)

A Parquet file (path or bytes) as a `ChuiFrames.Source`: one partition per row group. `kw` go
to `Parquet2.Dataset`.
"""
struct ParquetSource <: ChuiFrames.Source
    label::String
    ds::Parquet2.Dataset
    names::Vector{Symbol}
    schema::Tables.Schema
    # timestamp columns (ADR-0021 rule 11): name => the value type they read as (`DateTime` or
    # an `ArrowTimestamp`), or a String saying why they cannot be read exactly
    ts::Dict{Symbol, Any}
end
function ParquetSource(src::Union{AbstractString, Vector{UInt8}}; kw...)
    ds = Parquet2.Dataset(src; kw...)
    sch = Tables.schema(ds)
    names = collect(Symbol, sch.names)
    types = Type[_pq_eltype(T) for T in sch.types]
    ts = _timestamp_columns(ds, names)
    for (j, n) in enumerate(names)
        V = get(ts, n, nothing)
        V isa Type && (types[j] = Missing <: sch.types[j] ? Union{Missing, V} : V)
    end
    label = src isa AbstractString ? "Parquet $(basename(src))" : "Parquet ($(length(src)) bytes)"
    return ParquetSource(label, ds, names, Tables.Schema(names, types), ts)
end

# ---------------------------------------------------------------------------------------------
# Exact timestamps (ADR-0021 rule 11). Parquet2 0.2.37 decodes every INT64 timestamp through a
# Float64 product and truncation (`unix2datetime(x * 10.0^exponent)`, TS-07), which puts about
# 1 in 170 millisecond values 1 ms early and truncates µs/ns. ChuiFrames therefore reads the raw
# Int64 counts itself: it rebuilds the column chunk with its physical type (`ParqInt64`), which
# Parquet2 then loads without conversion. This uses Parquet2 internals (the `Column` and
# `SchemaNode` fields); if they change, the read raises instead of returning shifted values, and
# the extension's tests pin exactness. Zones: `isAdjustedToUTC` (from the file metadata) says
# naive or UTC; the zone name comes from pyarrow's `ARROW:schema` metadata when present.

const _PQ_UNITS = Dict(-3 => Dates.Millisecond, -6 => Dates.Microsecond, -9 => Dates.Nanosecond)

function _timestamp_columns(ds::Parquet2.Dataset, names::Vector{Symbol})
    out = Dict{Symbol, Any}()
    length(ds) == 0 && return out
    rg = ds[1]
    utc = _adjusted_to_utc(ds)
    zones = _arrow_schema_zones(ds)
    for n in names
        t = rg[String(n)].type
        t isa Parquet2.ParqDateTime || continue
        if t.exponent === nothing
            out[n] = "it holds legacy INT96 timestamps, which Parquet2 rounds to milliseconds"
            continue
        end
        U = get(_PQ_UNITS, t.exponent, nothing)
        if U === nothing
            out[n] = "its timestamp unit 10^$(t.exponent) s is not s/ms/µs/ns"
            continue
        end
        a = get(utc, n, missing)
        if ismissing(a)
            out[n] = "its isAdjustedToUTC flag could not be read from the file metadata"
            continue
        end
        tz = a ? something(get(zones, n, nothing), :UTC) : nothing
        out[n] = (U === Dates.Millisecond && tz === nothing) ? DateTime : ArrowTimestamp{U, tz}
    end
    return out
end

# name => isAdjustedToUTC for top-level timestamp columns (the legacy TIMESTAMP_* converted
# types mean UTC, per the Parquet spec). Empty when the metadata layout is not as expected.
function _adjusted_to_utc(ds::Parquet2.Dataset)
    out = Dict{Symbol, Bool}()
    try
        els = getfield(ds, :meta_orig).schema       # depth-first, the root first
        # the subtree of element i spans _span(i) elements (itself included)
        _nch(i) = something(els[i].num_children, 0)
        function _span(i)
            k = 1
            for _ in 1:_nch(i)
                k += _span(i + k)
            end
            return k
        end
        i = 2
        for _ in 1:_nch(1)                          # the root's direct children only (critic)
            se = els[i]
            n = Symbol(se.name)
            lt = se.logicalType
            if _nch(i) == 0 && lt !== nothing && lt.TIMESTAMP !== nothing
                out[n] = lt.TIMESTAMP.isAdjustedToUTC
            elseif _nch(i) == 0 && se.converted_type !== nothing && occursin("TIMESTAMP", string(se.converted_type))
                out[n] = true
            end
            i += _span(i)
        end
    catch
        empty!(out)
    end
    return out
end

# name => zone Symbol from pyarrow's ARROW:schema (a base64 IPC schema message), parsed by
# ChuiFrames' own IPC reader. Missing or unreadable metadata gives no zones (UTC is used).
function _arrow_schema_zones(ds::Parquet2.Dataset)
    out = Dict{Symbol, Symbol}()
    b64 = get(DataAPI.metadata(ds), "ARROW:schema", nothing)
    b64 isa AbstractString || return out
    try
        sch = ChuiFrames.read_ipc_schema(_base64(b64))
        for (n, T) in zip(sch.names, sch.types)
            S = nonmissingtype(T)
            S <: ArrowTimestamp && timestamp_zone(S) !== nothing && (out[n] = timestamp_zone(S))
        end
    catch
        empty!(out)
    end
    return out
end

const _B64 = Dict{Char, UInt8}(c => UInt8(i - 1) for (i, c) in enumerate("ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/"))
function _base64(s::AbstractString)
    out = UInt8[]
    acc, bits = UInt32(0), 0
    for c in s
        (c == '=' || isspace(c)) && continue
        acc = (acc << 6) | _B64[c]
        bits += 6
        if bits >= 8
            bits -= 8
            push!(out, UInt8((acc >> bits) & 0xff))
        end
    end
    return out
end

"The raw Int64 counts of an INT64 timestamp column chunk (no Float64 conversion)."
function _raw_int64(col::Parquet2.Column, n::Symbol)
    return try
        node = col.node
        rawnode = Parquet2.SchemaNode{Parquet2.ParqInt64}((f === :type ? Parquet2.ParqInt64() : getfield(node, f) for f in fieldnames(typeof(node)))...)
        fields = Any[f === :type ? Parquet2.ParqInt64() : f === :node ? rawnode : getfield(col, f) for f in fieldnames(typeof(col))]
        raw = Parquet2.load(Parquet2.Column{Parquet2.ParqInt64, typeof(col).parameters[2]}(fields...))
        eltype(raw) <: Union{Missing, Int64} || error("raw values of type $(eltype(raw))")
        raw
    catch err
        throw(ArgumentError("Parquet: cannot read the exact timestamps of column $(repr(n)) with this Parquet2 version ($(sprint(showerror, err))); ChuiFrames does not use Parquet2's own timestamp decoding, which shifts values (ADR-0021 rule 11)"))
    end
end

function _timestamp_values(col::Parquet2.Column, n::Symbol, ::Type{V}) where {V}
    raw = _raw_int64(col, n)
    out = Vector{Union{Missing, V}}(undef, length(raw))
    for (i, x) in enumerate(raw)
        out[i] = ismissing(x) ? missing : V === DateTime ? _ms_datetime(n, x) : V(x)
    end
    return out
end
function _ms_datetime(n, x::Int64)
    inst = Int128(x) + ChuiFrames._UNIX_EPOCH_MS
    ChuiFrames._DT_MIN_MS <= inst <= ChuiFrames._DT_MAX_MS ||
        throw(ArgumentError("Parquet: column $(repr(n)): timestamp $x ms is out of the DateTime range"))
    return DateTime(1970) + Dates.Millisecond(x)      # exact: integer ms, range checked above
end

function _check_timestamp(s::ParquetSource, n::Symbol)
    V = get(s.ts, n, nothing)
    V isa AbstractString || return nothing
    throw(ArgumentError("Parquet: column $(repr(n)) cannot be read exactly: $V (ADR-0021 rule 11)"))
end

ChuiFrames.source_schema(s::ParquetSource) = s.schema
ChuiFrames.source_label(s::ParquetSource) = s.label
function ChuiFrames.plan_partitions(s::ParquetSource, scan::Tables.Scan; morsel::Int = ChuiFrames.DEFAULT_MORSEL)
    cols = pushed_columns(scan, s.names)
    return [(k, cols) for k in 1:length(s.ds)], scan
end
function ChuiFrames.read_partition(s::ParquetSource, (k, cols))
    rg = s.ds[k]
    names = cols === nothing ? s.names : cols
    out = AbstractColumn[]
    types = ChuiFrames.schema_types(s.schema)
    foreach(n -> _check_timestamp(s, n), names)
    for n in names
        j = findfirst(==(n), s.names)::Int
        V = get(s.ts, n, nothing)
        v = V isa Type ? _timestamp_values(rg[String(n)], n, V) : Parquet2.load(rg, String(n))
        push!(out, conform_column(n, v, types[j]))
    end
    return Frame(copy(names), out, Symbol[], nothing, DataAPI.nrow(rg))
end
ChuiFrames.partition_row_count(s::ParquetSource, (k, _)) = (DataAPI.nrow(s.ds[k]), true)
ChuiFrames.row_count(s::ParquetSource) = (DataAPI.nrow(s.ds), true)

_bound(x) = (x === nothing || ismissing(x) || (x isa AbstractFloat && isnan(x))) ? nothing : x

"""
    partition_stats(s::ParquetSource, (k, cols), col)

`(; lo, hi, nnull, nnan, ndistinct)` from the row group's column-chunk statistics. A bound that
is absent, `missing` or NaN is `nothing`; `nnan` is always `nothing` (unknown).
"""
function ChuiFrames.partition_stats(s::ParquetSource, (k, _), col::Symbol)
    col in s.names || return nothing
    # Parquet2 decodes timestamp bounds through the same lossy Float64 path: shifted bounds
    # would prune wrongly (review M1; ADR-0021 rule 11), so timestamp columns report none.
    haskey(s.ts, col) && return nothing
    st = try
        Parquet2.ColumnStatistics(s.ds[k][String(col)])
    catch
        return nothing
    end
    lo, hi = _bound(st.min), _bound(st.max)
    lo isa AbstractString && (lo = String(lo))
    hi isa AbstractString && (hi = String(hi))
    return (; lo, hi, nnull = st.n_null, nnan = nothing, ndistinct = st.n_distinct)
end

# ---------------------------------------------------------------------------------------------

"""
    ParquetSink(path; compression = :snappy)

The Parquet sink: one row group per partition, column statistics on, written to a temporary
file and renamed on close. `compression` is any Parquet2 codec (`:uncompressed`, `:snappy`,
`:gzip`, `:brotli`, `:zstd`). List and struct columns are not supported yet (`ArgumentError`).
"""
struct ParquetSink <: ChuiFrames.Sink
    path::String
    compression::Symbol
end
ParquetSink(path::AbstractString; compression::Symbol = :snappy) = ParquetSink(String(path), compression)

mutable struct ParquetSinkState
    sink::ParquetSink
    schema::Tables.Schema
    tmp::String
    io::Union{Nothing, IOStream}
    fw::Any
    nrows::Int
    done::Bool
end

function ChuiFrames.open_sink(k::ParquetSink, schema::Tables.Schema)
    tmp = temp_path_for(k.path)
    io = open(tmp, "w")
    return ParquetSinkState(k, schema, tmp, io, nothing, 0, false)
end

# What Parquet2 is handed: plain vectors with the declared element type.
_pq_present(n, c::StringColumn) = collect(ChuiFrames.isnullable(c) ? Union{Missing, String} : String, c)
_pq_present(n, c::BinaryColumn) = collect(ChuiFrames.isnullable(c) ? Union{Missing, Vector{UInt8}} : Vector{UInt8}, c)
_pq_present(n, c::DictColumn) = _pq_present(n, ChuiFrames.column(collect(eltype(c), c)))
_pq_present(n, c::Union{ListColumn, StructColumn}) =
    throw(ArgumentError("column $(repr(n)) is a $(nameof(typeof(c))); the Parquet sink does not write nested columns yet"))
_pq_present(n, c::AbstractColumn) = collect(eltype(c), c)

# Timestamps (ADR-0021 rule 11). Parquet2 writes `DateTime` through `datetime2unix` and `floor`,
# which puts about 1 in 100 values 1 ms off, and it writes only naive milliseconds. So naive
# s/ms columns are handed over as `ExactMs`, a ChuiFrames-owned `AbstractDateTime` whose
# encoding is its exact millisecond count; every other unit or zone raises.
"An exact Unix-epoch millisecond count, as handed to Parquet2's writer (ADR-0021 rule 11)."
struct ExactMs <: Dates.AbstractDateTime
    ms::Int64
end
Base.isless(a::ExactMs, b::ExactMs) = isless(a.ms, b.ms)
Base.:(==)(a::ExactMs, b::ExactMs) = a.ms == b.ms
Base.show(io::IO, x::ExactMs) = print(io, "ExactMs(", x.ms, ")")
Parquet2.encodevalue(::Parquet2.ParqDateTime, ::Parquet2.ParqInt64, x::ExactMs) = x.ms

function _exact_ms(n, x::DateTime)
    ms = Int128(Dates.value(x)) - ChuiFrames._UNIX_EPOCH_MS
    typemin(Int64) <= ms <= typemax(Int64) || _ms_range(n, x)
    return ExactMs(Int64(ms))
end
function _exact_ms(n, x::ArrowTimestamp)
    ms = fld(ChuiFrames._instant_ns(x), 1_000_000)
    typemin(Int64) <= ms <= typemax(Int64) || _ms_range(n, x)
    return ExactMs(Int64(ms))
end
_ms_range(n, x) = throw(ArgumentError("column $(repr(n)): timestamp $x does not fit Int64 milliseconds since 1970, which Parquet stores; write the Arrow format instead"))
function _pq_present(n, c::ChuiFrames.PrimitiveColumn{E, T}) where {E, T <: Union{DateTime, ArrowTimestamp}}
    if T <: ArrowTimestamp && !(timestamp_zone(T) === nothing && timestamp_unit(T) in (Dates.Second, Dates.Millisecond))
        throw(ArgumentError("column $(repr(n)) holds $T values; Parquet2 writes only naive millisecond timestamps, so ChuiFrames does not write µs/ns or zoned timestamps to Parquet (ADR-0021 rule 11). Write the Arrow format to keep them exactly, or convert the column (DateTime.(c.x) floors to milliseconds)"))
    end
    return (Missing <: E ? Union{Missing, ExactMs} : ExactMs)[ismissing(x) ? missing : _exact_ms(n, x) for x in c]
end

function _fw!(st::ParquetSinkState; statistics::Bool)
    st.fw === nothing || return st.fw
    st.fw = Parquet2.FileWriter(st.io, st.sink.path; compute_statistics = statistics, compression_codec = st.sink.compression)
    return st.fw
end

function _write!(st::ParquetSinkState, f::Frame; statistics::Bool)
    cols = map((n, c) -> (check_writable(n, c, "Parquet"); _pq_present(n, c)), f.names, f.columns)
    tbl = NamedTuple{Tuple(f.names)}(Tuple(cols))
    Parquet2.writetable!(_fw!(st; statistics), tbl)
    st.nrows += f.nrow
    return nothing
end

function ChuiFrames.write_partition!(st::ParquetSinkState, part)
    st.done && throw(ArgumentError("the Parquet sink is already closed"))
    f = conform_partition(part, st.schema)
    if f.nrow == 0
        # Parquet2 cannot compute statistics on an empty row group, and an empty partition adds
        # no rows; its columns are still checked.
        foreach((n, c) -> (check_writable(n, c, "Parquet"); _pq_present(n, c)), f.names, f.columns)
        return nothing
    end
    return _write!(st, f; statistics = true)
end

function ChuiFrames.close_sink!(st::ParquetSinkState)
    st.done && return nothing
    try
        # No rows at all: one empty row group, without statistics, carries the schema.
        st.fw === nothing && _write!(st, empty_frame(st.schema); statistics = false)
        Parquet2.finalize!(st.fw)
        close(st.io)
        mv(st.tmp, st.sink.path; force = true)
    catch err
        ChuiFrames.abort_sink!(st, err)
        rethrow()
    end
    st.done = true
    return nothing
end

function ChuiFrames.abort_sink!(st::ParquetSinkState, err)
    st.done && return nothing
    st.done = true
    st.io === nothing || ChuiFrames._tryclose(st.io)
    ChuiFrames._tryrm(st.tmp)
    return nothing
end

function __init__()
    ChuiFrames.register_format!(:parquet; source = ParquetSource, sink = ParquetSink, extensions = [".parquet"])
    return nothing
end

end # module ChuiFramesParquet2Ext
