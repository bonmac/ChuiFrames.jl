# Arrow IPC: the writer adapter over Arrow.jl (ADR-0010 rule 2, ADR-0001 rule 11) and the source
# over ChuiFrames' own reader (sub-lane p2-ipc, ADR-0001 rule 10).
#
# Every Arrow.jl call goes through `ArrowSink`. Its rules:
# - every partition is converted to ONE declared schema (`conform_partition`), and its Arrow
#   layout signature is checked against the first partition's, because Arrow.jl fixes the
#   schema from the first partition and corrupts silently on a mismatch;
# - Utf8/LargeUtf8 is chosen up front (`large`); a partition that would need large offsets in a
#   small-offset file raises instead of letting Arrow.jl widen per partition;
# - dictionary columns are presented with 1-based `refarray` and the FULL unified dictionary
#   as `refpool` in every partition (so no delta dictionaries are written); a column whose
#   unified dictionary is not known when the sink opens is decoded;
# - binary elements are presented as `Base.CodeUnits` (a `SubArray{UInt8}` would be list<uint8>);
# - the file format is the default, the stream format for `.arrows` and append;
# - the write goes to a temporary path in the same directory, renamed on close, deleted on abort.

# ---------------------------------------------------------------------------------------------
# Presentation wrappers: what Arrow.jl sees. Each is a ChuiFrames-owned AbstractVector.

const _CodeUnitsView = Base.CodeUnits{UInt8, StrView}

"Binary column elements as `Base.CodeUnits` over the column's bytes (no copy)."
struct ArrowBinary{E, C <: BinaryColumn} <: AbstractVector{E}
    c::C
end
ArrowBinary(c::BinaryColumn) = ArrowBinary{isnullable(c) ? Union{Missing, _CodeUnitsView} : _CodeUnitsView, typeof(c)}(c)
Base.size(x::ArrowBinary) = size(x.c)
Base.IndexStyle(::Type{<:ArrowBinary}) = IndexLinear()
@inline function Base.getindex(x::ArrowBinary, i::Int)
    v = x.c[i]
    return v === missing ? missing : Base.CodeUnits(StringView(v))
end

"A dictionary column as Arrow.jl's writer expects: 1-based `refarray`, the full pool as `refpool`."
struct ArrowDict{E, R <: Unsigned, P <: AbstractVector} <: AbstractVector{E}
    codes::Vector{R}
    pool::P
end
Base.size(x::ArrowDict) = size(x.codes)
Base.IndexStyle(::Type{<:ArrowDict}) = IndexLinear()
@inline function Base.getindex(x::ArrowDict{E}, i::Int) where {E}
    k = x.codes[i]
    return k == 0 ? (missing::E) : x.pool[Int(k)]::E
end
DataAPI.refarray(x::ArrowDict) = x.codes
DataAPI.refpool(x::ArrowDict) = x.pool

"A list column whose elements are views of the presented child."
struct ArrowList{E, O, C <: AbstractVector, V} <: AbstractVector{E}
    offsets::Vector{O}
    child::C
    validity::V
end
Base.size(x::ArrowList) = (length(x.offsets) - 1,)
Base.IndexStyle(::Type{<:ArrowList}) = IndexLinear()
@inline function Base.getindex(x::ArrowList{E}, i::Int) where {E}
    _isvalid(x.validity, i) || return missing::E
    return view(x.child, (Int(x.offsets[i]) + 1):Int(x.offsets[i + 1]))
end

"A struct column whose elements are named tuples of the presented children's elements."
struct ArrowStruct{E, C <: NamedTuple, V} <: AbstractVector{E}
    children::C
    n::Int
    validity::V
end
Base.size(x::ArrowStruct) = (x.n,)
Base.IndexStyle(::Type{<:ArrowStruct}) = IndexLinear()
@inline function Base.getindex(x::ArrowStruct{E}, i::Int) where {E}
    _isvalid(x.validity, i) || return missing::E
    return map(ch -> ch[i], x.children)
