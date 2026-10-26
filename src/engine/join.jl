# The hash join (phase-4 spec docs/superpowers/specs/2026-10-26-phase4-joins-groupby-codegen-design.md
# §1.2; ADR-0003 rules 4, 8, 10, 11; the user's ★ K2). Join lane.
#
# One physical operator, eager and lazy, in three shapes:
#   (a) broadcast, build y: `ProbeStep(:y)` streams x (pairs come out in (x row, y row) order);
#   (b) broadcast, build x: `ProbeStep(:x)` streams y, `JoinTailStep(:x)` restores the order;
#   (c) partitioned: `PartitionedJoinStep`, both sides radix-partitioned (`radix_partition`).
# The key machinery (typed keys, `keyhash`, `KeyTable`, `radix_partition`, the key-pair rule) is
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
# Output assembly

"`col` with a validity bitmap (a nullable column of the same kind and values)."
_asnullable(c::AbstractColumn) = validity(c) === nothing ? _withvalidity(c, trues(length(c))) : c
_withvalidity(c::PrimitiveColumn, v::BitVector) = PrimitiveColumn(c.values, v)
_withvalidity(c::BoolColumn, v::BitVector) = BoolColumn(c.values, v)
_withvalidity(c::StringColumn, v::BitVector) = StringColumn(c.offsets, c.data, v)
_withvalidity(c::BinaryColumn, v::BitVector) = BinaryColumn(c.offsets, c.data, v)
_withvalidity(c::DictColumn, v::BitVector) = DictColumn(c.codes, c.dict, v)
_withvalidity(c::ListColumn, v::BitVector) = ListColumn(c.offsets, c.child, v)
_withvalidity(c::StructColumn, v::BitVector) = StructColumn(c.children, v; length = length(c))
_withvalidity(c::ObjectColumn, v::BitVector) = ObjectColumn(c.values, v)

_ascolumn(v::AbstractColumn) = v
_ascolumn(v::AbstractVector) = column(v)

"""
The merged key column (keep = false): x's converted value, or y's for a row only in y. For
right/full joins (`merged`) the column is fed by both frames and always built from plain
values (a dictionary is decoded, spec §1.1), whatever the rows, so every shape gives one kind.
"""
function _keycolumn(xc::AbstractVector, yc::Union{Nothing, AbstractVector}, xr::Vector{Int}, yr::Vector{Int}, ynullable::Bool, merged::Bool)
    if !merged
        col = take(_ascolumn(xc), xr)
        return ynullable ? _asnullable(col) : col
    end
    E = yc === nothing ? eltype(xc) : Union{eltype(xc), eltype(yc)}
    v = Vector{ynullable ? Union{Missing, E} : E}(undef, length(xr))
    return column(_fillkeys!(v, xc, yc, xr, yr))
end
function _fillkeys!(v::Vector, xc::AbstractVector, ::Nothing, xr::Vector{Int}, yr::Vector{Int})
    @inbounds for i in eachindex(v)
        v[i] = xc[xr[i]]
    end
    return v
end
function _fillkeys!(v::Vector, xc::AbstractVector, yc::AbstractVector, xr::Vector{Int}, yr::Vector{Int})
    @inbounds for i in eachindex(v)
        v[i] = xr[i] > 0 ? xc[xr[i]] : yc[yr[i]]
    end
    return v
end

"""
    _assemble(s, names, X, xconv, Y, yconv, xr, yr) -> (names, columns)

The output columns of a keyed (or cross) join for the row pairs `(xr[i], yr[i])` (`0`: that
side is missing), in `names`' order. X's columns come from `X`, y's from `Y` (by y's names);
columns absent from `X`/`Y` (projected away) are skipped. Element types are static by kind
(spec §1.1).
"""
function _assemble(s::JoinStep, names::JoinNames, X::Frame, xconv, Y::Frame, yconv, xr::Vector{Int}, yr::Vector{Int})
    xnull = s.kind === :right || s.kind === :full
    ynull = s.kind === :left || s.kind === :full
    xkeys = _xkeys(names)
    outn = Symbol[]
    cols = AbstractColumn[]
    for (j, nm) in enumerate(names.outnames)
        side, src = names.outside[j], names.outsrc[j]
        if side === :x
            hascolumn(X, src) || continue
            col = take(getcol(X, src), xr)
            xnull && (col = _asnullable(col))
        elseif side === :y
            hascolumn(Y, src) || continue
            col = take(getcol(Y, src), yr)
            ynull && (col = _asnullable(col))
        else  # :key
            p = findfirst(==(src), xkeys)::Int
            ynullable = Missing <: eltype(getcol(Y, names.pairs[p].second))
            col = _keycolumn(xconv[p], yconv === nothing ? nothing : yconv[p], xr, yr, ynullable, xnull)
        end
        push!(outn, nm)
        push!(cols, col)
    end
    return outn, cols
