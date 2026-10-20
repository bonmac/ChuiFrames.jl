# CSV over CSV.jl 1.x (ADR-0019): a source reading `CSV.Chunks` sequentially as ordered
# partitions, a sink writing one file sequentially, and a readr-style reader API.
#
# - `CSV.Chunks` has no handle access and splits by 64 MiB byte windows, so handles are batch
#   numbers read through one sequential cursor (restarted when a handle goes backwards), and
#   no code assumes a batch count.
# - `CSV.Chunks` rejects `scan=`, so the whole `Tables.Scan` is the residual; projection is
#   pushed through `select`.
# - `pool = false` and `stringtype = String` are always passed; every column becomes a
#   ChuiFrames column. `CSV.Chunks` has no `typemap`, so inferred `Durations.Timestamp`
#   columns are converted to `DateTime` here, exactly or with an `ArgumentError`.

const _CSV_EXTS_TAB = (".tsv", ".tab")
_default_delim(path) = path isa AbstractString && lowercase(splitext(path)[2]) in _CSV_EXTS_TAB ? '\t' : ','

_csv_eltype(::Type{T}) where {T} = (S = nonmissingtype(T); S === T ? _csv_valtype(S) : Union{Missing, _csv_valtype(S)})
_csv_valtype(::Type{T}) where {T} =
    T === Union{} ? Bool :                           # an all-missing column: logical, as readr
    T <: AbstractString ? StrView :
    (T <: Dates.AbstractDateTime && T !== DateTime) ? DateTime :
    T

function _csv_column(name::Symbol, v::AbstractVector, ::Type{E}) where {E}
    S = nonmissingtype(eltype(v))
    if S <: Dates.AbstractDateTime && S !== DateTime && S !== Union{}
        out = Vector{Union{Missing, DateTime}}(undef, length(v))
        for (i, x) in enumerate(v)
            if ismissing(x)
                out[i] = missing
            else
                y = DateTime(x)
                S(y) == x || throw(ArgumentError("column $(repr(name)): timestamp $x has sub-millisecond digits, which DateTime cannot hold; read it with col_types = ($(repr(name)) => String)"))
                out[i] = y
            end
        end
        v = out
    end
    return conform_column(name, v, E)
end

"""
    CSVSource(src; delim, header = 1, skipto = nothing, comment = nothing, missingstring = ["NA"],
              types = nothing, select = nothing, limit = nothing, stripwhitespace = false,
              quotechar = '"', dateformat = nothing, decimal = '.', ntasks = nothing)

The built-in CSV source over `CSV.Chunks` (ADR-0019): `src` is a path or a `Vector{UInt8}`.
The keywords are CSV.jl's (format options are PROVISIONAL); the readr-style API is
[`read_csv`](@ref). One partition per `CSV.Chunks` batch, read sequentially.
"""
mutable struct CSVSource <: Source
    src::Union{String, Vector{UInt8}}
    opts::Dict{Symbol, Any}
    names::Vector{Symbol}
    schema::Tables.Schema
    nbatches::Int
    lock::ReentrantLock
    # the sequential cursor: the Chunks iterator for one projection, its state, and the next
    # batch number it yields
    cur_cols::Any
    cur_chunks::Any
    cur_state::Any
    cur_next::Int
    pending::Any
end

function CSVSource(src::Union{AbstractString, Vector{UInt8}}; delim = _default_delim(src), kw...)
    opts = Dict{Symbol, Any}(pairs(kw))
    opts[:delim] = delim
    opts[:pool] = false
    opts[:stringtype] = String
    for k in (:pool, :stringtype, :scan, :typemap)
        haskey(kw, k) && throw(ArgumentError("CSVSource does not take the `$k` keyword (it is fixed by ChuiFrames)"))
    end
    src′ = src isa AbstractString ? String(src) : src
    chunks = CSV.Chunks(src′; _chunk_kw(opts)...)
    nb = length(chunks)
    names = collect(Symbol, Base.names(chunks))
    # CSV.Chunks settles one schema for every batch but exposes it only through a batch.
    if nb == 0
        f = CSV.File(src′; _chunk_kw(opts)...)
        types = Type[_csv_eltype(eltype(Tables.getcolumn(f, n))) for n in names]
        pending = nothing
    else
        pending = iterate(chunks)
        pending === nothing && throw(ArgumentError("CSV.Chunks reported $nb batches but yielded none"))
        first_batch = pending[1]
        types = Type[_csv_eltype(eltype(Tables.getcolumn(first_batch, n))) for n in names]
    end
    sch = Tables.Schema(names, types)
    return CSVSource(src′, opts, names, sch, nb, ReentrantLock(), nothing, chunks, nothing, 1, pending)
