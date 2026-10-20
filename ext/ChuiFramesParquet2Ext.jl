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
    pushed_columns, temp_path_for, empty_frame
using DataAPI: DataAPI
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
    # columns whose timestamps are finer than milliseconds, with their unit name
    subms::Dict{Symbol, String}
end
function ParquetSource(src::Union{AbstractString, Vector{UInt8}}; kw...)
    ds = Parquet2.Dataset(src; kw...)
    sch = Tables.schema(ds)
    names = collect(Symbol, sch.names)
    types = Type[_pq_eltype(T) for T in sch.types]
    label = src isa AbstractString ? "Parquet $(basename(src))" : "Parquet ($(length(src)) bytes)"
    return ParquetSource(label, ds, names, Tables.Schema(names, types), _subms_columns(ds, names))
end

# Parquet2 decodes µs/ns timestamps to `DateTime`, silently truncating them to milliseconds.
# ADR-0001 rule 6 defers sub-millisecond timestamps to the `ArrowTimestamp` ADR, so such a
# column raises when read (as the Arrow reader and CSV do) and gives no statistics, instead of
# producing truncated values or bounds (review M1, 2026-10-20). The unit is the column's
# `ParqDateTime` exponent (-3 = ms, -6 = µs, -9 = ns; checked on a pyarrow 26 file).
function _subms_columns(ds::Parquet2.Dataset, names::Vector{Symbol})
    out = Dict{Symbol, String}()
    length(ds) == 0 && return out
    rg = ds[1]
    for n in names
        t = rg[String(n)].type
        if t isa Parquet2.ParqDateTime && t.exponent < -3
            out[n] = t.exponent == -6 ? "MICROSECOND" : t.exponent == -9 ? "NANOSECOND" : "10^$(t.exponent) s"
        end
    end
    return out
end
function _check_subms(s::ParquetSource, n::Symbol)
    u = get(s.subms, n, nothing)
    u === nothing && return nothing
    throw(ArgumentError("Parquet: column $(repr(n)) holds Timestamp($u) values, which ChuiFrames does not read yet (ADR-0001 rule 6: sub-millisecond timestamps wait for the ArrowTimestamp ADR); Parquet2 would truncate them to milliseconds"))
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
    foreach(n -> _check_subms(s, n), names)
    for n in names
        j = findfirst(==(n), s.names)::Int
        push!(out, conform_column(n, Parquet2.load(rg, String(n)), types[j]))
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
    haskey(s.subms, col) && return nothing   # truncated bounds would prune wrongly (review M1)
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