end

"""
String elements as `String`s. Used for the string children of a struct: for a null parent,
Arrow.jl's struct writer substitutes `ArrowTypes.default(T)`, a `String`, which cannot be
converted to a `StrView`.
"""
struct ArrowStrings{E, C <: StringColumn} <: AbstractVector{E}
    c::C
end
ArrowStrings(c::StringColumn) = ArrowStrings{isnullable(c) ? Union{Missing, String} : String, typeof(c)}(c)
Base.size(x::ArrowStrings) = size(x.c)
Base.IndexStyle(::Type{<:ArrowStrings}) = IndexLinear()
@inline Base.getindex(x::ArrowStrings, i::Int) = (v = x.c[i]; v === missing ? missing : String(v))

_struct_child(ch::DictColumn) = _struct_child(_decode(ch))
_struct_child(ch::StringColumn) = ArrowStrings(ch)
_struct_child(ch::AbstractColumn) = arrow_present(ch)

_plain_pool(d::StringColumn) = String[String(_dict_value(x)) for x in d]
_dict_value(::Missing) = throw(ArgumentError("a dictionary must not hold missing values"))
_dict_value(x) = x
_plain_pool(d::AbstractColumn) = collect(nonmissingtype(eltype(d)), d)

_decode(c::DictColumn) = column(collect(eltype(c), c))

"""
`Date`/`DateTime` elements as Arrow.jl's own storage values (`Arrow.DATE`, Date32;
`Arrow.DATETIME`, Timestamp(ms) with no zone). Handing Arrow.jl `Dates.Date`/`Dates.DateTime`
makes it tag the field with its `JuliaLang.Date`/`JuliaLang.DateTime` extension type, which
ChuiFrames' own reader rejects (ADR-0001 rule 6) and other readers ignore; the storage
values give the plain Arrow types.
"""
struct ArrowTemporal{E, A, C <: PrimitiveColumn} <: AbstractVector{E}
    c::C
end
_arrow_temporal(::Type{Date}) = Arrow.DATE
_arrow_temporal(::Type{DateTime}) = Arrow.DATETIME
function ArrowTemporal(c::PrimitiveColumn{E, T}) where {E, T}
    A = _arrow_temporal(T)
    return ArrowTemporal{isnullable(c) ? Union{Missing, A} : A, A, typeof(c)}(c)
end
Base.size(x::ArrowTemporal) = size(x.c)
Base.IndexStyle(::Type{<:ArrowTemporal}) = IndexLinear()
@inline Base.getindex(x::ArrowTemporal{E, A}, i::Int) where {E, A} =
    (v = x.c[i]; v === missing ? missing : convert(A, v))

arrow_present(c::PrimitiveColumn{E, T}) where {E, T <: Union{Date, DateTime}} = ArrowTemporal(c)
arrow_present(c::Union{PrimitiveColumn, BoolColumn}) = isnullable(c) ? c : c.values
arrow_present(c::StringColumn) = c
arrow_present(c::BinaryColumn) = ArrowBinary(c)
# A nullable dictionary column gets a pool with `missing` appended, and its null slots point
# at that entry. Arrow.jl takes the field's nullability from the pool's element type, and in
# every partition after the first it re-encodes by value, so a `missing` absent from the pool
# would be written as a delta dictionary (pyarrow probe, test/io/arrow_tests.jl).
_arrow_pool(d::AbstractColumn, nullable::Bool) =
    nullable ? Union{Missing, nonmissingtype(eltype(_plain_pool(d)))}[_plain_pool(d); missing] : _plain_pool(d)
function arrow_present(c::DictColumn, pool = _arrow_pool(c.dict, isnullable(c)))
    E = eltype(pool)
    if isnullable(c)
        R = length(pool) <= typemax(UInt8) ? UInt8 : length(pool) <= typemax(UInt16) ? UInt16 : UInt32
        nullcode = R(length(pool))
        codes = R[k == 0 ? nullcode : R(k) for k in c.codes]
        return ArrowDict{E, R, typeof(pool)}(codes, pool)
    end
    return ArrowDict{E, eltype(c.codes), typeof(pool)}(c.codes, pool)
