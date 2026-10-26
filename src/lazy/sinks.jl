# The hash-aggregate and grouped-window sinks (phase-4 spec §2.1, §2.3). Group-by lane.
#
# - `group_by ⨟ summarise` and `summarise(...; by)` with simple aggregates over plain key columns
#   of the streamed stage's output become a hash-aggregate sink: `execute` feeds the stage's
#   morsels to per-task partial aggregation (src/engine/hashagg.jl) instead of gathering them.
# - A grouped `mutate` after the gather runs as a grouped-window sink: `apply(::MutateStep)` on
#   sub-frames of contiguous group ranges, in parallel, scattered back in row order.

# ---------------------------------------------------------------------------------------------
# The hash-aggregate sink

_plainkey(k) = k isa Union{Symbol, AbstractString, Col}

"""
    _hashagg_plan(ph::Physical) -> (HashAggSpec, nsteps) | String | nothing

Whether the steps after the streamed stage start with a summary the hash-aggregate sink computes
(phase-4 spec §2.1): `group_by(keys...) ⨟ summarise(...)` (`nsteps = 2`) or
`summarise(...; by)` (`nsteps = 1`), with no row limit and an ungrouped scan, plain key columns
of the stage's output (concrete element types, or dictionary columns), and only simple
aggregates (`_simple_aggregate`) over the stage's columns. `nothing` when the steps start with
no summary; a `String` (for `explain`) saying why such a summary runs on the gathered frame
instead. Plans only: the stage's output schema comes from `_process_empty` (no data is read).
"""
function _hashagg_plan(ph)
    (ph.limit === nothing && isempty(ph.scan.groups) && !isempty(ph.rest)) || return nothing
    rest = ph.rest
    s1 = rest[1]
    if s1 isa GroupByStep
        (length(rest) >= 2 && rest[2] isa SummariseStep && !rest[2].reframe && rest[2].by === nothing) || return nothing
        s, nsteps, keysel, drop = rest[2], 2, s1.keys, something(s1.drop, true)
        isempty(s1.computed) || return "a computed group key"
        isempty(s1.keys) && return "no group keys"
        all(_plainkey, s1.keys) || return "group keys given by a selector"
    elseif s1 isa SummariseStep && !s1.reframe && s1.by !== nothing
        s, nsteps, keysel, drop = s1, 1, s1.by, true
        (_plainkey(keysel) || (keysel isa AbstractVector && all(_plainkey, keysel))) || return "`by` keys given by a selector"
    else
        return nothing
    end
    f0 = try
        _process_empty(ph)
    catch
        return "the stage's output schema is not known"
    end
    keys = try
        Symbol[f0.names[i] for i in resolve(keysel, f0)]
    catch
        return "a group key is not a column of the stage's output"
    end
    isempty(keys) && return "no group keys"
    for k in keys
        col = getcol(f0, k)
        col isa DictColumn || _keyable(eltype(col)) || return "the key column `$k` has an abstract element type"
    end
    all(o -> o isa Pair, s.outs) || return "across(…) outputs"
    names, nodes, aggs, cols = Symbol[], Any[], Any[], Union{Nothing, Symbol}[]
    for (nm, x) in s.outs
        x === nothing && return "an output removes a column"
        nm in keys && return "the output `$nm` is a group key"
        nm in names && return "two outputs named `$nm`"
        r = _simple_aggregate(x)
        r isa String && return r
        agg, c = r
        if c !== nothing
            c in names && return "refers to the earlier output `$c`"
            c in f0.names || return "`$c` is not a column of the stage's output"
        end
        push!(names, nm)
        push!(nodes, x)
        push!(aggs, agg)
        push!(cols, c)
    end
    dictmode = Bool[getcol(f0, k) isa DictColumn for k in keys]
    return HashAggSpec(keys, drop, names, nodes, aggs, cols, dictmode, s.groups, nsteps == 1), nsteps
end

# Does the first partition's `ndistinct` statistic of a key column pass the radix limit? Then the
# merge is partitioned from the start (ADR-0003 rule 9). Only a hint: the result never depends on it.
function _starts_radix(src, handles, keys::Vector{Symbol}, limit::Int)
    isempty(handles) && return false
    for k in keys
        nd = try
            partition_stats(src, handles[1], k).ndistinct
        catch
            nothing
        end
        nd isa Integer && nd > limit && return true
    end
    return false
end

