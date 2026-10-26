# The hash join (phase-4 spec docs/superpowers/specs/2026-10-26-phase4-joins-groupby-codegen-design.md
# §1.2; ADR-0003 rules 4, 8, 10, 11; the user's ★ K2). Join lane.
#
# One physical operator, eager and lazy, in three shapes:
#   (a) broadcast, build y: `ProbeStep(:y)` streams x (pairs come out in (x row, y row) order);
#   (b) broadcast, build x: `ProbeStep(:x)` streams y, `JoinTailStep(:x)` restores the order;
#   (c) partitioned: `PartitionedJoinStep`, both sides radix-partitioned (`radix_partition`).
# This file: the shared types, the cost stage, key conversion, the build table, the sort and the
# x-side pass, and the eager entry point; the shapes themselves are in join_shapes.jl (included
# at the end). The key machinery (typed keys, `keyhash`, `KeyTable`, `radix_partition`, the key-pair rule) is
# the group-by lane's (src/engine/hashagg.jl, src/engine/radix.jl; ADR-0003 rule 10).

# ---------------------------------------------------------------------------------------------
# Types shared by the verbs (verbs_join.jl), the engine and the lazy plan (src/lazy/joins.jl).

"""
    JoinStep

A join verb's value (spec §1.1): `kind` is one of `:inner`, `:left`, `:right`, `:full`,
`:semi`, `:anti`, `:nest`, `:cross`; `y` is a `Frame`, a `LazyFrame` or a `Source` (any other
Tables.jl table is converted once with `Frame(y)`); `by` holds the key pairs `x => y`
(`nothing`: a natural join on the common names). Built by [`inner_join`](@ref) and the other
join verbs.

When a side of a lazy join has no static schema, its names are resolved when the query is
collected, and the natural-join message (`@info "Joining with by = [...]"`) is logged then.
"""
struct JoinStep <: Step
    kind::Symbol
    y::Any
    by::Union{Nothing, Vector{Pair{Symbol, Symbol}}}
    suffix::Tuple{String, String}
    na_matches::Symbol
    keep::Bool
    multiple::Symbol
    unmatched::Symbol
    name::Symbol
end

"""
    JoinNames

The resolved names of a join (spec §1.4): the key pairs (`x => y`), whether `by` was `nothing`,
both sides' column names, and every output column with its source: `outside[j]` is `:x`
(x's column `outsrc[j]`), `:y` (y's column), `:key` (the merged key of the pair whose x name
is `outsrc[j]`, under `keep = false`) or `:nest` (the nested column). `xclash`/`yclash` are the
columns renamed by a suffix. `compare` holds each pair's compare type when both sides' key
types are static, else `nothing`.
"""
struct JoinNames
    pairs::Vector{Pair{Symbol, Symbol}}
    natural::Bool
    xnames::Vector{Symbol}
    ynames::Vector{Symbol}
    outnames::Vector{Symbol}
    outside::Vector{Symbol}
    outsrc::Vector{Symbol}
    xclash::Vector{Symbol}
    yclash::Vector{Symbol}
    compare::Union{Nothing, Vector{Type}}
end

_withcompare(n::JoinNames, T::Union{Nothing, Vector{Type}}) =
    JoinNames(n.pairs, n.natural, n.xnames, n.ynames, n.outnames, n.outside, n.outsrc, n.xclash, n.yclash, T)

_xkeys(n::JoinNames) = Symbol[p.first for p in n.pairs]
_ykeys(n::JoinNames) = Symbol[p.second for p in n.pairs]

# ---------------------------------------------------------------------------------------------
# Constants and the forcing switch (spec §0.3, §1.2)

"Broadcast only when the build side has fewer rows than this (ADR-0003 rule 11; p4-bench recalibrates)."
const BROADCAST_MAX_ROWS = 131_072
"Broadcast only when the build side has fewer estimated input bytes than this (ADR-0003 rule 11)."
const BROADCAST_MAX_BYTES = 4 * 1024 * 1024

"""
Test switch (spec §0.3): `:auto` (default), `:broadcast_x`, `:broadcast_y`, `:partitioned_x` or
`:partitioned_y` forces the strategy and the build side of every keyed join. Read once per join
decision (eager apply, the lowering at `collect`, `explain`). Set it only through `withforce`.
"""
const _FORCE_JOIN = Ref{Symbol}(:auto)