end
function arrow_present(c::ListColumn)
    ch = c.child isa DictColumn ? arrow_present(_decode(c.child)) : arrow_present(c.child)
    T = SubArray{eltype(ch), 1, typeof(ch), Tuple{UnitRange{Int64}}, true}
    E = isnullable(c) ? Union{Missing, T} : T
    return ArrowList{E, eltype(c.offsets), typeof(ch), typeof(c.validity)}(c.offsets, ch, c.validity)
end
function arrow_present(c::StructColumn)
    chs = map(_struct_child, c.children)
    T = NamedTuple{keys(chs), Tuple{map(eltype, values(chs))...}}
    E = isnullable(c) ? Union{Missing, T} : T
    return ArrowStruct{E, typeof(chs), typeof(c.validity)}(chs, length(c), c.validity)
end

"The Arrow layout of a column, compared across partitions (kind, value type, nullability, children)."
arrow_sig(c::PrimitiveColumn{E, T}) where {E, T} = (:primitive, T, isnullable(c))
arrow_sig(c::BoolColumn) = (:bool, isnullable(c))
arrow_sig(c::StringColumn) = (:utf8, isnullable(c))
arrow_sig(c::BinaryColumn) = (:binary, isnullable(c))
arrow_sig(c::DictColumn) = (:dictionary, arrow_sig(c.dict), isnullable(c))
arrow_sig(c::ListColumn) = (:list, c.child isa DictColumn ? arrow_sig(c.child.dict) : arrow_sig(c.child), isnullable(c))
arrow_sig(c::StructColumn) = (:struct, keys(c.children), map(ch -> ch isa DictColumn ? arrow_sig(ch.dict) : arrow_sig(ch), values(c.children)), isnullable(c))

_needs_large(c::VarColumn) = last(c.offsets) > typemax(Int32)
_needs_large(c::ListColumn) = last(c.offsets) > typemax(Int32) || _needs_large(c.child)
_needs_large(c::StructColumn) = any(_needs_large, values(c.children))
_needs_large(c::DictColumn) = _needs_large(c.dict)
_needs_large(::AbstractColumn) = false

# ---------------------------------------------------------------------------------------------
# Atomic file commit helpers, shared by the built-in file sinks.

function temp_path_for(path::AbstractString)
    dir = dirname(abspath(path))
    isdir(dir) || throw(ArgumentError("directory $(repr(dir)) does not exist"))
    return tempname(dir; cleanup = false) * ".tmp"
end
_tryclose(::Nothing) = nothing
_tryclose(x) = try
    close(x)
catch
    nothing
end
_tryrm(p) = try
    p === nothing || rm(p; force = true)
catch
    nothing
end

# ---------------------------------------------------------------------------------------------
# The sink.

"""
    ArrowSink(path; format = :auto, append = false, compress = nothing, large = false,
              dictionaries = nothing)

The built-in Arrow IPC sink (ADR-0010). `format = :auto` writes the **file** format, except for
`.arrows` paths, which get the **stream** format; `:file` and `:stream` force one.
`append = true` appends to an existing stream-format file through `Arrow.append`; that is
**not atomic** (a failure can leave a partly appended file). `compress` is `:lz4` or `:zstd`.
`large = true` writes LargeUtf8/LargeBinary/LargeList offsets (needed when a column passes 2³¹−1
bytes). `dictionaries` maps column names to their unified dictionaries; a dictionary column not
in it is decoded (ADR-0001 rule 11). `write_file` unifies the dictionaries of in-memory input
itself.
"""
struct ArrowSink <: Sink
    path::String
    stream::Bool
    append::Bool
    compress::Union{Nothing, Symbol}
    large::Bool
    dictionaries::Union{Nothing, Dict{Symbol, AbstractColumn}}
