# Key equality and the group index (ADR-0003 rules 3 and 8). Keys follow `isequal`, except that
# NaN/-NaN are one key and -0.0/0.0 are one key (shown as the first one seen in row order);
# `missing` is its own key. Each key column is coded through a typed `Dict` of its canonical
# values (no `Dict{Any}` per row); several columns combine their codes pairwise.

"""
    _keycodes(col) -> (codes, firstrow)

Dense codes `1:k` of `col`'s canonical values in first-seen order, and the first row of each.
"""
function _keycodes(col::AbstractVector)
    E = eltype(col)
    d = Dict{E, Int}()
    codes = Vector{Int}(undef, length(col))
    first = Int[]
    for (i, x) in enumerate(col)
        k = _canon(x)
        code = get(d, k, 0)
        if code == 0
            code = length(d) + 1
            d[k] = code
            push!(first, i)
        end
        codes[i] = code
    end
    return codes, first
end
# Dictionary columns: the dictionary holds unique values, so codes are keys after canonicalising
# the dictionary itself (two dictionary entries may still be ±0.0).
function _keycodes(col::DictColumn)
    dcodes, _ = _keycodes(col.dict)
    remap = col.validity === nothing ? (i -> dcodes[col.codes[i]]) :
        (i -> col.validity[i] ? dcodes[col.codes[i]] + 1 : 1)
    raw = [remap(i) for i in eachindex(col.codes)]
    return _keycodes(raw)
end

"Combine two code vectors into dense codes of their pairs, in first-seen order."
function _paircodes(a::Vector{Int}, b::Vector{Int})
    d = Dict{Tuple{Int, Int}, Int}()
    codes = Vector{Int}(undef, length(a))
    first = Int[]
    for i in eachindex(a)
        k = (a[i], b[i])
        code = get(d, k, 0)
        if code == 0
            code = length(d) + 1
            d[k] = code
            push!(first, i)
        end
        codes[i] = code
    end
    return codes, first
end

"""
    rowcodes(cols, n = length(cols[1])) -> (codes, firstrow)

Dense per-row key codes over several columns (first-seen order), under rule 8's equality. With
zero key columns every row has the same key: `n` codes `1` (first row `1`), so pass `n` (the row
count) whenever `cols` may be empty; without it, an empty `cols` means zero rows.
"""
function rowcodes(cols::AbstractVector, n::Int = isempty(cols) ? 0 : length(cols[1]))
    all(col -> length(col) == n, cols) ||
        throw(DimensionMismatch("rowcodes: key columns have lengths $(map(length, cols)), expected $n rows"))
    isempty(cols) && return (ones(Int, n), n == 0 ? Int[] : [1])
    codes, first = _keycodes(cols[1])
    for k in 2:length(cols)
        b, _ = _keycodes(cols[k])
        codes, first = _paircodes(codes, b)
    end
    return codes, first
end

# Ascending order of distinct key values; NaN before missing (isless). Values without `isless`
# keep first-seen order. So do values whose `isless` refuses the pair: an `Any` column mixing
# naive and zoned timestamps (ADR-0021 rule 5) raises an ArgumentError there.
_unordered(err) = err isa MethodError || (err isa ArgumentError && occursin("(ADR-0021 rule 5)", err.msg))
function _valueranks(col::AbstractVector, firstrows::Vector{Int})
    vals = [_canon(col[i]) for i in firstrows]
    p = try
        sortperm(vals; lt = isless, alg = MergeSort)
    catch err
        _unordered(err) || rethrow()
        collect(eachindex(vals))
    end
    r = similar(p)
    r[p] = eachindex(p)
    return r
end