const _HIDDEN_PREFIX = "##chui_"
const _YROW = Symbol("##chui_yrow")
const _XROW = Symbol("##chui_xrow")
const _YSTART = Symbol("##chui_ystart")
const _XKEY = Symbol("##chui_xkey")
const _YKEY = Symbol("##chui_ykey")

_ishidden(n::Symbol) = startswith(String(n), _HIDDEN_PREFIX)

# ---------------------------------------------------------------------------------------------
# The cost stage: build side and strategy (spec §1.2; ADR-0003 rule 4)

"""
    SideEstimate(rows, exact, coltypes)

What the cost stage knows about one side of a join: `rows` (`nothing`: unknown; else a count,
an upper bound when not `exact`) and the element types of the columns the join reads from that
side (`nothing` when they are not static).
"""
struct SideEstimate
    rows::Union{Nothing, Int}
    exact::Bool
    coltypes::Union{Nothing, Vector{Type}}
end

# A nominal width per element type (UNVERIFIED heuristic; p4-bench recalibrates): `sizeof` of a
# bits type, 16 bytes otherwise; nested elements (frames, vectors, named tuples) have none.
function _nominal_width(E::Type)
    T = nonmissingtype(E)
    (T <: Frame || T <: AbstractVector || T <: NamedTuple) && return nothing
    return isbitstype(T) ? sizeof(T) : 16
end

"Estimated input bytes of a side, or `nothing` when unknown."
function _estimated_bytes(e::SideEstimate)
    (e.rows === nothing || e.coltypes === nothing) && return nothing
    w = 0
    for T in e.coltypes
        x = _nominal_width(T)
        x === nothing && return nothing
        w += x
    end
    return e.rows * w
end

_broadcast_ok(rows::Int, bytes::Union{Nothing, Int}) =
    rows < BROADCAST_MAX_ROWS && bytes !== nothing && bytes < BROADCAST_MAX_BYTES

# Partition bits from the larger side's rows: 2^4 partitions up to ~2^17 rows, up to 2^8.
_partition_bits(rows::Union{Nothing, Int}) = rows === nothing ? 4 : clamp(ceil(Int, log2(max(rows, 1))) - 13, 4, 8)

"""
    join_decision(spec::JoinStep, x::SideEstimate, y::SideEstimate) -> (strategy, build, p, why)

The cost stage of a keyed join (spec §1.2, ADR-0003 rules 4 and 11):

1. `_FORCE_JOIN[] != :auto`: that strategy and build side.
2. The build side is the one with fewer estimated bytes (rows times a nominal width per column
   read); a tie → y. A side with unknown rows, column types or bytes counts as larger; both
   unknown → y.
3. `:broadcast` when the build side has fewer than `BROADCAST_MAX_ROWS` rows and fewer than
   `BROADCAST_MAX_BYTES` estimated bytes, else `:partitioned` into `2^p` partitions, `p` in 4–8
   from the larger side's rows.

At `collect` the build side is collected first and the strategy is confirmed on its collected
size; `explain` prints this prediction.
"""
function join_decision(spec::JoinStep, x::SideEstimate, y::SideEstimate)
    bx, by = _estimated_bytes(x), _estimated_bytes(y)
    larger = (x.rows === nothing || y.rows === nothing) ? nothing : max(x.rows, y.rows)
    p = _partition_bits(larger)
    f = _FORCE_JOIN[]
    if f !== :auto
        f in (:broadcast_x, :broadcast_y, :partitioned_x, :partitioned_y) ||
            throw(ArgumentError("_FORCE_JOIN must be :auto, :broadcast_x, :broadcast_y, :partitioned_x or :partitioned_y, got $(repr(f))"))
        s = String(f)
        return (Symbol(first(split(s, '_'))), Symbol(last(split(s, '_'))), p, "forced by _FORCE_JOIN")
    end
    build = if bx === nothing && by === nothing
        :y
    elseif by === nothing
        :x
    elseif bx === nothing
        :y
    else
        bx < by ? :x : :y
    end
    e, b = build === :x ? (x, bx) : (y, by)
    if e.rows !== nothing && _broadcast_ok(e.rows, b)
        return (:broadcast, build, p, "the build side ($(build)) is below the broadcast limits")
    end
    why = e.rows === nothing || b === nothing ? "the build side's size is unknown" : "the build side ($(build)) is above the broadcast limits"
    return (:partitioned, build, p, why)