end
function ArrowSink(path::AbstractString; format::Symbol = :auto, append::Bool = false, compress::Union{Nothing, Symbol} = nothing, large::Bool = false, dictionaries = nothing)
    format in (:auto, :file, :stream) || throw(ArgumentError("Arrow format must be :auto, :file or :stream, got $(repr(format))"))
    stream = format === :stream || (format === :auto && (append || lowercase(splitext(path)[2]) == ".arrows"))
    append && !stream && throw(ArgumentError("append needs the Arrow stream format (format = :stream or a .arrows path)"))
    compress in (nothing, :lz4, :zstd) || throw(ArgumentError("compress must be nothing, :lz4 or :zstd, got $(repr(compress))"))
    dicts = dictionaries === nothing ? nothing : Dict{Symbol, AbstractColumn}(Symbol(k) => column(v) for (k, v) in pairs(dictionaries))
    return ArrowSink(String(path), stream, append, compress, large, dicts)
end

mutable struct ArrowSinkState
    sink::ArrowSink
    schema::Tables.Schema
    tmp::Union{Nothing, String}
    io::Union{Nothing, IOStream}
    writer::Any
    sigs::Union{Nothing, Vector{Any}}
    pools::Dict{Symbol, Any}
    lookups::Dict{Symbol, Dict{Any, Int}}
    nwritten::Int
    done::Bool
end

function open_sink(k::ArrowSink, schema::Tables.Schema)
    st = ArrowSinkState(k, schema, nothing, nothing, nothing, nothing, Dict{Symbol, Any}(), Dict{Symbol, Dict{Any, Int}}(), 0, false)
    k.append && isfile(k.path) && return st     # appended in place, partition by partition
    tmp = temp_path_for(k.path)
    st.tmp = tmp
    try
        st.io = open(tmp, "w")
        st.writer = open(Arrow.Writer, st.io; file = !k.stream, largelists = k.large, compress = k.compress)
    catch
        st.io === nothing || _tryclose(st.io)
        _tryrm(tmp)
        rethrow()
    end
    return st
end

function _remap_codes(st::ArrowSinkState, name::Symbol, c::DictColumn, u::AbstractColumn)
    c.dict === u && return c
    lookup = get!(st.lookups, name) do
        Dict{Any, Int}(x => i for (i, x) in enumerate(u))
    end
    m = Vector{Int}(undef, length(c.dict))
    for (j, x) in enumerate(c.dict)
        m[j] = get(() -> throw(ArgumentError("column $(repr(name)): value $(repr(x)) is not in the declared dictionary")), lookup, x)
    end
    C = length(u) <= typemax(UInt8) ? UInt8 : length(u) <= typemax(UInt16) ? UInt16 : UInt32
    codes = C[k == 0 ? 0 : m[k] for k in c.codes]
    return DictColumn(codes, u, c.validity)
end

function _prepare_dict(st::ArrowSinkState, name::Symbol, c::AbstractColumn)
    dicts = st.sink.dictionaries
    u = dicts === nothing ? nothing : get(dicts, name, nothing)
    if u === nothing
        return c isa DictColumn ? _decode(c) : c
    elseif c isa DictColumn
        return _remap_codes(st, name, c, u)
    else                                         # plain values of a dictionary column: encode
        lookup = get!(() -> Dict{Any, Int}(x => i for (i, x) in enumerate(u)), st.lookups, name)
        C = length(u) <= typemax(UInt8) ? UInt8 : length(u) <= typemax(UInt16) ? UInt16 : UInt32
        codes = C[ismissing(x) ? 0 : get(() -> throw(ArgumentError("column $(repr(name)): value $(repr(x)) is not in the declared dictionary")), lookup, x) for x in c]
        return DictColumn(codes, u, validity(c))
    end
end

