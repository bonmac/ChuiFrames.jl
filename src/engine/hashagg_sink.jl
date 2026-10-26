# The hash-aggregate operator (phase-4 spec §2.3; ADR-0003 rules 5, 6, 9): each task folds a
# contiguous range of morsels into runs (a task's table between two radix flushes); the runs are
# merged per radix partition in (range, seq) order; the groups get their final values and are
# sorted by the keys exactly as the eager group index sorts them. Group-by lane. Split out of
# hashagg.jl (review B1: the 600-line ratchet); `RADIX_SWITCH`, `_FORCE_RADIX_SWITCH` and the
# key machinery stay there, the accumulators are in hashagg_acc.jl.

# Radix bits of the partitioned merge when some task switched: a few partitions per task.
_merge_bits(ntasks::Int) = clamp(ceil(Int, log2(4 * ntasks)), 3, 8)

"""
    HashAggSpec

What the hash-aggregate sink computes: the group `keys` (plain columns of the streamed stage's
output) and `drop` flag, one output per summary (`names`, expression `nodes` for their static
types, aggregators `aggs`, the input column or `nothing` for `n_rows()`), which keys are
dictionary columns remapped through a global dictionary (`dictmode`), and the shape of the
result: summarise's `groups` option and whether it came from `summarise(...; by)`.
"""
struct HashAggSpec
    keys::Vector{Symbol}
    drop::Bool
    names::Vector{Symbol}
    nodes::Vector{Any}
    aggs::Vector{Any}
    cols::Vector{Union{Nothing, Symbol}}
    dictmode::Vector{Bool}
    groups::Symbol
    by::Bool
end

_keytype(::KeyTable{K}) where {K} = K

# The table key type of typed keys: string views (into a morsel's buffer) are stored as String,
# converted once per new key (a table outlives the morsel).
function _tablekey(E::Type)
    E isa DataType && E <: Tuple && return Tuple{map(_tablekey, fieldtypes(E))...}
    return _valtype(E)
end

"`t` rebuilt with key type `K2`: every key reinserted in id order, so the ids are kept."
function _rekey(t::KeyTable, ::Type{K2}) where {K2}
    t2 = KeyTable{K2}(length(t))
    @inbounds for id in 1:length(t)
        getorinsert!(t2, t.keys[id], t.hashes[id])
    end
    return t2
end

"""
A global value-keyed dictionary for a dictionary-encoded key (critic M6): one shared
[`KeyTable`](@ref) of canonical values behind a lock. A morsel's codes are remapped to its ids,
consulted once per distinct code present in the morsel, so partitions with different or permuted
dictionaries group by value and no string is hashed per row.
"""
mutable struct _GlobalDict
    table::KeyTable
    lock::ReentrantLock
end
_GlobalDict() = _GlobalDict(KeyTable{Union{}}(16), ReentrantLock())

function _ensurekey!(gd::_GlobalDict, E::Type)
    K = _keytype(gd.table)
    Kn = _tablekey(E)
    Kn <: K || (gd.table = _rekey(gd.table, _jointype(K, Kn)))
    return gd
end

# Global codes (UInt32, 0 = missing) of a morsel's dictionary column.
function _globalcodes(gd::_GlobalDict, col::DictColumn)
    present = _presentcodes(zeros(Bool, length(col.dict)), col.codes, col.validity)
    gmap = zeros(UInt32, length(col.dict))
    lock(gd.lock) do
        _ensurekey!(gd, eltype(col.dict))
        _mapdict!(gmap, gd.table, col.dict, present)
    end
    return _applygmap!(Vector{UInt32}(undef, length(col.codes)), col.codes, col.validity, gmap)
end
function _applygmap!(out::Vector{UInt32}, codes::Vector{<:Unsigned}, v::Validity, gmap::Vector{UInt32})
    @inbounds for i in eachindex(out)
        out[i] = _isvalid(v, i) ? gmap[Int(codes[i])] : UInt32(0)
    end
    return out
end
# A plain column under a dictionary-mode key (another partition kind): every row through the table.
function _globalcodes(gd::_GlobalDict, col::AbstractVector)
    out = Vector{UInt32}(undef, length(col))
    lock(gd.lock) do
        _ensurekey!(gd, nonmissingtype(eltype(col)))
        _mapvalues!(out, gd.table, col)
    end
    return out
end
function _presentcodes(present::Vector{Bool}, codes::Vector{<:Unsigned}, v::Validity)
    @inbounds for i in eachindex(codes)
        _isvalid(v, i) && (present[Int(codes[i])] = true)
    end
    return present
end
function _globalid(t::KeyTable, x)
    id = getorinsert!(t, x, keyhash(x))
    id <= typemax(UInt32) || throw(ArgumentError("hash aggregate: more than $(typemax(UInt32)) dictionary values"))
    return id % UInt32