"""
    build_gindex(f, keys; drop = true) -> GroupIndex

The group index of frame `f` over `keys`: groups numbered in ascending key order (CF-008),
rows of each group in row order, key values as first seen. `drop = false` also keeps the empty
groups of absent dictionary entries of `DictColumn` keys (dplyr's `.drop = FALSE`; see
[`_build_gindex_keep`](@ref)).
"""
function build_gindex(f::Frame, keys::Vector{Symbol}; drop::Bool = true)
    drop || !any(k -> getcol(f, k) isa DictColumn, keys) || return _build_gindex_keep(f, keys)
    cols = AbstractVector[getcol(f, k) for k in keys]
    n = f.nrow
    codes, firstrows = rowcodes(cols, n)
    ng = length(firstrows)
    # per-column ranks of each group's key value
    ranks = Vector{Vector{Int}}(undef, length(cols))
    for (j, col) in enumerate(cols)
        cj, fj = _keycodes(col)
        rj = _valueranks(col, fj)
        ranks[j] = [rj[cj[r]] for r in firstrows]
    end
    order = sortperm(1:ng; lt = (a, b) -> _lexless(ranks, a, b), alg = MergeSort)
    newid = similar(order)
    newid[order] = 1:ng
    ids = Vector{Int}(undef, n)
    counts = zeros(Int, ng)
    for r in 1:n
        g = newid[codes[r]]
        ids[r] = g
        counts[g] += 1
    end
    starts = Vector{Int}(undef, ng + 1)
    starts[1] = 1
    for g in 1:ng
        starts[g + 1] = starts[g] + counts[g]
    end
    pos = starts[1:ng]
    perm = Vector{Int}(undef, n)
    for r in 1:n
        g = ids[r]
        perm[pos[g]] = r
        pos[g] += 1
    end
    keyrows = firstrows[order]
    keycols = AbstractColumn[take(getcol(f, k), keyrows) for k in keys]
    return GroupIndex(ids, perm, starts, keycols)
end
function _lexless(ranks, a, b)
    for r in ranks
        r[a] == r[b] || return r[a] < r[b]
    end
    return false
end

# Index from per-group row lists, already in group order; `keycols` one column per key.
function _gindex_from(rowsets::Vector{Vector{Int}}, n::Int, keycols::Vector{AbstractColumn})
    ng = length(rowsets)
    ids = Vector{Int}(undef, n)
    perm = Vector{Int}(undef, n)
    starts = Vector{Int}(undef, ng + 1)
    starts[1] = 1
    k = 0
    for (g, rows) in enumerate(rowsets)
        for r in rows
            k += 1
            perm[k] = r
            ids[r] = g
        end
        starts[g + 1] = k + 1
    end
    return GroupIndex(ids, perm, starts, keycols)
end