end

"`SideEstimate` of a frame read whole: exact rows and its column types."
_frame_estimate(f::Frame) = SideEstimate(f.nrow, true, Type[eltype(c) for c in f.columns])

# ---------------------------------------------------------------------------------------------
# Key types: the pair rule (critic N1, ★ K4) and the conversion to the compare type

"""
    _join_compare_types(names, xtypes, ytypes) -> Vector{Type}

Each key pair's compare type from the two sides' key element types (spec §1.1): an
`ArgumentError` naming both columns for a pair the key-pair rule rejects
(`_keypair_allowed`, or `_keypair_compare_type` returning `nothing`), or for an abstract key
element type (n6). Identical non-missing types compare as themselves; every other allowed pair
as `_keypair_compare_type(Sx, Sy)`.
"""
function _join_compare_types(names::JoinNames, xtypes::Vector{Type}, ytypes::Vector{Type})
    out = Type[]
    for (j, p) in enumerate(names.pairs)
        Tx, Ty = xtypes[j], ytypes[j]
        _keyable(Tx) || Tx === Missing ||
            throw(ArgumentError("join: x's key column `$(p.first)` has the abstract element type $Tx; convert it to a concrete type first (e.g. mutate(:$(p.first) => identity.(c.$(p.first))))"))
        _keyable(Ty) || Ty === Missing ||
            throw(ArgumentError("join: y's key column `$(p.second)` has the abstract element type $Ty; convert it to a concrete type first"))
        Sx, Sy = nonmissingtype(Tx), nonmissingtype(Ty)
        rejected = ArgumentError("join: x's key `$(p.first)` (element type $Tx) and y's key `$(p.second)` (element type $Ty) cannot be compared; convert one of them first")
        _keypair_allowed(Sx, Sy) || throw(rejected)
        T = Sx === Sy ? Sx : _keypair_compare_type(Sx, Sy)   # `nothing`: a rejected pair
        T === nothing && throw(rejected)
        push!(out, T)
    end
    return out
end
_join_compare_types(names::JoinNames, x::Frame, y::Frame) = _join_compare_types(
    names, Type[eltype(getcol(x, k)) for k in _xkeys(names)], Type[eltype(getcol(y, k)) for k in _ykeys(names)]
)

# Does a key column of element type E need converting to the compare type T? Strings never
# (their hashes agree across string types), an all-missing column only towards a real type.
_needsconv(E::Type, T::Type) = !(T <: AbstractString) && T !== Union{} && nonmissingtype(E) !== T

"The key column converted to the compare type `T` (`missing` stays `missing`), or itself."
_convkey(col::AbstractVector, T::Type) = _needsconv(eltype(col), T) ? _convvec(col, T) : col
function _convvec(col::AbstractVector{E}, ::Type{T}) where {E, T}
    out = Missing <: E ? Vector{Union{Missing, T}}(undef, length(col)) : Vector{T}(undef, length(col))
    return _convfill!(out, col)
end
function _convfill!(out::Vector{O}, col::AbstractVector) where {O}
    T = nonmissingtype(O)
    @inbounds for (o, i) in zip(eachindex(out), eachindex(col))
        x = col[i]
        out[o] = ismissing(x) ? missing : convert(T, x)
    end
    return out
end

_convkeys(f::Frame, keys::Vector{Symbol}, T::Vector{Type}) =
    AbstractVector[_convkey(getcol(f, k), T[j]) for (j, k) in enumerate(keys)]

"Typed keys of the converted key columns, or an `ArgumentError` naming the column (n6)."
function _join_typed_keys(conv::Vector{AbstractVector}, n::Int, names::Vector{Symbol})
    tk = typed_keys(conv, n; codes = false)
    tk === nothing || return tk
    j = something(findfirst(c -> !_keyable(eltype(c)), conv), 1)
    throw(ArgumentError("join: the key column `$(names[j])` has the abstract element type $(eltype(conv[j])); convert it to a concrete type first"))
end

