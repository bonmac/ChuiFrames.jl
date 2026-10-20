# Column selection (ADR-0002 rule 7): a selector chooses columns, never rows. Forms: a Symbol, a
# string, a vector of them, a Regex, a name predicate (any Function applied to the name string),
# `where(T)`/`where(pred)` on element types, DataAPI's `Cols`/`Between`/`All`, InvertedIndices'
# `Not`, integer positions, and the helpers below.

"Supertype of ChuiFrames' own selector helpers."
abstract type Selector end

"`where(T)` selects columns whose element type is `<: T`; `where(pred)` those with `pred(eltype)`."
struct Where{T} <: Selector
    pred::T
end
where(T::Type) = Where{Type}(T)
where(f) = Where(f)

"`everything()`: every column."
struct Everything <: Selector end
everything() = Everything()

"`last_col(offset = 0)`: the last column, or the one `offset` before it."
struct LastCol <: Selector
    offset::Int
end
last_col(offset::Integer = 0) = LastCol(Int(offset))

"`any_of(names)`: the named columns that exist; absent names are ignored."
struct AnyOf <: Selector
    names::Vector{Symbol}
end
any_of(names) = AnyOf(Symbol[Symbol(n) for n in names])
any_of(names::Union{Symbol, AbstractString}) = AnyOf([Symbol(names)])

"`group_cols()`: the grouping columns."
struct GroupColsSel <: Selector end
group_cols() = GroupColsSel()

"A selector built by `c[sel]`."
struct ColSet{S} <: Selector
    sel::S
end
Base.getindex(::ColumnRefs, sel) = ColSet(sel)

# `each(f)` is not a Function, so it is never taken for a name predicate (ADR-0002 rule 8).
"`each(f)`: apply `f` elementwise inside `across`: `across(where(Number), each(round))`."
struct Each{F}
    f::F
end
each(f) = Each(f)
(e::Each)(x::Node) = Broadcast.broadcasted(e.f, x)
Base.show(io::IO, e::Each) = print(io, "each(", _fname(e.f), ")")

_selrepr(x) = repr(x)
_selrepr(x::Function) = _fname(x)
_selrepr(::Everything) = "everything()"
_selrepr(x::LastCol) = x.offset == 0 ? "last_col()" : "last_col($(x.offset))"
_selrepr(x::AnyOf) = "any_of($(repr(x.names)))"
_selrepr(::GroupColsSel) = "group_cols()"
_selrepr(x::Where) = "where($(_selrepr(x.pred)))"
_selrepr(x::ColSet) = "c[$(_selrepr(x.sel))]"
Base.show(io::IO, s::Selector) = print(io, _selrepr(s))

"""
    SelectCtx

What a selector is resolved against: the column names, their declared element types, and the
grouping columns.
"""
struct SelectCtx
    names::Vector{Symbol}
    types::Vector{Type}
    groups::Vector{Symbol}
end
SelectCtx(f::Frame) = SelectCtx(f.names, Type[eltype(col) for col in f.columns], f.groups)

_pos(ctx, s::Symbol) = (
    i = findfirst(==(s), ctx.names);
    i === nothing ? throw(ArgumentError("no column $(repr(s)); columns are $(join(repr.(ctx.names), ", "))")) : i
)

"""
    resolve(sel, ctx) -> Vector{Int}

The positions `sel` selects, in selection order, without duplicates.
"""
resolve(sel, ctx::SelectCtx) = unique!(_resolve(sel, ctx))
resolve(sel, f::Frame) = resolve(sel, SelectCtx(f))

_resolve(s::Symbol, ctx) = [_pos(ctx, s)]
_resolve(s::AbstractString, ctx) = [_pos(ctx, Symbol(s))]
_resolve(s::Col, ctx) = [_pos(ctx, s.name)]
function _resolve(i::Integer, ctx)
    1 <= i <= length(ctx.names) || throw(ArgumentError("column position $i out of range 1:$(length(ctx.names))"))
    return [Int(i)]
end
_resolve(v::AbstractVector, ctx) = isempty(v) ? Int[] : reduce(vcat, [_resolve(x, ctx) for x in v])
_resolve(t::Tuple, ctx) = isempty(t) ? Int[] : reduce(vcat, [_resolve(x, ctx) for x in t])
_resolve(r::Regex, ctx) = [i for (i, n) in enumerate(ctx.names) if occursin(r, string(n))]
_resolve(f::Function, ctx) = [i for (i, n) in enumerate(ctx.names) if f(string(n)) === true]
_resolve(::Each, ctx) = throw(ArgumentError("each(f) is a function wrapper for across, not a selector"))
function _resolve(w::Where, ctx)
    return if w.pred isa Type
        [i for (i, T) in enumerate(ctx.types) if T <: w.pred || nonmissingtype(T) <: w.pred]
    else
        [i for (i, T) in enumerate(ctx.types) if w.pred(T) === true]
    end
end
_resolve(::Everything, ctx) = collect(1:length(ctx.names))
_resolve(::DataAPI.All, ctx) = collect(1:length(ctx.names))
function _resolve(l::LastCol, ctx)
    i = length(ctx.names) - l.offset
    i >= 1 || throw(ArgumentError("last_col($(l.offset)) is out of range for $(length(ctx.names)) columns"))
    return [i]
end
_resolve(a::AnyOf, ctx) = [i for n in a.names for i in something(findfirst(==(n), ctx.names), Int[])]
_resolve(::GroupColsSel, ctx) = [_pos(ctx, g) for g in ctx.groups]
_resolve(s::ColSet, ctx) = _resolve(s.sel, ctx)
function _resolve(s::DataAPI.Cols, ctx)
    isempty(s.cols) && return Int[]
    parts = [unique!(_resolve(x, ctx)) for x in s.cols]
    return s.operator === intersect ? reduce(intersect, parts) : reduce(vcat, parts)
end
function _resolve(b::DataAPI.Between, ctx)
    i, j = first(_resolve(b.first, ctx)), first(_resolve(b.last, ctx))
    return i <= j ? collect(i:j) : collect(j:i)
end
function _resolve(n::InvertedIndices.InvertedIndex, ctx)
    drop = Set(_resolve(n.skip, ctx))
    return [i for i in 1:length(ctx.names) if !(i in drop)]
end
_resolve(x, ctx) = throw(ArgumentError("$(repr(x)) is not a column selector"))

"Is `x` a selector rather than a single column or an expression?"
_isselector(x) = x isa Union{Selector, Regex, Function, AbstractVector, DataAPI.Cols, DataAPI.Between, DataAPI.All, InvertedIndices.InvertedIndex}
