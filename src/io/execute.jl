# The eager executor of phase 2: plan a source, read its partitions in order, apply the
# residual `Tables.Scan` to each, and apply the global offset/limit (ADR-0004 rules 1-3, CF-012).
# And the write driver: any source into a sink, aborting on any exception (rule 7, CF-014).

"The default morsel size (rows) passed to `plan_partitions` by the eager executor."
const DEFAULT_MORSEL = 65_536

_is_all_select(sel) = length(sel) == 1 && only(sel).ref isa DataAPI.All &&
    only(sel).type === nothing && only(sel).rename === nothing
_is_identity(s::Tables.Scan) = s.filter === nothing && s.limit === nothing && s.offset == 0 &&
    _is_all_select(s.select)

_as_frame(t::Frame) = t
_as_frame(t) = Frame(t)

"""
    apply_scan(t, scan::Tables.Scan) -> Frame

Apply `scan` to one table with `Tables.Scan`'s semantics (filter, then offset/limit, then
projection with renames and type overrides). Column kinds are kept (a dictionary column stays
one); an identity request returns the table as a frame.
"""
function apply_scan(t, scan::Tables.Scan)
    f = _as_frame(t)
    _is_identity(scan) && return f
    b = Tables.resolve(scan, f.names)
    idx = b.filter === nothing ? (1:f.nrow) : findall(Tables.filtermask(b, f))
    skipped = min(b.offset, length(idx))
    taken = b.limit === nothing ? length(idx) - skipped : min(b.limit, length(idx) - skipped)
    rows = idx[(skipped + 1):(skipped + taken)]
    g = rows == 1:f.nrow ? f : take(f, rows)
    names = Symbol[c.name for c in b.columns]
    cols = AbstractColumn[_override(getcol(g, c.index), c.type) for c in b.columns]
    return Frame(names, cols, Symbol[], nothing, length(rows))
end

_override(c::AbstractColumn, ::Nothing) = c
function _override(c::AbstractColumn, ::Type{T}) where {T}
    eltype(c) !== Union{} && eltype(c) <: Union{T, Missing} && return c
    E = any(ismissing, c) ? Union{T, Missing} : T
    return column(E[ismissing(x) ? missing : convert(T, x) for x in c])
end

"""
    conform_types(part, schema::Tables.Schema) -> Frame

The partition `part` as a frame whose columns that `schema` declares have the declared element
types ([`conform_column`](@ref); an `ArgumentError` when a value cannot be converted exactly).
Columns already of the declared type, and columns `schema` does not name, are kept as they are.
Both the eager source reader and the lazy engine read partitions through it, so every partition
reaches the verbs with the declared types (a source's partitions may differ, e.g. `Int` in one
and `Float64` in another), and lazy and eager see the same types (CF-008).
"""
function conform_types(part, sch::Tables.Schema)
    f = _as_frame(part)
    sch.types === nothing && return f
    names = sch.names
    types = sch.types
    cols = nothing
    for (j, n) in enumerate(f.names)
        i = findfirst(==(n), names)
        i === nothing && continue
        E = types[i]
        c = f.columns[j]
        eltype(c) === E && continue
        cols === nothing && (cols = copy(f.columns))
        cols[j] = conform_column(n, c, E)
    end
    cols === nothing && return f
    return Frame(copy(f.names), cols, copy(f.groups), nothing, f.nrow, f.drop)
end

"The element types of a schema as a vector (`Tables.Schema.types` may be `nothing`)."
function schema_types(sch::Tables.Schema)
    ts = sch.types
    ts === nothing && throw(ArgumentError("a schema without element types cannot be declared"))
    return Type[T for T in ts]
end

"An empty frame with the declared schema `sch`."
function empty_frame(sch::Tables.Schema)
    names = collect(Symbol, sch.names)
    cols = AbstractColumn[column(Vector{T}()) for T in schema_types(sch)]
    return Frame(names, cols)
end

_concat(fs::Vector{Frame}) =
    isempty(first(fs).names) ? Frame(Symbol[], AbstractColumn[], Symbol[], nothing, sum(f -> f.nrow, fs)) :
    vcat_frames(fs)

const _SOURCE_LOCKS = WeakKeyDict{Any, ReentrantLock}()
const _SOURCE_LOCKS_LOCK = ReentrantLock()

# One lock per source object for sources that are not thread-safe (ADR-0004 rule 10). Sources
# that are not mutable cannot be weak keys, so they share one global lock.
const _IMMUTABLE_SOURCE_LOCK = ReentrantLock()
function source_lock(s)
    ismutable(s) || return _IMMUTABLE_SOURCE_LOCK
    return lock(_SOURCE_LOCKS_LOCK) do
        get!(ReentrantLock, _SOURCE_LOCKS, s)
    end
end

function _read(s, p)
    isthreadsafe(s) && return read_partition(s, p)
    return lock(() -> read_partition(s, p), source_lock(s))
end

"""
    read_source(s::Source; scan = Tables.Scan(), morsel = DEFAULT_MORSEL) -> Frame

Read a source eagerly. The request is pushed to `plan_partitions` with `offset = 0` and a
per-partition limit of `offset + limit` (ADR-0004 rule 3). Each partition gets the residual,
then the global offset and limit are applied in partition order.
"""
function read_source(s::Source; scan::Tables.Scan = Tables.Scan(), morsel::Integer = DEFAULT_MORSEL)
    k, n = scan.offset, scan.limit
    pushed = Tables.Scan(scan; offset = 0, limit = n === nothing ? nothing : k + n)
    handles, residual = plan_partitions(s, pushed; morsel = Int(morsel))
    frames = Frame[]
    total = 0
    sch = source_schema(s)
    for p in handles
        f = apply_scan(conform_types(_read(s, p), sch), residual)
        push!(frames, f)
        total += f.nrow
        n !== nothing && total >= k + n && break   # later partitions cannot reach the window
    end
    if isempty(frames)
        push!(frames, apply_scan(empty_frame(source_schema(s)), Tables.Scan(scan; offset = 0, limit = nothing)))
    end
    result = _concat(frames)
    (k == 0 && (n === nothing || result.nrow <= n)) && return result
    lo = min(k, result.nrow) + 1
    hi = n === nothing ? result.nrow : min(k + n, result.nrow)
    return take(result, lo:hi)
end

"""
    write_source(k::Sink, x; schema = nothing, morsel = DEFAULT_MORSEL)

Write `x` (a [`Source`](@ref) or any Tables.jl table) through sink `k`: `open_sink` with the
source's schema (or `schema`), one `write_partition!` per partition in order, `close_sink!`.
On any exception after `open_sink`, `abort_sink!` is called and the exception rethrown.
"""
function write_source(k::Sink, x; schema::Union{Nothing, Tables.Schema} = nothing, morsel::Integer = DEFAULT_MORSEL)
    s = x isa Source ? x : TablesSource(x)
    sch = schema === nothing ? source_schema(s) : schema
    handles, residual = plan_partitions(s, Tables.Scan(); morsel = Int(morsel))
    k = prepare_sink(k, s, handles)
    state = open_sink(k, sch)
    try
        for p in handles
            t = _read(s, p)
            write_partition!(state, _is_identity(residual) ? t : apply_scan(t, residual))
        end
        close_sink!(state)
    catch err
        abort_sink!(state, err)
        rethrow()
    end
    return nothing
end

# A hook for sinks that need to see the data before opening (the Arrow sink unifies the
# dictionaries of an in-memory source up front, ADR-0001 rule 11). Returns the sink to open.
prepare_sink(k::Sink, s, handles) = k
