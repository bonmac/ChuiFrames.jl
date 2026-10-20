# The eager frame: named columns of equal length, plus grouping (ADR-0003 rule 3), and its
# Tables.jl interface (CF-001).

"""
    GroupIndex

The materialized grouping of a frame (ADR-0003 rule 3): `ids[r]` is the dense group id of row
`r`; groups are numbered in ascending key order (CF-008's `isless` order, ADR-0003 rule 8);
`perm[starts[g]:starts[g+1]-1]` are group `g`'s rows in row order; `keys` holds one column per
grouping column with the key values of each group (`length(keys[k]) == ngroups`).
"""
struct GroupIndex
    ids::Vector{Int}
    perm::Vector{Int}
    starts::Vector{Int}
    keys::Vector{AbstractColumn}
end
ngroups(g::GroupIndex) = length(g.starts) - 1
group_rows(g::GroupIndex, k::Int) = view(g.perm, g.starts[k]:(g.starts[k + 1] - 1))

"""
    Frame(; name = vector, ...)
    Frame(table)

ChuiFrames' eager frame: an immutable, ordered set of named [`AbstractColumn`](@ref)s of equal
length, optionally grouped. `Frame(table)` converts any Tables.jl source (CF-001); keyword
arguments build one from vectors. Column element types come from the input's declared types
(ADR-0001 rule 1).
"""
struct Frame
    names::Vector{Symbol}
    columns::Vector{AbstractColumn}
    lookup::Dict{Symbol, Int}
    nrow::Int
    groups::Vector{Symbol}
    gindex::Union{Nothing, GroupIndex}
    function Frame(names::Vector{Symbol}, columns::Vector{AbstractColumn}, groups::Vector{Symbol} = Symbol[], gindex::Union{Nothing, GroupIndex} = nothing, nrow::Int = -1)
        length(names) == length(columns) || throw(ArgumentError("$(length(names)) names for $(length(columns)) columns"))
        lookup = Dict{Symbol, Int}()
        for (i, n) in enumerate(names)
            haskey(lookup, n) && throw(ArgumentError("duplicate column name $(repr(n))"))
            lookup[n] = i
        end
        # `nrow` is needed only for a zero-column frame that still has rows (dplyr's `select()`).
        n = isempty(columns) ? max(nrow, 0) : length(columns[1])
        nrow >= 0 && nrow != n && throw(DimensionMismatch("nrow = $nrow but the columns have $n rows"))
        for (nm, c) in zip(names, columns)
            length(c) == n || throw(DimensionMismatch("column $(repr(nm)) has length $(length(c)), expected $n"))
        end
        for g in groups
            haskey(lookup, g) || throw(ArgumentError("grouping column $(repr(g)) is not a column"))
        end
        isempty(groups) && gindex !== nothing && throw(ArgumentError("a group index needs grouping columns"))
        return new(names, columns, lookup, n, groups, gindex)
    end
end

Frame(; kw...) = Frame(collect(Symbol, keys(kw)), AbstractColumn[column(_asvector(v)) for v in values(kw)])
Frame(f::Frame) = f
function Frame(table)
    Tables.istable(table) || throw(ArgumentError("$(typeof(table)) is not a Tables.jl table"))
    cols = Tables.columns(table)
    names = collect(Symbol, Tables.columnnames(cols))
    columns = AbstractColumn[column(_asvector(Tables.getcolumn(cols, n))) for n in names]
    return Frame(names, columns)
end
_asvector(v::AbstractVector) = v
_asvector(v) = throw(ArgumentError("a frame column must be an AbstractVector, got $(typeof(v))"))

"""
    groupcols(f) -> Vector{Symbol}

The grouping columns of a frame, in order (none for an ungrouped frame or a plain Tables.jl
source; `chui-frames.md` Definitions).
"""
groupcols(f::Frame) = copy(f.groups)
groupcols(t) = (Tables.istable(t) || throw(ArgumentError("$(typeof(t)) is not a table")); Symbol[])

"`isgrouped(f)`: `true` when the frame has grouping columns."
isgrouped(f::Frame) = !isempty(f.groups)

nrows(f::Frame) = f.nrow
ncols(f::Frame) = length(f.names)
columnnames(f::Frame) = copy(f.names)
hascolumn(f::Frame, n::Symbol) = haskey(f.lookup, n)
function getcol(f::Frame, n::Symbol)
    i = get(f.lookup, n, 0)
    i == 0 && throw(ArgumentError("no column $(repr(n)); columns are $(join(repr.(f.names), ", "))"))
    return @inbounds f.columns[i]
end
getcol(f::Frame, i::Int) = f.columns[i]

"Rebuild a frame with new columns, keeping the grouping when all grouping columns survive."
function with_columns(f::Frame, names::Vector{Symbol}, columns::Vector{AbstractColumn}; groups = f.groups, gindex = nothing)
    g = Symbol[x for x in groups if x in names]
    return Frame(names, columns, g, length(g) == length(groups) && g == f.groups ? gindex : nothing)
end

# ---------------------------------------------------------------------------------------------
# Tables.jl (CF-001): a frame is a column table.

Tables.istable(::Type{Frame}) = true
Tables.columnaccess(::Type{Frame}) = true
Tables.columns(f::Frame) = f
Tables.columnnames(f::Frame) = f.names
Tables.getcolumn(f::Frame, n::Symbol) = getcol(f, n)
Tables.getcolumn(f::Frame, i::Int) = f.columns[i]
Tables.getcolumn(f::Frame, ::Type{T}, i::Int, ::Symbol) where {T} = f.columns[i]
Tables.schema(f::Frame) = Tables.Schema(f.names, Type[eltype(c) for c in f.columns])
Tables.rowaccess(::Type{Frame}) = false

DataAPI.nrow(f::Frame) = f.nrow
DataAPI.ncol(f::Frame) = length(f.names)

Base.propertynames(f::Frame) = copy(getfield(f, :names))

"""
    frame_equal(a, b) -> Bool

Frame equality from `chui-frames.md` Definitions: equal column tables (by `isequal`) and
equal grouping columns.
"""
frame_equal(a, b) =
    isequal(Tables.columntable(a), Tables.columntable(b)) && isequal(groupcols(a), groupcols(b))

# ---------------------------------------------------------------------------------------------
# Row selection on a whole frame (ungrouped helpers shared by verbs and I/O).

"`take(f::Frame, idx)`: the rows `idx` of every column; grouping columns are kept, the index dropped."
take(f::Frame, idx::AbstractVector{<:Integer}) =
    Frame(copy(f.names), AbstractColumn[take(c, idx) for c in f.columns], copy(f.groups), nothing, length(idx))

"`vcat_frames(fs)`: concatenate frames with identical column names, in order."
function vcat_frames(fs::AbstractVector{Frame})
    isempty(fs) && throw(ArgumentError("vcat_frames needs at least one frame"))
    names = fs[1].names
    for f in fs
        f.names == names || throw(ArgumentError("cannot concatenate frames with columns $(f.names) and $names"))
    end
    cols = AbstractColumn[vcat_columns([f.columns[j] for f in fs]) for j in eachindex(names)]
    return Frame(copy(names), cols)
end