end

"The y frame of a nested element: y's non-key columns (keep = false) or all of them, ungrouped."
function _nest_source(s::JoinStep, names::JoinNames, Y::Frame)
    ykeys = _ykeys(names)
    ns = Symbol[n for n in names.ynames if (s.keep || !(n in ykeys)) && hascolumn(Y, n)]
    return Frame(ns, AbstractColumn[getcol(Y, n) for n in ns], Symbol[], nothing, Y.nrow)
end

"""
The output of a nest join: x's columns (the key converted under `keep = false`) and one column
of `Frame`s, one per x row, holding the `Y` rows `runs[i]` (y order).
"""
function _assemble_nest(s::JoinStep, names::JoinNames, X::Frame, xconv, Y::Frame, runs::Vector{Vector{Int}})
    ysub = _nest_source(s, names, Y)
    nested = ObjectColumn(Frame[take(ysub, r) for r in runs])
    xr = collect(1:X.nrow)
    xkeys = _xkeys(names)
    outn = Symbol[]
    cols = AbstractColumn[]
    for (j, nm) in enumerate(names.outnames)
        side, src = names.outside[j], names.outsrc[j]
        if side === :x
            hascolumn(X, src) || continue
            push!(cols, getcol(X, src))
        elseif side === :key
            p = findfirst(==(src), xkeys)::Int
            ynullable = Missing <: eltype(getcol(Y, names.pairs[p].second))
            push!(cols, _keycolumn(xconv[p], nothing, xr, xr, ynullable, false))
        elseif side === :nest
            push!(cols, nested)
        else
            continue
        end
        push!(outn, nm)
    end
    return outn, cols
end

"Group runs of pairs sorted by x row: `runs[i]` lists the handles paired with x row `i`."
function _runs(px::Vector{Int}, ph::Vector{Int}, nx::Int)
    runs = [Int[] for _ in 1:nx]
    @inbounds for (x, h) in zip(px, ph)
        push!(runs[x], h)
    end
    return runs
end

"x's grouping, mapped to the output names, kept when the columns survive (spec §1.1)."
function _regroup_out(out::Frame, names::JoinNames, groups::Vector{Symbol}, drop::Bool)
    isempty(groups) && return out
    gs = Symbol[]
    for g in groups
        j = findfirst(i -> (names.outside[i] in (:x, :key) && names.outsrc[i] === g) || (names.outside[i] === :nest && names.outnames[i] === g), eachindex(names.outnames))
        j === nothing && continue
        nm = names.outnames[j]
        hascolumn(out, nm) && push!(gs, nm)
    end
    isempty(gs) && return out
    return regroup(out, gs; drop)
end

_ungrouped(f::Frame) = isgrouped(f) ? Frame(copy(f.names), copy(f.columns), Symbol[], nothing, f.nrow) : f

"The kinds whose broadcast-build-y shape needs a tail (spec §1.2 shape a)."
_needs_ytail(s::JoinStep) = s.kind === :right || s.kind === :full ||
    (s.unmatched === :error && (s.kind === :inner || s.kind === :left || s.kind === :nest))

# ---------------------------------------------------------------------------------------------
# The physical steps

"""
    ProbeStep(side, build, spec, names, tail)

A streamable join probe (spec §1.2). `side = :y`: `build` is y's `JoinBuild` and the probe
streams x morsels (shape a); `side = :x`: `build` is x's `JoinBuild` and the probe streams y
morsels (shape b, always followed by a `JoinTailStep`). For a cross join `build` is the
collected y frame. `tail` says whether a `JoinTailStep` follows (shape a: the hidden y-row or
y-key column is emitted). In `explain`'s plan, `build` is the build side's plan.
"""
struct ProbeStep <: Step
    side::Symbol
    build::Any
    spec::JoinStep
    names::JoinNames
    tail::Bool