end
function _mapdict!(gmap::Vector{UInt32}, t::KeyTable, dict::AbstractVector, present::Vector{Bool})
    @inbounds for j in eachindex(present)
        present[j] && (gmap[j] = _globalid(t, dict[j]))
    end
    return gmap
end
function _mapvalues!(out::Vector{UInt32}, t::KeyTable, col::AbstractVector)
    @inbounds for (o, i) in zip(eachindex(out), eachindex(col))
        x = col[i]
        out[o] = ismissing(x) ? UInt32(0) : _globalid(t, x)
    end
    return out
end

# The keys of one morsel: canonical typed values per key column (global codes for a
# dictionary-mode key), a concrete Tuple per row for several columns.
function _sinkkeys(cols::Vector{AbstractVector}, n::Int, gds::Vector{Union{Nothing, _GlobalDict}})
    length(cols) == 1 && return _sinkkey1(cols[1], n, gds[1])
    ks = Vector{AbstractVector}(undef, length(cols))
    for j in eachindex(cols)
        ks[j] = _sinkkey1(cols[j], n, gds[j])
    end
    return _tuplekeys(Tuple(ks), n)
end
# a dictionary-mode key (it has a global dictionary): global codes; else canonical values
_sinkkey1(col::AbstractVector, ::Int, gd::_GlobalDict) = _globalcodes(gd, col)
function _sinkkey1(col::AbstractVector, n::Int, ::Nothing)
    k = typed_keys(AbstractVector[col], n; codes = false)
    return k === nothing ? Any[_canon(x) for x in col] : k
end

"A task's table and accumulators between two radix flushes, with each group's first row (`firstpos`, into the task's key chunks)."
mutable struct _Run
    table::KeyTable
    accs::Vector{_Acc}
    firstpos::Vector{Int}
end

"""
One task's partial state: its finished runs (flushed in `seq` order) and the current one, the
key columns of each new group's first row (`keychunks`, one chunk per non-empty morsel and key,
taken from the morsel, so their concatenation has the column kinds the gathered frame would
have), zero-row chunks of each output's input column (for the gathered element types), zero-row
chunks of the key columns of every morsel that counts for the column kinds (`keykinds`, for
`_gathered_kind`), whether it switched to radix mode, and morsel 1's empty output (the gather's
result when no morsel has rows).
"""
mutable struct _AggTask
    runs::Vector{_Run}
    cur::Union{Nothing, _Run}
    keychunks::Vector{Vector{AbstractColumn}}
    colchunks::Vector{Vector{AbstractColumn}}
    keykinds::Vector{Vector{AbstractColumn}}
    nkeyrows::Int
    switched::Bool
    first::Union{Nothing, Frame}
end
_AggTask(spec::HashAggSpec) = _AggTask(
    _Run[], nothing, [AbstractColumn[] for _ in spec.keys], [AbstractColumn[] for _ in spec.cols],
    [AbstractColumn[] for _ in spec.keys], 0, false, nothing,
)

"Note the key columns' kinds of a morsel that counts for the gathered kinds (see `_gathered_kind`)."
function _notekinds!(st::_AggTask, spec::HashAggSpec, f::Frame)
    for (j, k) in enumerate(spec.keys)
        push!(st.keykinds[j], take(getcol(f, k), Int[]))
    end
    return st
end

_ineltype(f::Frame, c::Union{Nothing, Symbol}) = c === nothing ? Any : eltype(getcol(f, c))

"""
    _consume!(st::_AggTask, spec, f::Frame, gds, limit) -> st

Fold one morsel (the streamed stage's output `f`) into the task's current run: typed keys, one
probe per row in the run's [`KeyTable`](@ref) (new groups record their first row), then each
accumulator over its column. A run whose table passes `limit` groups is flushed (`seq` + 1) and
the task is in radix mode from then on.
"""
function _consume!(st::_AggTask, spec::HashAggSpec, f::Frame, gds::Vector{Union{Nothing, _GlobalDict}}, limit::Int)
    n = f.nrow
    n == 0 && return st
    kcols = AbstractVector[getcol(f, k) for k in spec.keys]
    tk = _sinkkeys(kcols, n, gds)
    K = _tablekey(eltype(tk))
    run = st.cur
    if run === nothing
        accs = _Acc[_newacc(spec.aggs[o], _ineltype(f, spec.cols[o])) for o in eachindex(spec.aggs)]
        run = _Run(KeyTable{K}(min(n, 1024)), accs, Int[])
        st.cur = run
    elseif !(K <: _keytype(run.table))
        run.table = _rekey(run.table, _jointype(_keytype(run.table), K))
    end
    ids = Vector{Int}(undef, n)
    newrows = Int[]
    keyids!(ids, run.table, tk, keyhashes(tk), newrows)
    for k in eachindex(newrows)
        push!(run.firstpos, st.nkeyrows + k)
    end
    st.nkeyrows += length(newrows)
    for j in eachindex(kcols)
        push!(st.keychunks[j], take(kcols[j], newrows))
    end
    m = length(run.table)
    for o in eachindex(spec.aggs)
        c = spec.cols[o]
        col = c === nothing ? nothing : getcol(f, c)
        acc = run.accs[o]
        if col !== nothing
            push!(st.colchunks[o], take(col, Int[]))
            _accepts(acc, eltype(col)) || (acc = _widen(acc, eltype(col)); run.accs[o] = acc)
        end
        _grow!(acc, m)
        _fold!(acc, ids, col)
    end
    if m > limit
        push!(st.runs, run)
        st.cur = nothing
        st.switched = true
    end
    return st