function write_partition!(st::ArrowSinkState, part)
    st.done && throw(ArgumentError("the Arrow sink is already closed"))
    f = conform_partition(part, st.schema)
    names = f.names
    cols = Vector{AbstractColumn}(undef, length(names))
    for (j, nm) in enumerate(names)
        c = f.columns[j]
        check_writable(nm, c, "Arrow IPC")
        c = _prepare_dict(st, nm, c)
        !st.sink.large && _needs_large(c) &&
            throw(ArgumentError("column $(repr(nm)) needs 64-bit offsets (over 2^31-1 bytes or elements); write with large = true"))
        cols[j] = c
    end
    sigs = Any[arrow_sig(c) for c in cols]
    first_sigs = st.sigs
    if first_sigs === nothing
        st.sigs = sigs
    else
        for (j, nm) in enumerate(names)
            sigs[j] == first_sigs[j] ||
                throw(ArgumentError("column $(repr(nm)) has Arrow layout $(sigs[j]) in partition $(st.nwritten + 1), but $(first_sigs[j]) in the first partition"))
        end
    end
    presented = map(enumerate(names)) do (j, nm)
        c = cols[j]
        c isa DictColumn ? arrow_present(c, get!(() -> _arrow_pool(c.dict, isnullable(c)), st.pools, nm)) : arrow_present(c)
    end
    tbl = NamedTuple{Tuple(names)}(Tuple(presented))
    if st.writer === nothing
        Arrow.append(st.sink.path, tbl)
    else
        Arrow.write(st.writer, tbl)
    end
    st.nwritten += 1
    return nothing
end

function close_sink!(st::ArrowSinkState)
    st.done && return nothing
    try
        st.nwritten == 0 && st.writer !== nothing && write_partition!(st, empty_frame(st.schema))
        writer, io, tmp = st.writer, st.io, st.tmp
        if writer !== nothing && io !== nothing && tmp !== nothing
            close(writer)
            close(io)
            mv(tmp, st.sink.path; force = true)
        end
    catch err
        abort_sink!(st, err)
        rethrow()
    end
    st.done = true
    return nothing
end

function abort_sink!(st::ArrowSinkState, err)
    st.done && return nothing
    st.done = true
    st.writer === nothing || _tryclose(st.writer)
    st.io === nothing || _tryclose(st.io)
    _tryrm(st.tmp)
    return nothing
end

# Unify the dictionaries of an in-memory source up front (ADR-0001 rule 11): a column gets a
# declared dictionary when every partition holds it as a dictionary column.
function prepare_sink(k::ArrowSink, s::TablesSource, handles)
    k.dictionaries === nothing || return k
    found = Dict{Symbol, Vector{AbstractColumn}}()
    plain = Set{Symbol}()
    for p in handles
        part = s.parts[p]
        part isa Frame || return k
        for (nm, c) in zip(part.names, part.columns)
            if c isa DictColumn
                push!(get!(Vector{AbstractColumn}, found, nm), c.dict)
            else
                push!(plain, nm)
            end
        end
    end
    dicts = Dict{Symbol, AbstractColumn}(nm => unify_dictionaries(ds) for (nm, ds) in found if !(nm in plain))
    return ArrowSink(k.path, k.stream, k.append, k.compress, k.large, dicts)
end

"""
    unify_dictionaries(dicts) -> AbstractColumn

One dictionary holding every value of `dicts`, in order of first appearance (the first
dictionary is returned as is when all are the same object).
"""
function unify_dictionaries(dicts::AbstractVector)
    all(d -> d === dicts[1], dicts) && return dicts[1]
    T = mapreduce(d -> nonmissingtype(eltype(d)), merge_eltype, dicts)
    seen = Set{Any}()
    vals = T[]
    for d in dicts, x in d
        x in seen && continue
        push!(seen, x)
        push!(vals, x)
    end
    return column(vals)
end