"""
    _run_hashagg(ph, spec, part, handles, threads, stats) -> Frame

The hash-aggregate sink over the morsels `part(i)` (each already through the scan, the residual
and `_runstage(ph, f, kernel)`): `ntasks` contiguous morsel ranges (ADR-0003 rule 6), each folded
by one task (`_consume!`); the first failing morsel in morsel order is reported as a
`MorselError` (ADR-0003 rule 7); then the ordered merge and the final frame (src/engine/hashagg.jl).
"""
function _run_hashagg(ph, spec::HashAggSpec, part, handles, threads::Bool, stats)
    n = length(handles)
    limit = _radix_limit()                      # read once per collect (spec §0.3)
    ntasks = threads && Threads.nthreads() > 1 && n > 1 ? min(Threads.nthreads(), n) : 1
    stats.read = n
    stats.sink = :hashagg
    ntasks > 1 && (stats.parallel = true; stats.tasks = ntasks)
    gds = Union{Nothing, _GlobalDict}[dm ? _GlobalDict() : nothing for dm in spec.dictmode]
    tasks = [_AggTask(spec) for _ in 1:ntasks]
    errs = Vector{Any}(nothing, n)
    failed = Threads.Atomic{Int}(typemax(Int))   # lowest failing range
    function work(k)
        st = tasks[k]
        for i in _radix_range(n, ntasks, k)
            failed[] < k && break
            try
                f = part(i)
                i == 1 && (st.first = take(f, Int[]))
                _consume!(st, spec, f, gds, limit)
            catch err
                errs[i] = err
                Threads.atomic_min!(failed, k)
                break
            end
        end
        return nothing
    end
    if ntasks == 1
        work(1)
    else
        ts = [Threads.@spawn(work(k)) for k in 1:ntasks]
        for t in ts
            try
                wait(t)
            catch err
                throw(_taskerror(err))           # only outside the per-morsel try (a bug)
            end
        end
    end
    i = findfirst(!isnothing, errs)
    i === nothing || throw(MorselError(i, errs[i]))
    radix = _starts_radix(ph.scan.source, handles, spec.keys, limit)
    results = _hashagg_merge(tasks, spec; radix, threads = ntasks > 1)
    fallback() = something(tasks[1].first, _process_empty(ph))
    return _hashagg_finish(results, tasks, spec, fallback)
end

# ---------------------------------------------------------------------------------------------
# The grouped-window sink

# Split the groups of `gi` into at most `nr` contiguous ranges of about equal row counts.
function _window_ranges(gi::GroupIndex, nr::Int)
    ng = ngroups(gi)
    n = gi.starts[end] - 1
    ranges = UnitRange{Int}[]
    lo = 1
    for g in 1:(ng - 1)
        length(ranges) == nr - 1 && break
        # close the range at g once the rows up to g reach the next share
        if gi.starts[g + 1] - 1 >= (length(ranges) + 1) * n / nr
            push!(ranges, lo:g)
            lo = g + 1
        end
    end
    push!(ranges, lo:ng)
    return ranges
end

# The rows of the groups `r` (in group order) as a frame with its own group index over them.
function _subframe(f::Frame, gi::GroupIndex, r::UnitRange{Int})
    lo, hi = gi.starts[first(r)], gi.starts[last(r) + 1] - 1
    rows = gi.perm[lo:hi]
    ids = Vector{Int}(undef, length(rows))
    for (k, g) in enumerate(r), q in (gi.starts[g] - lo + 1):(gi.starts[g + 1] - lo)
        ids[q] = k
    end
    starts = gi.starts[first(r):(last(r) + 1)] .- (lo - 1)
    sgi = GroupIndex(ids, collect(1:length(rows)), starts, AbstractColumn[take(k, collect(r)) for k in gi.keys])
    sub = Frame(copy(f.names), AbstractColumn[take(c, rows) for c in f.columns], copy(f.groups), sgi, length(rows), f.drop)
    return sub, rows
end

# One output column scattered back in row order from the ranges' columns: a dictionary column
# when every range kept one dictionary, else the values under the ranges' promoted element type
# (narrowed by value when that type is not known, as `typed_column` does).
function _scatter_column(parts::Vector{AbstractColumn}, rowsets::Vector{Vector{Int}}, n::Int)
    p1 = parts[1]
    if p1 isa DictColumn && all(p -> p isa typeof(p1) && p.dict === p1.dict, parts)
        codes = Vector{eltype(p1.codes)}(undef, n)
        val = p1.validity === nothing ? nothing : trues(n)
        for (p, rows) in zip(parts, rowsets), (k, r) in enumerate(rows)
            codes[r] = p.codes[k]
            val === nothing || (val[r] = p.validity[k])
        end
        return DictColumn(codes, p1.dict, val)
    end
    E = Union{}
    for (p, rows) in zip(parts, rowsets)
        isempty(rows) || (E = promote_type(E, eltype(p)))
    end
    E === Union{} && (E = eltype(p1))
    v = Vector{E}(undef, n)
    for (p, rows) in zip(parts, rowsets), (k, r) in enumerate(rows)
        v[r] = p[k]
    end
    return column(isconcretetype(E) || isconcretetype(nonmissingtype(E)) ? v : _narrowvec(v))
end

