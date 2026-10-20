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
    rowcodes(cols) -> (codes, firstrow)

Dense per-row key codes over several columns (first-seen order), under rule 8's equality.
"""
function rowcodes(cols::AbstractVector)
    n = isempty(cols) ? 0 : length(cols[1])
    isempty(cols) && return (ones(Int, n), n == 0 ? Int[] : [1])
    codes, first = _keycodes(cols[1])
    for k in 2:length(cols)
        b, _ = _keycodes(cols[k])
        codes, first = _paircodes(codes, b)
    end
    return codes, first
end

# Ascending order of distinct key values; NaN before missing (isless). Values without `isless`
# keep first-seen order.
function _valueranks(col::AbstractVector, firstrows::Vector{Int})
    vals = [_canon(col[i]) for i in firstrows]
    p = try
        sortperm(vals; lt = isless, alg = MergeSort)
    catch err
        err isa MethodError || rethrow()
        collect(eachindex(vals))
    end
    r = similar(p)
    r[p] = eachindex(p)
    return r
end

"""
    build_gindex(f, keys) -> GroupIndex

The group index of frame `f` over `keys`: groups numbered in ascending key order (CF-008),
rows of each group in row order, key values as first seen.
"""
function build_gindex(f::Frame, keys::Vector{Symbol})
    cols = AbstractVector[getcol(f, k) for k in keys]
    n = f.nrow
    codes, firstrows = rowcodes(cols)
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

"The frame's group index, built when the frame is grouped but carries none."
function gindex(f::Frame)
    isempty(f.groups) && return nothing
    f.gindex !== nothing && return f.gindex
    return build_gindex(f, f.groups)
end

"`f` regrouped by `keys` (no keys: ungrouped), with a fresh group index."
regroup(f::Frame, keys::Vector{Symbol}) =
    Frame(copy(f.names), copy(f.columns), copy(keys), isempty(keys) ? nothing : build_gindex(f, keys), f.nrow)