# ---------------------------------------------------------------------------------------------
# The source, over the own reader of sub-lane p2-ipc (ADR-0001 rule 10; Arrow.jl's reader is
# never used by src/, ADR-0010 rule 3). The reader's names are looked up at run time.

"""
    ArrowSource(src)

The built-in Arrow IPC source over ChuiFrames' own reader: one partition per record batch.
`src` is a path or a `Vector{UInt8}` (file or stream format). Projection is pushed down.
"""
mutable struct ArrowSource <: Source
    src::Union{String, Vector{UInt8}}
    schema::Tables.Schema
    batches::Union{Nothing, Vector{Frame}}
    lock::ReentrantLock
end
ArrowSource(src::Union{AbstractString, Vector{UInt8}}) =
    ArrowSource(src isa AbstractString ? String(src) : src, ChuiFrames.read_ipc_schema(src), nothing, ReentrantLock())

function _batches(s::ArrowSource)
    return lock(s.lock) do
        s.batches === nothing && (s.batches = ChuiFrames.read_ipc_batches(s.src))
        s.batches
    end
end

source_schema(s::ArrowSource) = s.schema
source_label(s::ArrowSource) = _src_label("Arrow IPC", s.src)
_src_label(kind, src::String) = "$kind $(basename(src))"
_src_label(kind, src::Vector{UInt8}) = "$kind ($(length(src)) bytes)"
function plan_partitions(s::ArrowSource, scan::Tables.Scan; morsel::Int = DEFAULT_MORSEL)
    cols = pushed_columns(scan, s.schema.names)
    return [(k, cols) for k in eachindex(_batches(s))], scan
end
function read_partition(s::ArrowSource, (k, cols))
    b = _batches(s)[k]
    cols === nothing && return b
    return Frame(cols, AbstractColumn[getcol(b, c) for c in cols], Symbol[], nothing, b.nrow)
end
partition_row_count(s::ArrowSource, (k, _)) = (_batches(s)[k].nrow, true)
row_count(s::ArrowSource) = (sum(b -> b.nrow, _batches(s); init = 0), true)

"""
    pushed_columns(scan, names) -> Union{Nothing, Vector{Symbol}}

The source columns a projection pushdown must read for `scan` (its selection and every column
its filter references), in source order; `nothing` to read every column. Pushdown is used only
when every reference is a name, so the whole `scan` stays valid as the residual over the subset.
"""
function pushed_columns(scan::Tables.Scan, names)
    _is_all_select(scan.select) && return nothing
    all(it -> it.ref isa Union{Symbol, String}, scan.select) || return nothing
    scan.filter === nothing || _names_only(scan.filter) || return nothing
    nms = collect(Symbol, names)
    b = Tables.resolve(scan, nms)
    need = sort!(unique!(vcat(Int[c.index for c in b.columns], b.filtercols)))
    return nms[need]
end
_names_only(e::Tables.Col) = e.ref isa Union{Symbol, String}
_names_only(e::AbstractVector) = all(_names_only, e)
_names_only(e::Tables.ScanExpr) = all(f -> _names_only(getfield(e, f)), fieldnames(typeof(e)))
_names_only(_) = true

# ---------------------------------------------------------------------------------------------
# readr/arrow-style conveniences.

"""
    read_arrow(src; kw...) -> Frame

Read an Arrow IPC file or stream (a path or bytes) with ChuiFrames' own reader.
"""
read_arrow(path::AbstractString; kw...) = read_file(path; format = :arrow, kw...)
read_arrow(bytes::Vector{UInt8}) = read_source(ArrowSource(bytes))

"""
    write_arrow(x, path; format = :auto, append = false, compress = nothing, large = false) -> path

Write any Tables.jl table as Arrow IPC: the file format by default, the stream format for
`.arrows` paths, `format = :stream` or `append = true` (see the internal `ChuiFrames.ArrowSink`).
"""
function write_arrow(x, path::AbstractString; kw...)
    write_source(ArrowSink(path; kw...), x)
    return path
end