end

"""
    JoinTailStep(side, build, spec, names)

The pipeline breaker after a probe (spec §1.2): for `side = :y` (shape a) the y-side check and
the unmatched y rows of right/full joins; for `side = :x` (shape b) the order-restoring sort,
the x-side pass, `multiple`, the y-side check, the unmatched rows, and x's columns.
"""
struct JoinTailStep <: Step
    side::Symbol
    build::Any
    spec::JoinStep
    names::JoinNames
end

"""
    PartitionedJoinStep(right, spec, names, build, p, T, morsel, threads)

Shape (c) (spec §1.2): x arrives gathered; y is `right` (a collected frame, or y's plan,
collected when the step runs). Both sides' keys are hashed and radix-partitioned into `2^p`
partitions; each partition's table is built on `build` (`:x` or `:y`) and probed in ascending
order; the probes raise nothing, every check runs after the order-restoring sort.
"""
struct PartitionedJoinStep <: Step
    right::Any
    spec::JoinStep
    names::JoinNames
    build::Symbol
    p::Int
    T::Vector{Type}
    morsel::Int
    threads::Bool
end

_bystr(ps::Vector{Pair{Symbol, Symbol}}) = "[" * join([p.first === p.second ? repr(p.first) : "$(repr(p.first)) => $(repr(p.second))" for p in ps], ", ") * "]"
_bystr(n::JoinNames) = _bystr(n.pairs)
Base.show(io::IO, p::ProbeStep) = p.spec.kind === :cross ?
    print(io, "probe(cross; y collected, x streamed)") :
    print(io, "probe(", p.spec.kind, "; build ", p.side, ", stream ", p.side === :y ? :x : :y, ", by = ", _bystr(p.names), p.tail ? ", emits hidden columns" : "", ")")
Base.show(io::IO, t::JoinTailStep) = print(io, "join_tail(", t.spec.kind, "; build ", t.side, t.side === :x ? ", order-restoring sort" : "", ")")
Base.show(io::IO, s::PartitionedJoinStep) =
    print(io, "partitioned_join(", s.spec.kind, "; 2^", s.p, " partitions, build ", s.build, ", by = ", _bystr(s.names), ", order-restoring sort)")

function apply(p::ProbeStep, f::Frame)
    p.spec.kind === :cross && return _cross(p.spec, p.names, f, p.build::Frame)
    b = p.build::JoinBuild
    return p.side === :y ? _probe_streams_x(p, b, f) : _probe_streams_y(p, b, f)
end

# Shape (a): x streams; the morsel's pairs are already in (x row, y row) order (no sort).
function _probe_streams_x(p::ProbeStep, b::JoinBuild, X::Frame)
    s, names = p.spec, p.names
    xkeys = _xkeys(names)
    nx = X.nrow
    xconv = _convkeys(X, xkeys, b.T)
    pk = _join_typed_keys(xconv, nx, xkeys)
    null = s.na_matches === :never ? _nullkeys(xconv, nx) : nothing
    if s.kind === :semi || s.kind === :anti
        ids = _probe_ids(b, pk, null)
        return take(X, s.kind === :semi ? findall(!=(0), ids) : findall(==(0), ids))
    end
    px, py = _probe_pairs(b, pk, null)
    if s.kind === :nest
        outn, cols = _assemble_nest(s, names, X, xconv, b.frame, _runs(px, py, nx))
        if p.tail
            ids = _probe_ids(b, pk, null)
            push!(outn, _YKEY)
            push!(cols, column(ids))
        end
        return _regroup_out(Frame(outn, cols, Symbol[], nothing, nx), names, X.groups, X.drop)
    end
    cx, cy = _xpass(px, py, nx, s)
    outn, cols = _assemble(s, names, X, xconv, b.frame, b.conv, cx, cy)
    if p.tail
        push!(outn, _YROW)
        push!(cols, column(cy))
    end
    return _regroup_out(Frame(outn, cols, Symbol[], nothing, length(cx)), names, X.groups, X.drop)
