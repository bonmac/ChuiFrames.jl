# Any Tables.jl input is a Source (ADR-0004 rule 5, CF-011).

"""
    TablesSource(table)

Wrap any `Tables.istable` input as a [`Source`](@ref). Each element of `Tables.partitions(table)`
is one partition. The partition list is snapshotted here, by iterating (never `collect`ing the
input), so planning twice gives the same partitions. Its residual is the whole `Scan`. The
constructor is PROVISIONAL (CF-011).
"""
struct TablesSource <: Source
    parts::Vector{Any}
    schema::Tables.Schema
    label::String
    function TablesSource(table)
        table isa Source && throw(ArgumentError("$(typeof(table)) is already a Source"))
        # A `Tables.partitioner` of tables is the documented way to hand over partitions; it is
        # not itself `istable` unless its elements are rows.
        table isa Tables.Partitioner || Tables.istable(table) ||
            throw(ArgumentError("$(typeof(table)) is not a Tables.jl table"))
        parts = Any[]
        for p in Tables.partitions(table)
            push!(parts, p)
        end
        sch = _merged_schema(table, parts)
        return new(parts, sch, "Tables.jl $(nameof(typeof(table)))")
    end
end

source_schema(s::TablesSource) = s.schema
source_label(s::TablesSource) = s.label
plan_partitions(s::TablesSource, scan::Tables.Scan; morsel::Int = DEFAULT_MORSEL) = (collect(eachindex(s.parts)), scan)
read_partition(s::TablesSource, p::Integer) = s.parts[p]

_part_nrow(p) = Tables.columnaccess(typeof(p)) ? Tables.rowcount(Tables.columns(p)) : nothing
_part_nrow(p::Frame) = p.nrow
function partition_row_count(s::TablesSource, p::Integer)
    n = _part_nrow(s.parts[p])
    return n === nothing ? nothing : (n, true)
end
function row_count(s::TablesSource)
    total = 0
    for p in eachindex(s.parts)
        r = partition_row_count(s, p)
        r === nothing && return nothing
        total += r[1]
    end
    return (total, true)
end

# The declared schema: per column, the element types of every partition's schema merged
# (nullable when any partition is; numeric types promoted). A partition without a schema is
# materialized to find one.
function _merged_schema(table, parts)
    schemas = Tables.Schema[]
    for p in parts
        sch = Tables.schema(Tables.columns(p))
        sch === nothing && (sch = Tables.schema(Frame(p)))
        push!(schemas, sch)
    end
    if isempty(schemas)
        sch = Tables.schema(table)
        sch === nothing && throw(ArgumentError("cannot find the schema of a $(typeof(table)) with no partitions"))
        return sch
    end
    names = collect(Symbol, schemas[1].names)
    types = schema_types(schemas[1])
    for sch in schemas[2:end]
        collect(Symbol, sch.names) == names ||
            throw(ArgumentError("partitions have different columns: $names and $(collect(sch.names))"))
        for (j, t) in enumerate(schema_types(sch))
            types[j] = merge_eltype(types[j], t)
        end
    end
    return Tables.Schema(names, types)
end

"""
    merge_eltype(a, b) -> Type

The declared element type covering partitions of element types `a` and `b`: `Union{Missing,T}`
when either admits `missing`; the same kind keeps `a`'s type; numbers promote.
"""
function merge_eltype(a::Type, b::Type)
    na, nb = nonmissingtype(a), nonmissingtype(b)
    nullable = (a !== na) || (b !== nb)
    T = if na === Union{} || na === Missing
        nb
    elseif nb === Union{} || nb === Missing
        na
    elseif kind_type(na) == kind_type(nb)
        _merge_same(na, nb)
    else
        promote_type(na, nb)
    end
    return nullable ? Union{Missing, T} : T
end

# Same kind: merge nested element types (lists, named tuples) so nested nullability covers both.
function _merge_same(a::Type, b::Type)
    if a <: AbstractVector && b <: AbstractVector && !(a <: AbstractVector{UInt8})
        return Vector{merge_eltype(eltype(a), eltype(b))}
    elseif a <: NamedTuple && b <: NamedTuple && isconcretetype(a) && isconcretetype(b)
        return NamedTuple{fieldnames(a), Tuple{map(merge_eltype, fieldtypes(a), fieldtypes(b))...}}
    end
    return a
end