"Rows whose key holds `missing` or NaN in any key column (`na_matches = :never`)."
function _nullkeys(conv::Vector{AbstractVector}, n::Int)
    null = falses(n)
    for c in conv
        _marknull!(null, c)
    end
    return null
end
function _marknull!(null::BitVector, c::AbstractVector{E}) where {E}
    (Missing <: E || nonmissingtype(E) <: AbstractFloat) || return null
    @inbounds for (o, i) in zip(eachindex(null), eachindex(c))
        x = c[i]
        (ismissing(x) || (x isa AbstractFloat && isnan(x))) && (null[o] = true)
    end
    return null
end

# ---------------------------------------------------------------------------------------------
# The build table: a KeyTable over one side's keys with row chains in that side's row order

"""
    JoinBuild

A built side (spec §1.2): its frame, its key columns converted to the compare types, the
`KeyTable` of its keys, `first[id]` (the first row with key `id`), `next[row]` (the next row
with the same key, `0` at the end; rows ascending, so chains are in row order) and `ids[row]`
(the row's key id, `0` for a `missing`/NaN key under `na_matches = :never`).
"""
struct JoinBuild{K}
    frame::Frame
    conv::Vector{AbstractVector}
    T::Vector{Type}
    table::KeyTable{K}
    first::Vector{Int}
    next::Vector{Int}
    ids::Vector{Int}
end

function JoinBuild(frame::Frame, keys::Vector{Symbol}, T::Vector{Type}, never::Bool)
    n = frame.nrow
    conv = _convkeys(frame, keys, T)
    tk = _join_typed_keys(conv, n, keys)
    null = never ? _nullkeys(conv, n) : nothing
    return _build_table(frame, conv, T, tk, null)
end
function _build_table(frame::Frame, conv::Vector{AbstractVector}, T::Vector{Type}, tk::AbstractVector{K}, null::Union{Nothing, BitVector}) where {K}
    n = length(tk)
    t = KeyTable{K}(n)
    first = Int[]
    last = Int[]
    next = zeros(Int, n)
    ids = zeros(Int, n)
    @inbounds for r in 1:n
        null !== nothing && null[r] && continue
        k = tk[r]
        id = getorinsert!(t, k, keyhash(k))
        if id > length(first)
            push!(first, r)
            push!(last, r)
        else
            next[last[id]] = r
            last[id] = r
        end
        ids[r] = id
    end
    return JoinBuild{K}(frame, conv, T, t, first, next, ids)
end

"The (probe row, build row) pairs: probe rows ascending, each one's build rows in build order."
function _probe_pairs(b::JoinBuild, pk::AbstractVector, null::Union{Nothing, BitVector})
    pp = Int[]
    pb = Int[]
    _probe_loop!(pp, pb, b.table, b.first, b.next, pk, null)
    return pp, pb
end
function _probe_loop!(pp::Vector{Int}, pb::Vector{Int}, t::KeyTable, first::Vector{Int}, next::Vector{Int}, pk::AbstractVector, null::Union{Nothing, BitVector})
    @inbounds for i in eachindex(pk)
        null !== nothing && null[i] && continue
        k = pk[i]
        id = lookup(t, k, keyhash(k))
        id == 0 && continue
        r = first[id]
        while r != 0
            push!(pp, i)
            push!(pb, r)
            r = next[r]
        end
    end
    return pp
end

"The key id of each probe row in the build table (`0`: no match)."
function _probe_ids(b::JoinBuild, pk::AbstractVector, null::Union{Nothing, BitVector})
    ids = zeros(Int, length(pk))
    _probe_ids!(ids, b.table, pk, null)
    return ids
end
function _probe_ids!(ids::Vector{Int}, t::KeyTable, pk::AbstractVector, null::Union{Nothing, BitVector})
    @inbounds for i in eachindex(pk)
        null !== nothing && null[i] && continue
        k = pk[i]
        ids[i] = lookup(t, k, keyhash(k))
    end
    return ids
end

# ---------------------------------------------------------------------------------------------
# The order-restoring sort and the x-side pass (spec §1.2, ★ K2, critic pass 3 MAJOR-3)