end

# Shape (b): y streams; each y row's x matches, in x order, plus the hidden columns.
function _probe_streams_y(p::ProbeStep, b::JoinBuild, Y::Frame)
    s, names = p.spec, p.names
    ykeys = _ykeys(names)
    ny = Y.nrow
    yconv = _convkeys(Y, ykeys, b.T)
    pk = _join_typed_keys(yconv, ny, ykeys)
    null = s.na_matches === :never ? _nullkeys(yconv, ny) : nothing
    if s.kind === :semi || s.kind === :anti
        ids = unique!(filter!(!=(0), _probe_ids(b, pk, null)))
        return Frame(Symbol[_XKEY], AbstractColumn[column(ids)])
    end
    py, px = _probe_pairs(b, pk, null)
    needall = s.kind === :right || s.kind === :full ||
        (s.unmatched === :error && (s.kind === :inner || s.kind === :left || s.kind === :nest))
    rows, xrow, ystart = _emit_rows(py, px, ny, needall)
    outn = Symbol[]
    cols = AbstractColumn[]
    for (n, c) in zip(Y.names, Y.columns)
        push!(outn, n)
        push!(cols, take(c, rows))
    end
    push!(outn, _XROW, _YSTART)
    push!(cols, column(xrow), column(ystart))
    return Frame(outn, cols, Symbol[], nothing, length(rows))
end
function _emit_rows(py::Vector{Int}, px::Vector{Int}, ny::Int, needall::Bool)
    rows = Int[]
    xrow = Int[]
    ystart = Bool[]
    m = length(py)
    j = 1
    @inbounds for i in 1:ny
        a = j
        while j <= m && py[j] == i
            push!(rows, i)
            push!(xrow, px[j])
            push!(ystart, j == a)
            j += 1
        end
        if j == a && needall
            push!(rows, i)
            push!(xrow, 0)
            push!(ystart, true)
        end
    end
    return rows, xrow, ystart
end

function apply(t::JoinTailStep, G::Frame)
    b = t.build::JoinBuild
    return t.side === :y ? _tail_build_y(t, b, G) : _tail_build_x(t, b, G)
end

function _drophidden(G::Frame)
    keep = findall(n -> !_ishidden(n), G.names)
    return Frame(G.names[keep], G.columns[keep], Symbol[g for g in G.groups if !_ishidden(g)], nothing, G.nrow, G.drop)
end

function _tail_build_y(t::JoinTailStep, b::JoinBuild, G::Frame)
    s, names = t.spec, t.names
    ny = b.frame.nrow
    if s.kind === :nest
        marked = falses(length(b.table))
        for id in getcol(G, _YKEY)
            id > 0 && (marked[id] = true)
        end
        for r in 1:ny
            id = b.ids[r]
            (id == 0 || !marked[id]) && throw(_y_unmatched_error(r))
        end
        return _regroup_like(_drophidden(G), G)
    end
    matched = falses(ny)
    for r in getcol(G, _YROW)
        r > 0 && (matched[r] = true)
    end
    if s.unmatched === :error && (s.kind === :inner || s.kind === :left)
        r = findfirst(!, matched)
        r === nothing || throw(_y_unmatched_error(r))
    end
    out = _drophidden(G)
    if s.kind === :right || s.kind === :full
        un = findall(!, matched)
        isempty(un) || (out = _append_yonly(s, names, out, b.frame, b.conv, un))
    end
    return _regroup_like(out, G)
end
_regroup_like(out::Frame, G::Frame) = isempty(out.groups) ? out : regroup(out, copy(out.groups); drop = G.drop)

# Append y's unmatched rows `un` (right/full; shape a): x columns missing, keys from y.
function _append_yonly(s::JoinStep, names::JoinNames, out::Frame, Y::Frame, yconv, un::Vector{Int})
    k = length(un)
    xkeys = _xkeys(names)
    cols = AbstractColumn[]
    for (nm, col) in zip(out.names, out.columns)
        j = findfirst(==(nm), names.outnames)::Int
        side, src = names.outside[j], names.outsrc[j]
        block = if side === :x
            take(col, zeros(Int, k))
        elseif side === :y
            c = take(getcol(Y, src), un)
            s.kind === :full ? _asnullable(c) : c
        else
            p = findfirst(==(src), xkeys)::Int
            column(yconv[p][un])
        end
        push!(cols, vcat_columns(AbstractColumn[col, block]))
    end
    return Frame(copy(out.names), cols, copy(out.groups), nothing, out.nrow + k, out.drop)