"""
    _window_apply(s::MutateStep, f::Frame, nr::Int) -> Frame

A grouped `mutate` (on a grouped `f`, or with `by`) as the grouped-window sink (phase-4 spec
§2.1): the groups split into at most `nr` contiguous ranges of about equal row counts
(ADR-0003 rule 6); each range runs the existing `apply(::MutateStep)` on its sub-frame (its rows
in group order, with the group index of those groups), on its own task when `nr > 1`; the computed
columns are scattered back in row order, and every other column is the input's own column
object. Same result as `apply(s, f)`; the first failing range (in range order) raises.
"""
function _window_apply(s::MutateStep, f0::Frame, nr::Int)
    any(o -> o isa Across, s.outs) && return apply(s, f0)
    f, by = _withby(f0, s.by, "mutate")
    gi = gindex(f)
    (gi === nothing || nr <= 1 || ngroups(gi) <= 1) && return apply(s, f0)
    ranges = _window_ranges(gi, nr)
    length(ranges) <= 1 && return apply(s, f0)
    s2 = MutateStep(s.outs, nothing, s.keep, s.before, s.after)
    subs = [_subframe(f, gi, r) for r in ranges]
    outs = Vector{Frame}(undef, length(ranges))
    errs = Vector{Any}(nothing, length(ranges))
    _radix_foreach(length(ranges)) do k
        try
            outs[k] = apply(s2, subs[k][1])
        catch err
            errs[k] = err
        end
    end
    k = findfirst(!isnothing, errs)
    k === nothing || throw(errs[k])
    computed = Set{Symbol}(o.first for o in s.outs if o isa Pair && o.second !== nothing)
    rowsets = Vector{Int}[sub[2] for sub in subs]
    names = copy(outs[1].names)
    cols = AbstractColumn[
        nm in computed ? _scatter_column(AbstractColumn[getcol(o, nm) for o in outs], rowsets, f.nrow) : getcol(f, nm)
            for nm in names
    ]
    by === nothing || return Frame(names, cols, Symbol[], nothing, f.nrow)
    return Frame(names, cols, copy(f.groups), gi, f.nrow, f.drop)
end

# A grouped mutate with threads to spare goes through the grouped-window sink.
function _apply_rest(s::MutateStep, f::Frame, threads::Bool)
    nr = threads ? Threads.nthreads() : 1
    (nr > 1 && (isgrouped(f) || s.by !== nothing)) || return apply(s, f)
    all(o -> !(o isa Pair) || o.second === nothing || isrowwise(o.second), s.outs) && return apply(s, f)
    return _window_apply(s, f, nr)
end
_apply_rest(s::Step, f::Frame, ::Bool) = apply(s, f)

# Is `rest[i]` a grouped mutate (with `by`, or right after a `group_by`)?
_grouped_mutate(rest, i) = rest[i] isa MutateStep && (rest[i].by !== nothing || (i > 1 && rest[i - 1] isa GroupByStep))

# ---------------------------------------------------------------------------------------------
# The rest of the steps

"""
    run_rest(ph::Physical, out::Frame; morsel, threads, from = 1) -> Frame

Run the steps after the streamed stage, `ph.rest[from:end]`, on `out` (the gathered frame, or
the hash-aggregate sink's result with `from` past the summary): each step through its eager
operator, a grouped `mutate` through the grouped-window sink when threads are available.
"""
function run_rest(ph, out; morsel::Int = DEFAULT_MORSEL, threads::Bool = true, from::Int = 1)
    for s in ph.rest[from:end]
        out = _apply_rest(s, out, threads)
    end
    return out
end

"`explain`'s lines for what runs after the streamed stage: the hash-aggregate sink, or the gather and the eager steps (with why a summary there is not a sink)."
function _explain_rest(io::IO, ph)
    p = _hashagg_plan(ph)
    if p isa Tuple
        _, nsteps = p
        println(io, "  then hash-aggregate sink: ", join(string.(ph.rest[1:nsteps]), " ⨟ "))
        println(io, "    each task folds a contiguous morsel range (typed keys and accumulators; past the radix limit its table flushes into radix partitions)")
        println(io, "    merged per partition in morsel order, groups sorted by the keys; no gathered frame")
        nsteps < length(ph.rest) && println(io, "  then eagerly: ", join(string.(ph.rest[(nsteps + 1):end]), " ⨟ "))
        _explain_windows(io, ph.rest, nsteps + 1)
        return nothing
    end
    println(io, "  then materialize (concatenate in morsel order)")
    isempty(ph.rest) || println(io, "  then eagerly: ", join(string.(ph.rest), " ⨟ "))
    p isa String && println(io, "    no hash-aggregate sink: ", p)
    _explain_windows(io, ph.rest, 1)
    return nothing
end
function _explain_windows(io::IO, rest, from::Int)
    for i in from:length(rest)
        _grouped_mutate(rest, i) &&
            println(io, "    ", rest[i], ": grouped-window sink when threads > 1 (contiguous group ranges in parallel, scattered back in row order)")
    end
    return nothing
end