"""
    _sort_by_x(px, nx) -> perm

A stable counting sort of pairs by x row (`1:nx`): a histogram over `nx` buckets, prefix sums,
scatter. O(m + nx). Pairs of one x row keep their order (y order in every shape).
"""
function _sort_by_x(px::Vector{Int}, nx::Int)
    counts = zeros(Int, nx + 1)
    @inbounds for x in px
        counts[x + 1] += 1
    end
    @inbounds for i in 2:(nx + 1)
        counts[i] += counts[i - 1]
    end
    perm = Vector{Int}(undef, length(px))
    @inbounds for (g, x) in enumerate(px)
        q = counts[x] + 1
        perm[q] = g
        counts[x] = q
    end
    return perm
end

_x_unmatched_error(i::Int) =
    ArgumentError("Each row of `x` must have a match in `y`. Row $i of `x` does not have a match.")
_x_multiple_error(i::Int) =
    ArgumentError("Each row in `x` must match at most 1 row in `y`. Row $i of `x` matches multiple rows in `y`.")
_y_unmatched_error(i::Int) =
    ArgumentError("Each row of `y` must be matched by `x`. Row $i of `y` was not matched.")

"""
    _xpass(px, py, nx, s) -> (cx, cy)

One ascending pass over x's rows `1:nx` with the pairs `(px, py)` sorted by x row (spec §1.2):
for each x row, first the x-side checks (no match under an x-side `unmatched = :error`, more
than one match under `multiple = :error`; the first failing row raises), then `multiple` picks
its y rows. Left and full joins keep an unmatched x row with `0`.
"""
function _xpass(px::Vector{Int}, py::Vector{Int}, nx::Int, s::JoinStep)
    xerr = s.unmatched === :error && (s.kind === :inner || s.kind === :right)
    keepx = s.kind === :left || s.kind === :full
    return _xpass(px, py, nx, xerr, keepx, s.multiple)
end
function _xpass(px::Vector{Int}, py::Vector{Int}, nx::Int, xerr::Bool, keepx::Bool, multiple::Symbol)
    cx = Int[]
    cy = Int[]
    sizehint!(cx, length(px))
    sizehint!(cy, length(px))
    m = length(px)
    j = 1
    @inbounds for i in 1:nx
        a = j
        while j <= m && px[j] == i
            j += 1
        end
        cnt = j - a
        if cnt == 0
            xerr && throw(_x_unmatched_error(i))
            keepx && (push!(cx, i); push!(cy, 0))
        else
            cnt > 1 && multiple === :error && throw(_x_multiple_error(i))
            if multiple === :first || multiple === :any
                push!(cx, i)
                push!(cy, py[a])
            elseif multiple === :last
                push!(cx, i)
                push!(cy, py[j - 1])
            else
                for k in a:(j - 1)
                    push!(cx, i)
                    push!(cy, py[k])
                end
            end
        end
    end
    return cx, cy
end

# ---------------------------------------------------------------------------------------------
# Eager: the same shapes on whole frames, the probe side as one morsel (spec §1.2 "Eager")

"""
    _join_frames(s, names, x, y) -> Frame

Run a join on two frames: the compare types and checks from their column types, the cost
stage's decision from exact sizes (`join_decision`), then the chosen shape. Used by the eager
verbs and by the replay of lazy plans (`reference`), which recompute the compare types from
their own frames.
"""
function _join_frames(s::JoinStep, names::JoinNames, x::Frame, y::Frame)
    y = _ungrouped(y)
    s.kind === :cross && return _cross(s, names, x, y)
    T = _join_compare_types(names, x, y)
    strategy, build, p, _ = join_decision(s, _frame_estimate(x), _frame_estimate(y))
    never = s.na_matches === :never
    if strategy === :broadcast
        if build === :y
            b = JoinBuild(y, _ykeys(names), T, never)
            tail = _needs_ytail(s)
            out = apply(ProbeStep(:y, b, s, names, tail), x)
            return tail ? apply(JoinTailStep(:y, b, s, names), out) : out
        else
            b = JoinBuild(x, _xkeys(names), T, never)
            return apply(JoinTailStep(:x, b, s, names), apply(ProbeStep(:x, b, s, names, true), y))
        end
    end
    return _partitioned_join(s, names, x, y, T, build, p, true)
end

# The output assembly and the physical steps (ProbeStep, JoinTailStep, PartitionedJoinStep).
include("join_shapes.jl")
