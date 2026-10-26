# Radix partitioning, one primitive (phase-4 spec §2.4; ADR-0003 rule 10). Group-by lane.
# The aggregate sink, the partitioned join build and later spilling all use `radix_partition`.

"The largest `p` that `radix_partition` accepts (a histogram has `2^p` entries per task)."
const RADIX_MAX_BITS = 20

"""
    radix_partition(hashes::AbstractVector{UInt64}, p::Int; ntasks::Int = 1)
        -> (offsets::Vector{Int}, perm::Vector{Int})

Partition the indices `1:length(hashes)` into `2^p` partitions by the **top** `p` bits of each
hash: element `i` goes to partition `j = Int(hashes[i] >> (64 - p)) + 1` (`p = 0`: one
partition). `offsets` has `2^p + 1` entries, `offsets[1] == 1` and `offsets[end] == n + 1`;
`perm[offsets[j]:offsets[j+1]-1]` lists partition `j`'s elements in **ascending index order**
(stable, ADR-0003 rule 6).

A stable counting scatter: a histogram per task range (`ntasks` contiguous ranges of the input,
on `Threads.@spawn` tasks when `ntasks > 1`), prefix sums in (partition, task range) order, then
the scatter. The result does not depend on `ntasks`. The partitions take the high bits, and
[`KeyTable`](@ref)'s home slot the low bits, so a partition's table never degrades to one probe
chain. Frozen API (phase-4 spec §2.4). `0 <= p <= RADIX_MAX_BITS` and `ntasks >= 1`, else an
`ArgumentError`.
"""
function radix_partition(hashes::AbstractVector{UInt64}, p::Int; ntasks::Int = 1)
    Base.require_one_based_indexing(hashes)
    0 <= p <= RADIX_MAX_BITS ||
        throw(ArgumentError("radix_partition: p must be in 0:$RADIX_MAX_BITS, got $p"))
    ntasks >= 1 || throw(ArgumentError("radix_partition: ntasks must be >= 1, got $ntasks"))
    n = length(hashes)
    np = 1 << p
    nt = clamp(ntasks, 1, max(n, 1))
    shift = 64 - p
    hist = zeros(Int, np, nt)
    _radix_foreach(nt) do t
        _radix_histogram!(hist, t, hashes, _radix_range(n, nt, t), shift)
    end
    offsets = Vector{Int}(undef, np + 1)
    pos = Matrix{Int}(undef, np, nt)
    acc = 1
    @inbounds for j in 1:np
        offsets[j] = acc
        for t in 1:nt
            pos[j, t] = acc
            acc += hist[j, t]
        end
    end
    offsets[np + 1] = acc
    perm = Vector{Int}(undef, n)
    _radix_foreach(nt) do t
        _radix_scatter!(perm, pos, t, hashes, _radix_range(n, nt, t), shift)
    end
    return offsets, perm
end

# Task t's contiguous range of 1:n (nt ranges, sizes differ by at most one).
@inline _radix_range(n::Int, nt::Int, t::Int) = (div((t - 1) * n, nt) + 1):div(t * n, nt)

# Run f(t) for t in 1:nt: inline for one task, else one spawned task each (all waited for).
function _radix_foreach(f::F, nt::Int) where {F}
    nt == 1 && return (f(1); nothing)
    tasks = Vector{Task}(undef, nt)
    for t in 1:nt
        tasks[t] = Threads.@spawn f(t)
    end
    foreach(wait, tasks)
    return nothing
end

function _radix_histogram!(hist::Matrix{Int}, t::Int, hashes::AbstractVector{UInt64}, r::UnitRange{Int}, shift::Int)
    @inbounds for i in r
        j = Int(hashes[i] >> shift) + 1
        hist[j, t] += 1
    end
    return hist
end

function _radix_scatter!(perm::Vector{Int}, pos::Matrix{Int}, t::Int, hashes::AbstractVector{UInt64}, r::UnitRange{Int}, shift::Int)
    @inbounds for i in r
        j = Int(hashes[i] >> shift) + 1
        q = pos[j, t]
        perm[q] = i
        pos[j, t] = q + 1
    end
    return perm
end