end

function _tail_build_x(t::JoinTailStep, b::JoinBuild, G::Frame)
    s, names = t.spec, t.names
    X = b.frame
    nx = X.nrow
    if s.kind === :semi || s.kind === :anti
        marked = falses(length(b.table))
        for id in getcol(G, _XKEY)
            marked[id] = true
        end
        semi = s.kind === :semi
        rows = Int[r for r in 1:nx if (b.ids[r] != 0 && marked[b.ids[r]]) == semi]
        return take(X, rows)
    end
    xrow = collect(Int, getcol(G, _XROW))
    ystart = collect(Bool, getcol(G, _YSTART))
    yord = cumsum(Int.(ystart))
    ny = isempty(yord) ? 0 : yord[end]
    yfirst = findall(ystart)
    gs = findall(>(0), xrow)
    perm = _sort_by_x(xrow[gs], nx)
    ph = gs[perm]
    px = xrow[ph]
    Y = _drophidden(G)
    return _finish(s, names, X, b.conv, b.T, Y, px, ph, yord, yfirst, ny)
end

"""
    _finish(s, names, X, xconv, T, Y, px, ph, ynum, yfirst, ny)

Steps 3–8 of shape (b) (spec §1.2), shared by shape (c): the pairs `(px, ph)` are sorted by x
row (`ph`: rows of `Y`, the frame holding y's values); `ynum[h]` is the y row number of handle
`h` and `yfirst[n]` the handle of y row `n` (`ny` rows; every y row has one when the kind needs
y's unmatched rows).
"""
function _finish(s::JoinStep, names::JoinNames, X::Frame, xconv, T::Vector{Type}, Y::Frame, px::Vector{Int}, ph::Vector{Int}, ynum::AbstractVector{Int}, yfirst::AbstractVector{Int}, ny::Int)
    nx = X.nrow
    if s.kind === :semi || s.kind === :anti
        has = falses(nx)
        for x in px
            has[x] = true
        end
        return take(X, s.kind === :semi ? findall(has) : findall(!, has))
    end
    if s.kind === :nest
        if s.unmatched === :error
            matched = falses(ny)
            for h in ph
                matched[ynum[h]] = true
            end
            r = findfirst(!, matched)
            r === nothing || throw(_y_unmatched_error(r))
        end
        outn, cols = _assemble_nest(s, names, X, xconv, Y, _runs(px, ph, nx))
        return _regroup_out(Frame(outn, cols, Symbol[], nothing, nx), names, X.groups, X.drop)
    end
    cx, ch = _xpass(px, ph, nx, s)
    yside = s.unmatched === :error && (s.kind === :inner || s.kind === :left)
    appendy = s.kind === :right || s.kind === :full
    if yside || appendy
        matched = falses(ny)
        for h in ch
            h > 0 && (matched[ynum[h]] = true)
        end
        if yside
            r = findfirst(!, matched)
            r === nothing || throw(_y_unmatched_error(r))
        end
        if appendy
            for n in 1:ny
                matched[n] || (push!(cx, 0); push!(ch, yfirst[n]))
            end
        end
    end
    yconv = appendy ? _convkeys(Y, _ykeys(names), T) : nothing
    outn, cols = _assemble(s, names, X, xconv, Y, yconv, cx, ch)
    return _regroup_out(Frame(outn, cols, Symbol[], nothing, length(cx)), names, X.groups, X.drop)
end

function apply(s::PartitionedJoinStep, X::Frame)
    Y = s.right isa Frame ? s.right : _run_subplan(s.right; morsel = s.morsel, threads = s.threads)
    return _partitioned_join(s.spec, s.names, X, _ungrouped(Y), s.T, s.build, s.p, s.threads)
end