end
_chunk_kw(opts) = (; (k => v for (k, v) in opts if v !== nothing)...)

source_schema(s::CSVSource) = s.schema
source_label(s::CSVSource) = _src_label("CSV", s.src)
function plan_partitions(s::CSVSource, scan::Tables.Scan; morsel::Int = DEFAULT_MORSEL)
    cols = pushed_columns(scan, s.names)
    return [(k, cols) for k in 1:s.nbatches], scan
end

# Read batch k for projection cols through the sequential cursor.
function _csv_batch(s::CSVSource, k::Int, cols)
    return lock(s.lock) do
        if !isequal(cols, s.cur_cols) || k < s.cur_next
            opts = copy(s.opts)
            cols === nothing || (opts[:select] = cols)
            s.cur_chunks = CSV.Chunks(s.src; _chunk_kw(opts)...)
            s.cur_cols = cols
            s.cur_state = nothing
            s.pending = nothing
            s.cur_next = 1
        end
        batch = nothing
        while s.cur_next <= k
            batch = _csv_next!(s, k)
        end
        batch
    end
end

function _csv_next!(s::CSVSource, k::Int)
    if s.pending !== nothing                   # the first batch, read at construction
        batch, st = s.pending
        s.pending = nothing
    else
        r = s.cur_state === nothing ? iterate(s.cur_chunks) : iterate(s.cur_chunks, s.cur_state)
        r === nothing && throw(ArgumentError("the CSV source has fewer than $k batches"))
        batch, st = r
    end
    s.cur_state = st
    s.cur_next += 1
    return batch
end

function read_partition(s::CSVSource, (k, cols))
    batch = _csv_batch(s, k, cols)
    names = cols === nothing ? s.names : cols
    out = AbstractColumn[]
    types = schema_types(s.schema)
    for n in names
        j = findfirst(==(n), s.names)::Int
        push!(out, _csv_column(n, Tables.getcolumn(batch, n), types[j]))
    end
    return Frame(copy(names), out, Symbol[], nothing, Tables.rowcount(batch))
end

# ---------------------------------------------------------------------------------------------
# The sink: one file, written sequentially (ADR-0004 rule 7), temporary path + rename.

"""
    CSVSink(path; delim = ',' (tab for .tsv), na = "NA", col_names = true, quotechar = '"',
            dateformat = nothing)

The built-in CSV sink: one file, written sequentially, committed atomically. `na` is written for
`missing` (readr's default `"NA"`); an empty string is written quoted (`""`), so it reads back
as an empty string. Object, binary, list and struct columns raise an `ArgumentError`.
"""
struct CSVSink <: Sink
    path::String
    opts::NamedTuple
end
function CSVSink(path::AbstractString; delim = _default_delim(path), na::AbstractString = "NA", col_names::Bool = true, quotechar = '"', dateformat = nothing)
    opts = (; delim, missingstring = String(na), quotechar, col_names)
    dateformat === nothing || (opts = merge(opts, (; dateformat)))
    return CSVSink(String(path), opts)
end

mutable struct CSVSinkState
    sink::CSVSink
    schema::Tables.Schema
    tmp::String
    io::Union{Nothing, IOStream}
    nwritten::Int
    done::Bool
end

function open_sink(k::CSVSink, schema::Tables.Schema)
    tmp = temp_path_for(k.path)
    io = open(tmp, "w")
    return CSVSinkState(k, schema, tmp, io, 0, false)
end

_csv_writable(name, c::Union{BinaryColumn, ListColumn, StructColumn}) =
    throw(ArgumentError("column $(repr(name)) is a $(nameof(typeof(c))), which cannot be written to CSV"))