end

# Insert run `s`'s groups `lids` into the partition table `t`; new groups record their first row.
function _mergekeys!(t::KeyTable, s::KeyTable, lids::AbstractVector{Int}, gfirst::Vector{Int}, firstpos::Vector{Int}, off::Int)
    gids = Vector{Int}(undef, length(lids))
    @inbounds for (k, l) in enumerate(lids)
        n0 = length(t)
        g = getorinsert!(t, s.keys[l], s.hashes[l])
        g > n0 && push!(gfirst, off + firstpos[l])
        gids[k] = g
    end
    return gids
end

_jointypes(ts) = isempty(ts) ? Any : foldl(_jointype, ts)

# Run f(j) for the partitions j in 1:np: on contiguous ranges over the threads, or inline.
function _foreach_partition(f::F, np::Int, threads::Bool) where {F}
    nt = threads ? min(Threads.nthreads(), np) : 1
    nt <= 1 && return (foreach(f, 1:np); nothing)
    _radix_foreach(nt) do t
        foreach(f, _radix_range(np, nt, t))
    end
    return nothing
end

"""
    _hashagg_merge(tasks, spec; radix, threads) -> Vector{(gfirst, accs)}

The merge (phase-4 spec §2.3): every run, in (range, seq) order, is radix-partitioned by the
high bits of its group hashes (`radix_partition`; one partition when no task switched and
`radix` is false); per partition, one task combines each group's accumulators in that order
(CC-005, so `first`, `last` and `reduce` see the rows in row order). Returns, per partition, each
group's first-row position (into the concatenated key chunks) and the merged accumulators.
"""
function _hashagg_merge(tasks::Vector{_AggTask}, spec::HashAggSpec; radix::Bool, threads::Bool)
    runs = _Run[]
    offs = Int[]
    off = 0
    for st in tasks
        for r in st.runs
            push!(runs, r)
            push!(offs, off)
        end
        st.cur === nothing || (push!(runs, st.cur); push!(offs, off))
        off += st.nkeyrows
    end
    p = (radix || any(st -> st.switched, tasks)) ? _merge_bits(length(tasks)) : 0
    np = 1 << p
    parts = [radix_partition(r.table.hashes, p) for r in runs]
    K = _jointypes([_keytype(r.table) for r in runs])
    Tin = Type[_jointypes(Type[_intype(r.accs[o]) for r in runs]) for o in eachindex(spec.aggs)]
    results = Vector{Tuple{Vector{Int}, Vector{_Acc}}}(undef, np)
    _foreach_partition(np, threads) do j
        results[j] = _mergepart(j, runs, offs, parts, K, Tin, spec)
    end
    return results
end

function _mergepart(j::Int, runs::Vector{_Run}, offs::Vector{Int}, parts, K::Type, Tin::Vector{Type}, spec::HashAggSpec)
    t = KeyTable{K}(16)
    gaccs = _Acc[_newacc(spec.aggs[o], Tin[o]) for o in eachindex(spec.aggs)]
    gfirst = Int[]
    for (r, run) in enumerate(runs)
        offsets, perm = parts[r]
        lids = view(perm, offsets[j]:(offsets[j + 1] - 1))
        isempty(lids) && continue
        gids = _mergekeys!(t, run.table, lids, gfirst, run.firstpos, offs[r])
        m = length(t)
        for o in eachindex(gaccs)
            _grow!(gaccs[o], m)
            _mergeinto!(gaccs[o], gids, run.accs[o], lids)
        end
    end
    return gfirst, gaccs
end