# Shape (c): both sides radix-partitioned by the high hash bits; one task per contiguous range
# of partitions; per partition the build side's rows (ascending) fill a table and the other
# side's rows probe it (ascending). Then the order-restoring sort and the shared finish.
function _partitioned_join(s::JoinStep, names::JoinNames, X::Frame, Y::Frame, T::Vector{Type}, build::Symbol, p::Int, threads::Bool)
    nx, ny = X.nrow, Y.nrow
    xkeys, ykeys = _xkeys(names), _ykeys(names)
    xconv = _convkeys(X, xkeys, T)
    yconv = _convkeys(Y, ykeys, T)
    xk = _join_typed_keys(xconv, nx, xkeys)
    yk = _join_typed_keys(yconv, ny, ykeys)
    never = s.na_matches === :never
    xnull = never ? _nullkeys(xconv, nx) : nothing
    ynull = never ? _nullkeys(yconv, ny) : nothing
    xh = keyhashes(xk)
    yh = keyhashes(yk)
    np = 1 << p
    nt = (threads && Threads.nthreads() > 1 && nx + ny >= 65_536) ? min(Threads.nthreads(), np) : 1
    xoff, xperm = radix_partition(xh, p; ntasks = nt)
    yoff, yperm = radix_partition(yh, p; ntasks = nt)
    pxs = [Int[] for _ in 1:np]
    pys = [Int[] for _ in 1:np]
    ranges = [(div((k - 1) * np, nt) + 1):div(k * np, nt) for k in 1:nt]
    work(r) = for j in r
        xs = view(xperm, xoff[j]:(xoff[j + 1] - 1))
        ys = view(yperm, yoff[j]:(yoff[j + 1] - 1))
        if build === :y
            _partition_pairs!(pxs[j], pys[j], yk, yh, ys, ynull, xk, xh, xs, xnull, false)
        else
            _partition_pairs!(pxs[j], pys[j], xk, xh, xs, xnull, yk, yh, ys, ynull, true)
        end
    end
    if nt == 1
        work(1:np)
    else
        tasks = [Threads.@spawn(work(r)) for r in ranges]
        foreach(wait, tasks)
    end
    px = reduce(vcat, pxs; init = Int[])
    py = reduce(vcat, pys; init = Int[])
    perm = _sort_by_x(px, nx)
    px, py = px[perm], py[perm]
    r = 1:ny
    return _finish(s, names, X, xconv, T, Y, px, py, r, r, ny)
end

# One partition: build on `bk[brows]`, probe with `qk[qrows]` (both ascending). Pairs go out as
# (x row, y row); `buildx` says which side was built.
function _partition_pairs!(
        px::Vector{Int}, py::Vector{Int}, bk::AbstractVector{K}, bh::Vector{UInt64}, brows::AbstractVector{Int}, bnull,
        qk::AbstractVector, qh::Vector{UInt64}, qrows::AbstractVector{Int}, qnull, buildx::Bool,
    ) where {K}
    (isempty(brows) || isempty(qrows)) && return px
    t = KeyTable{K}(length(brows))
    first = Int[]
    last = Int[]
    next = zeros(Int, length(brows))
    @inbounds for (q, r) in enumerate(brows)
        bnull !== nothing && bnull[r] && continue
        id = getorinsert!(t, bk[r], bh[r])
        if id > length(first)
            push!(first, q)
            push!(last, q)
        else
            next[last[id]] = q
            last[id] = q
        end
    end
    @inbounds for r in qrows
        qnull !== nothing && qnull[r] && continue
        id = lookup(t, qk[r], qh[r])
        id == 0 && continue
        q = first[id]
        while q != 0
            if buildx
                push!(px, brows[q])
                push!(py, r)
            else
                push!(px, r)
                push!(py, brows[q])
            end
            q = next[q]
        end
    end
    return px
end

# The cross join: |x| × |y| rows, x order, each x row's block in y order (spec §1.5).
function _cross(s::JoinStep, names::JoinNames, X::Frame, Y::Frame)
    nx, ny = X.nrow, Y.nrow
    xr = Int[i for i in 1:nx for _ in 1:ny]
    yr = Int[j for _ in 1:nx for j in 1:ny]
    outn, cols = _assemble(s, names, X, nothing, Y, nothing, xr, yr)
    return _regroup_out(Frame(outn, cols, Symbol[], nothing, nx * ny), names, X.groups, X.drop)
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