_csv_writable(name, c::AbstractColumn) = check_writable(name, c, "CSV")

function write_partition!(st::CSVSinkState, part)
    st.done && throw(ArgumentError("the CSV sink is already closed"))
    f = conform_partition(part, st.schema)
    for (n, c) in zip(f.names, f.columns)
        _csv_writable(n, c)
    end
    o = st.sink.opts
    header = o.col_names && st.nwritten == 0
    wkw = (; (k => v for (k, v) in pairs(o) if k !== :col_names)...)
    CSV.write(st.io, f; wkw..., writeheader = header)
    st.nwritten += 1
    return nothing
end

function close_sink!(st::CSVSinkState)
    st.done && return nothing
    try
        st.nwritten == 0 && write_partition!(st, empty_frame(st.schema))
        io = st.io
        io === nothing || close(io)       # a failing flush raises here, before the rename
        st.io = nothing
        mv(st.tmp, st.sink.path; force = true)
    catch err
        abort_sink!(st, err)
        rethrow()
    end
    st.done = true
    return nothing
end

function abort_sink!(st::CSVSinkState, err)
    st.done && return nothing
    st.done = true
    st.io === nothing || _tryclose(st.io)
    _tryrm(st.tmp)
    return nothing
end

# ---------------------------------------------------------------------------------------------
# readr-style reading (ADR-0019 rule 3). Arguments follow readr::read_delim; what CSV.jl cannot
# express is listed in docs/parity (see the read_csv docstring).

const _READR_CODES = Dict{Char, Any}(
    'i' => Int64, 'd' => Float64, 'n' => Float64, 'c' => String, 'l' => Bool, 'D' => Date,
    'T' => DateTime, 'f' => String, '?' => nothing, '_' => :skip, '-' => :skip,
)

# readr's logical spellings (readr::default_locale()), which CSV.jl takes as replacements.
const _READR_TRUE = ["TRUE", "True", "true", "T"]
const _READR_FALSE = ["FALSE", "False", "false", "F"]

_readr_type(T::Type) = T
function _readr_type(c::Char)
    haskey(_READR_CODES, c) || throw(ArgumentError("unknown readr column type code $(repr(c)); use one of $(join(sort(collect(keys(_READR_CODES))), ""))"))
    return _READR_CODES[c]
end
_readr_type(s::AbstractString) = length(s) == 1 ? _readr_type(only(s)) : throw(ArgumentError("a column type code is one character, got $(repr(s))"))
_readr_type(x) = throw(ArgumentError("unsupported column type $(repr(x)); give a Julia type or a readr code character"))

# col_types -> (CSV `types` Dict keyed by name or index, columns to drop)
function _col_types(spec)
    types = Dict{Any, Type}()
    drop = Any[]
    spec === nothing && return types, drop
    items = spec isa AbstractString ? collect(enumerate(collect(spec))) :
        spec isa NamedTuple ? collect(pairs(spec)) :
        spec isa AbstractDict ? collect(spec) :
        spec isa AbstractVector{<:Pair} ? spec :
        spec isa Pair ? [spec] :
        throw(ArgumentError("col_types must be a readr compact string, a NamedTuple, a Dict or Pairs; got $(typeof(spec))"))
    for (k, v) in items
        key = k isa AbstractString ? Symbol(k) : k
        T = _readr_type(v)
        if T === :skip
            push!(drop, key)
        elseif T !== nothing
            types[key] = T
        end
    end
    return types, drop
end

