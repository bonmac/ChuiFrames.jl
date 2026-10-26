# Combining tables: bind_rows, bind_cols and the set verbs (key equality: ADR-0003 rule 8).

# bind_rows, bind_cols and the set verbs

struct BindRowsStep <: Step
    others::Vector{Any}
    id::Union{Nothing, Symbol}
end
"""
    bind_rows(tables...; id = nothing)

Applied to `t`: the rows of `t`, then of each table, matching columns by name (columns missing
from a table are filled with `missing`). `id = :src` adds a first column with the table number
(1 for `t`), or the names when tables are given as `"name" => table`. Keeps `t`'s grouping.
"""
bind_rows(others...; id = nothing) = BindRowsStep(Any[others...], id === nothing ? nothing : Symbol(id))
"`union_all(y)`: all rows of the input, then of `y` (dplyr's `union_all`)."
union_all(y) = BindRowsStep(Any[y], nothing)
Base.show(io::IO, s::BindRowsStep) = print(io, "bind_rows(…", length(s.others), " table(s))")

function _bind(frames::Vector{Frame}, ids, idname)
    names = Symbol[]
    for f in frames, n in f.names
        n in names || push!(names, n)
    end
    cols = AbstractColumn[]
    for n in names
        parts = AbstractColumn[hascolumn(f, n) ? getcol(f, n) : column(Vector{Missing}(missing, f.nrow)) for f in frames]
        push!(cols, _vcat_nonempty(parts))
    end
    if idname !== nothing
        # The vector form preallocates (element type: promote_type of the ids', as the fold
        # gave); `init` would fold left, quadratic in the tables (P4-02).
        idv = reduce(vcat, [fill(ids[k], frames[k].nrow) for k in eachindex(frames)])
        pushfirst!(names, idname)
        pushfirst!(cols, column(idv))
    end
    return names, cols
end
# vcat that ignores the element type of empty parts (a zero-row Missing column does not make the
# result nullable).
function _vcat_nonempty(parts::Vector{AbstractColumn})
    ne = [p for p in parts if length(p) > 0]
    isempty(ne) && return parts[1]
    length(ne) == 1 && return ne[1]
    return vcat_columns(ne)
end
function apply(s::BindRowsStep, f::Frame)
    frames = Frame[f]
    ids = Any[1]
    for (k, o) in enumerate(s.others)
        if o isa Pair
            push!(frames, _asframe(o.second))
            push!(ids, string(o.first))
        else
            push!(frames, _asframe(o))
            push!(ids, k + 1)
        end
    end
    any(o -> o isa Pair, s.others) && (ids[1] = "1")
    names, cols = _bind(frames, [x for x in ids], s.id)
    out = Frame(names, cols, Symbol[], nothing, sum(fr.nrow for fr in frames))
    g = [x for x in f.groups if x in names]
    return isempty(g) ? out : regroup(out, g; drop = f.drop)
end

struct BindColsStep <: Step
    others::Vector{Any}
end
"`bind_cols(tables...)`: the columns of the input, then of each table (equal row counts; duplicate names are repaired as dplyr does, `x...1`)."
bind_cols(others...) = BindColsStep(Any[others...])
Base.show(io::IO, s::BindColsStep) = print(io, "bind_cols(…", length(s.others), " table(s))")
function apply(s::BindColsStep, f::Frame)
    frames = Frame[f; [_asframe(o) for o in s.others]]
    for fr in frames
        fr.nrow == f.nrow || throw(DimensionMismatch("bind_cols: tables have $(f.nrow) and $(fr.nrow) rows"))
    end
    names = Symbol[n for fr in frames for n in fr.names]
    cols = AbstractColumn[x for fr in frames for x in fr.columns]
    dup = Set(n for n in names if count(==(n), names) > 1)
    names = [n in dup ? Symbol(n, "...", i) : n for (i, n) in enumerate(names)]
    return Frame(names, cols, Symbol[g for g in f.groups if g in names], nothing, f.nrow, f.drop)
end

struct SetStep <: Step
    kind::Symbol
    y::Any
end
"`union_rows(y)`: the distinct rows of the input and `y` (input rows first). Key equality: ADR-0003 rule 8."
union_rows(y) = SetStep(:union, y)
"`intersect_rows(y)`: the distinct rows of the input that also occur in `y`."
intersect_rows(y) = SetStep(:intersect, y)
"`setdiff_rows(y)`: the distinct rows of the input that do not occur in `y`."
setdiff_rows(y) = SetStep(:setdiff, y)
"`symdiff_rows(y)`: the distinct rows in exactly one of the input and `y` (input rows first)."
symdiff_rows(y) = SetStep(:symdiff, y)
Base.show(io::IO, s::SetStep) = print(io, s.kind, "_rows(…)")
function apply(s::SetStep, x::Frame)
    y = _asframe(s.y)
    Set(x.names) == Set(y.names) && length(x.names) == length(y.names) ||
        throw(ArgumentError("$(s.kind)_rows: the tables must have the same columns; got $(x.names) and $(y.names)"))
    y = Frame(copy(x.names), AbstractColumn[getcol(y, n) for n in x.names])
    xu = Frame(copy(x.names), copy(x.columns))
    names, cols = _bind(Frame[xu, y], [1, 2], nothing)
    both = Frame(names, cols)
    codes, _ = rowcodes(AbstractVector[getcol(both, n) for n in names])
    nx = x.nrow
    inx = Set(codes[1:nx])
    iny = Set(codes[(nx + 1):end])
    seen = Set{Int}()
    keep = Int[]
    for (r, k) in enumerate(codes)
        k in seen && continue
        fromx = r <= nx
        ok = s.kind === :union ? true :
            s.kind === :intersect ? (fromx && k in iny) :
            s.kind === :setdiff ? (fromx && !(k in iny)) :
            (fromx ? !(k in iny) : !(k in inx))
        if ok
            push!(keep, r)
            push!(seen, k)
        end
    end
    out = take(both, keep)
    g = x.groups
    return isempty(g) ? out : regroup(out, copy(g); drop = x.drop)
end