"""
    _gathered_kind(col, parts) -> AbstractColumn

The gathered column `col` with the kind the eager read gives it: `read_source` concatenates the
raw partitions with `vcat_columns`, which keeps a dictionary column only when every partition's
column shares its dictionary (`===`) and otherwise decodes to the values (element type the
`Union` of the parts'). `parts` are the morsels' columns: empty morsels included, and pruned
ones too when a later step shows dictionary levels (`_needs_levels`; otherwise a pruned morsel
is left out, its levels cannot show). So a lone non-empty morsel of a source with per-partition
dictionaries is decoded too, and `group_by(drop = false)` shows the levels eager shows. Used by
the lazy gather and the hash-aggregate sink.
"""
function _gathered_kind(col::AbstractColumn, parts::Vector{AbstractColumn})
    (col isa DictColumn && !isempty(parts)) || return col
    p1 = parts[1]
    p1 isa DictColumn && all(p -> p isa typeof(p1) && p.dict === p1.dict, parts) && return col
    E = Union{map(eltype, parts)...}
    v = Vector{E}(undef, length(col))
    for i in eachindex(col)
        v[i] = col[i]
    end
    return column(v)
end

"""
    _hashagg_finish(results, tasks, spec, fallback) -> Frame

The summary frame, as eager `summarise` builds it on the gathered frame: the distinct keys (each
group's raw first-seen key row, from the key chunks concatenated as the gather concatenates
columns, so the column kinds and a dictionary's levels are the gathered frame's) are indexed with
[`build_gindex`](@ref) (`drop = false` adds the empty groups of absent dictionary levels, CC-006
for their values), which sorts them by CF-008's key order; each output column gets its static
type from the gathered element types (`typed_column`). `fallback()` is the gather's result when
no morsel has rows.
"""
function _hashagg_finish(results, tasks::Vector{_AggTask}, spec::HashAggSpec, fallback)
    G = sum(r -> length(r[1]), results; init = 0)
    pos = Vector{Int}(undef, G)
    part = Vector{Int}(undef, G)
    gid = Vector{Int}(undef, G)
    k = 0
    for (j, (gfirst, _)) in enumerate(results), (g, q) in enumerate(gfirst)
        k += 1
        pos[k], part[k], gid[k] = q, j, g
    end
    order = sortperm(pos)                      # global first-seen order of the groups
    fb = nothing
    getfb() = (fb === nothing && (fb = fallback()); fb::Frame)
    keycat = AbstractColumn[]
    for j in eachindex(spec.keys)
        chunks = AbstractColumn[c for st in tasks for c in st.keychunks[j]]
        col = isempty(chunks) ? getcol(getfb(), spec.keys[j]) : vcat_columns(chunks)
        push!(keycat, _gathered_kind(col, AbstractColumn[c for st in tasks for c in st.keykinds[j]]))
    end
    kf = Frame(copy(spec.keys), AbstractColumn[take(c, pos[order]) for c in keycat])
    gi = build_gindex(kf, spec.keys; drop = spec.drop)
    ng = ngroups(gi)
    src = zeros(Int, ng)                       # the group's index in `order`, 0 for an empty group
    for g in 1:ng
        rows = group_rows(gi, g)
        isempty(rows) || (src[g] = rows[1])
    end
    # the gathered frame's element types (static types of the outputs, eager's empty groups)
    ctxnames = copy(spec.keys)
    ctxtypes = Type[eltype(c) for c in keycat]
    coltype = Vector{Type}(undef, length(spec.aggs))
    for o in eachindex(spec.aggs)
        c = spec.cols[o]
        c === nothing && (coltype[o] = Any; continue)
        chunks = AbstractColumn[x for st in tasks for x in st.colchunks[o]]
        coltype[o] = eltype(isempty(chunks) ? getcol(getfb(), c) : vcat_columns(chunks))
        c in ctxnames || (push!(ctxnames, c); push!(ctxtypes, coltype[o]))
    end
    ctx = SelectCtx(ctxnames, ctxtypes, copy(spec.keys))
    outcols = AbstractColumn[]
    for o in eachindex(spec.aggs)
        fv = [_finals(r[2][o]) for r in results]
        v = Vector{Any}(undef, ng)
        for g in 1:ng
            q = src[g]
            v[g] = q == 0 ? _emptyfinal(spec.aggs[o], coltype[o]) : fv[part[order[q]]][gid[order[q]]]
        end
        T = static_type(spec.nodes[o], ctx)
        push!(outcols, ng == 0 ? column(Vector{isconcretetype(nonmissingtype(T)) ? T : Any}()) : typed_column(v, T))
    end
    keycols = AbstractColumn[take(c, collect(1:ng)) for c in gi.keys]
    out = Frame([spec.keys; spec.names], AbstractColumn[keycols; outcols], Symbol[], nothing, ng)
    groups = spec.by || spec.groups === :drop ? Symbol[] : spec.groups === :keep ? copy(spec.keys) : spec.keys[1:(end - 1)]
    return isempty(groups) ? out : regroup(out, groups; drop = spec.drop)
end