"""
    _build_gindex_keep(f, keys) -> GroupIndex

`group_by(keys...; drop = false)`, as dplyr 1.2.0's `.drop = FALSE`. Each entry of a
`DictColumn` key's dictionary (canonicalised, ADR-0003 rule 8) is a level. Keys are expanded
left to right: within each observed prefix, a dictionary key gets a group for every level (an
absent one is an empty group); under an empty prefix, a later dictionary key crosses all its
levels and a later non-dictionary key is `missing`. `missing` is a group only when observed.
Groups are then ordered by CF-008's `isless` order of the key values (dplyr orders levels by
level order: a documented difference). Rows of each group stay in row order.
"""
function _build_gindex_keep(f::Frame, keys::Vector{Symbol})
    n = f.nrow
    m = length(keys)
    cols = AbstractVector[getcol(f, k) for k in keys]
    # per key: row codes (0 = missing for a dictionary key), canonical values, level count
    rowc = Vector{Vector{Int}}(undef, m)
    vals = Vector{Vector{Any}}(undef, m)
    nlev = zeros(Int, m)              # > 0 only for dictionary keys
    dfirst = Vector{Vector{Int}}(undef, m)
    for (j, col) in enumerate(cols)
        if col isa DictColumn
            dcodes, df = _keycodes(col.dict)
            rowc[j] = Int[_isvalid(col.validity, i) ? dcodes[col.codes[i]] : 0 for i in 1:n]
            vals[j] = Any[_canon(col.dict[i]) for i in df]
            nlev[j] = length(df)
            dfirst[j] = df
        else
            codes, first = _keycodes(col)
            rowc[j] = codes
            vals[j] = Any[_canon(col[i]) for i in first]
            dfirst[j] = first
        end
    end
    gcodes = Vector{Vector{Int}}()    # per group: one code per key (0 = missing)
    grows = Vector{Vector{Int}}()
    function emit_empty(j, prefix)
        if j > m
            push!(gcodes, prefix)
            push!(grows, Int[])
        elseif nlev[j] > 0
            for lv in 1:nlev[j]
                emit_empty(j + 1, [prefix; lv])
            end
        else
            emit_empty(j + 1, [prefix; 0])
        end
        return nothing
    end
    function expand(j, rows, prefix)
        if j > m
            push!(gcodes, prefix)
            push!(grows, rows)
            return nothing
        end
        parts = Dict{Int, Vector{Int}}()
        order = Int[]
        for r in rows
            cd = rowc[j][r]
            haskey(parts, cd) || (parts[cd] = Int[]; push!(order, cd))
            push!(parts[cd], r)
        end
        for cd in order
            expand(j + 1, parts[cd], [prefix; cd])
        end
        for lv in 1:nlev[j]
            haskey(parts, lv) || emit_empty(j + 1, [prefix; lv])
        end
        return nothing
    end
    expand(1, collect(1:n), Int[])
    # ranks of each key's values (code 0 = missing); values without isless keep first-seen order
    ranks = Vector{Dict{Int, Int}}(undef, m)
    for j in 1:m
        cds = [0; collect(eachindex(vals[j]))]
        vs = Any[cd == 0 ? missing : vals[j][cd] for cd in cds]
        p = try
            sortperm(vs; lt = isless, alg = MergeSort)
        catch err
            _unordered(err) || rethrow()
            collect(eachindex(vs))
        end
        ranks[j] = Dict(cds[p[k]] => k for k in eachindex(p))
    end
    ng = length(gcodes)
    function grouplt(a, b)
        for j in 1:m
            ra, rb = ranks[j][gcodes[a][j]], ranks[j][gcodes[b][j]]
            ra == rb || return ra < rb
        end
        return false
    end
    order = sortperm(1:ng; alg = MergeSort, lt = grouplt)
    gcodes, grows = gcodes[order], grows[order]
    keycols = AbstractColumn[]
    for (j, col) in enumerate(cols)
        if col isa DictColumn
            C = eltype(col.codes)
            codes = C[g[j] == 0 ? 0 : dfirst[j][g[j]] for g in gcodes]
            val = col.validity === nothing ? nothing : BitVector(!iszero(cd) for cd in codes)
            push!(keycols, DictColumn(codes, col.dict, val))
        else
            # a group's first row holds its key value; an empty group under an observed value
            # takes that value's first row; code 0 (an empty prefix) is missing
            idx = Int[gcodes[g][j] == 0 ? 0 : isempty(grows[g]) ? dfirst[j][gcodes[g][j]] : grows[g][1] for g in 1:ng]
            push!(keycols, take(col, idx))
        end
    end
    return _gindex_from(grows, n, keycols)
end

"The frame's group index, built when the frame is grouped but carries none."
function gindex(f::Frame)
    isempty(f.groups) && return nothing
    f.gindex !== nothing && return f.gindex
    return build_gindex(f, f.groups)
end

"`f` regrouped by `keys` (no keys: ungrouped), with a fresh group index (`drop`: see [`build_gindex`](@ref))."
regroup(f::Frame, keys::Vector{Symbol}; drop::Bool = true) =
    Frame(copy(f.names), copy(f.columns), copy(keys), isempty(keys) ? nothing : build_gindex(f, keys; drop), f.nrow)