"""
    read_csv(path; col_names = true, col_types = nothing, col_select = nothing,
             na = ["", "NA"], skip = 0, comment = nothing, n_max = nothing, delim = ',',
             trim_ws = true, quotechar = '"') -> Frame
    read_tsv(path; kw...)  # delim = '\\t'

Read a delimited file into a frame, readr-style (ADR-0019 rule 3), over CSV.jl 1.x:

- `col_names`: `true` (first row after `skip`), `false` (`Column1`, ...) or a vector of names;
- `col_types`: a readr compact string (`"icdlDT_?"`: integer, double, character, logical, Date,
  DateTime, skip, guess; `n` = double, `f` = character), or `name => type` pairs, a NamedTuple
  or a Dict whose values are Julia types or code characters;
- `col_select`: the columns to keep (names), pushed into the parser;
- `na`: the strings read as `missing`; `skip`: lines skipped before the header; `comment`: a
  prefix marking comment lines; `n_max`: the maximum number of data rows; `trim_ws`: strip
  surrounding whitespace.

Matching readr: generated names are `X1, X2, ...`; `TRUE/True/true/T` and
`FALSE/False/false/F` are logical; whitespace is trimmed by default.

Divergences from readr, measured against readr 2.1.6 by the `:differential` test in
`test/io/csv_tests.jl` (CSV.jl cannot express them):
- whole-number columns infer as `Int64` (readr guesses double); `i` gives `Int64` (readr: 32-bit);
- numbers with leading zeros (`007`) parse as numbers (readr keeps them as character);
- an unquoted empty field is always `missing`, even when `na` omits `""`;
- `comment` skips lines that start with it; readr also drops trailing comments;
- `f` (factor) reads as strings; there is no `locale`;
- timestamps with sub-millisecond digits raise (`DateTime` holds ms; read them as `String`);
- a time of day (readr `hms`) is an object column of `Dates.Time`.
"""
function read_csv(path::Union{AbstractString, Vector{UInt8}}; col_names = true, col_types = nothing, col_select = nothing, na = ["", "NA"], skip::Integer = 0, comment = nothing, n_max = nothing, delim = _default_delim(path), trim_ws::Bool = true, quotechar = '"')
    return read_source(scan_csv(path; col_names, col_types, col_select, na, skip, comment, n_max, delim, trim_ws, quotechar))
end
read_tsv(path::Union{AbstractString, Vector{UInt8}}; kw...) = read_csv(path; delim = '\t', kw...)

"""
    scan_csv(path; kw...) -> CSVSource

The [`ChuiFrames.CSVSource`](@ref) [`read_csv`](@ref) reads, with the same readr-style keywords.
"""
function scan_csv(path; col_names = true, col_types = nothing, col_select = nothing, na = ["", "NA"], skip::Integer = 0, comment = nothing, n_max = nothing, delim = _default_delim(path), trim_ws::Bool = true, quotechar = '"')
    types, drop = _col_types(col_types)
    header, skipto = if col_names === true
        skip + 1, nothing
    elseif col_names === false
        false, skip + 1
    else
        collect(Symbol, col_names), skip + 1
    end
    missingstring = String[String(x) for x in (na isa AbstractString ? [na] : na) if !isempty(x)]
    select = col_select === nothing ? nothing : collect(Symbol, col_select isa Union{Symbol, AbstractString} ? [col_select] : col_select)
    kw = Dict{Symbol, Any}(
        :header => header, :missingstring => missingstring, :stripwhitespace => trim_ws,
        :quotechar => quotechar, :comment => comment, :limit => n_max === nothing ? nothing : Int(n_max),
        :truestrings => _READR_TRUE, :falsestrings => _READR_FALSE,
    )
    skipto === nothing || (kw[:skipto] = skipto)
    if header === false
        # readr names generated columns X1, X2, ...; CSV.jl says Column1. Learn the count first.
        probe = merge(kw, Dict{Symbol, Any}(:limit => 1))
        n = length(CSVSource(path; delim, probe...).names)
        kw[:header] = [Symbol("X", i) for i in 1:n]
    end
    isempty(types) || (kw[:types] = types)
    if !isempty(drop)
        select === nothing || throw(ArgumentError("give col_select or skip codes in col_types, not both"))
        kw[:drop] = [d isa Symbol ? d : Int(d) for d in drop]
    end
    select === nothing || (kw[:select] = select)
    return CSVSource(path; delim, kw...)
end

"""
    write_csv(x, path; na = "NA", delim = ',', col_names = true) -> path
    write_tsv(x, path; kw...)

Write any Tables.jl table as CSV, readr-style (`na` is written for `missing`), atomically.
"""
write_csv(x, path::AbstractString; na::AbstractString = "NA", delim = ',', col_names::Bool = true) =
    write_file(x, path; format = :csv, na, delim, col_names)
write_tsv(x, path::AbstractString; kw...) = write_csv(x, path; delim = '\t', kw...)
