# Row verbs: arrange, the slices, distinct and the counting verbs.

# arrange (ADR-0002 rule 13)

struct ArrangeStep <: Step
    keys::Vector{Node}
    by_group::Bool
    locale::Union{Nothing, String}
end
ArrangeStep(keys::Vector{Node}, by_group::Bool) = ArrangeStep(keys, by_group, nothing)
"""
    arrange(keys...; by_group = false, locale = nothing)

Sort rows, stably: non-NaN, non-`missing` values first (`-0.0` and `0.0` tied), then NaN and
`missing` as one tie class in input order, in both directions; `desc(x)` reverses only the first
part (ADR-0002 rule 13). Grouping is ignored unless `by_group = true`.

Strings sort by code point (Julia's `isless`, the same as byte order of UTF-8): the `"C"`
locale, which is also dplyr 1.2.0's default (`.locale = NULL` means `"C"` unless the
`dplyr.legacy_locale` option is set). `locale` accepts `nothing` or `"C"`; any other locale is
an `ArgumentError`, because ChuiFrames has no ICU collation (dplyr uses stringi for those).
"""
function arrange(keys...; by_group::Bool = false, locale::Union{Nothing, AbstractString} = nothing)
    locale === nothing || locale == "C" ||
        throw(ArgumentError("arrange: locale = $(repr(locale)) is not supported; only locale = \"C\" (code-point order, dplyr's default) is available, because ChuiFrames has no ICU collation"))
    return ArrangeStep(Node[_ordnode(k) for k in keys], by_group, locale === nothing ? nothing : String(locale))
end
Base.show(io::IO, s::ArrangeStep) = print(
    io, "arrange(", join(s.keys, ", "), s.by_group ? "; by_group = true" : "",
    s.locale === nothing ? "" : (s.by_group ? ", " : "; ") * "locale = $(repr(s.locale))", ")"
)

function _orderperm(keys::Vector, revs::Vector{Bool}, n::Int)
    function lt(i, j)
        for (v, rev) in zip(keys, revs)
            a, b = v[i], v[j]
            ta, tb = _istail(a), _istail(b)
            ta && tb && continue
            ta && return false
            tb && return true
            _ltval(a, b, rev) && return true
            _ltval(b, a, rev) && return false
        end
        return false
    end
    return sort!(collect(1:n); lt = lt, alg = MergeSort)
end

function apply(s::ArrangeStep, f::Frame)
    ks = copy(s.keys)
    s.by_group && (ks = Node[[Col(g) for g in f.groups]; ks])
    isempty(ks) && return f
    env = Env(f)
    vals = Any[]
    revs = Bool[]
    for k in ks
        rev = k isa Desc
        push!(vals, _fitcol(ev(rev ? k.inner : k, env), f.nrow))
        push!(revs, rev)
    end
    return take(f, _orderperm(vals, revs, f.nrow))
end

# =============================================================================================
# Row slices: head, slice_head, slice_tail, slice, slice_min, slice_max, slice_sample

struct HeadStep <: Step
    n::Int
end
"`head(n = 6)`: the first `n` rows, ignoring groups (negative `n`: all but the last `-n`). `first(3)` is Base's, so the verb is `head` (CF-009)."
head(n::Integer = 6) = HeadStep(Int(n))
Base.show(io::IO, s::HeadStep) = print(io, "head(", s.n, ")")
function apply(s::HeadStep, f::Frame)
    out = take(f, collect(1:(s.n >= 0 ? min(s.n, f.nrow) : max(f.nrow + s.n, 0))))
    # dplyr's head goes through `[.grouped_df`, which regroups: with `drop = false` only the
    # empty dictionary levels survive, not every earlier group (review m1)
    return f.drop ? out : regroup(out, out.groups; drop = false)
end

_count(len, n, prop) = n !== nothing ? (n >= 0 ? min(n, len) : max(len + n, 0)) :
    (prop >= 0 ? min(floor(Int, prop * len), len) : max(len + floor(Int, prop * len), 0))
function _nprop(verb, n, prop)
    n !== nothing && prop !== nothing && throw(ArgumentError("$verb: give n or prop, not both"))
    return (n === nothing && prop === nothing) ? (1, nothing) : (n, prop)
end

struct SliceStep <: Step
    kind::Symbol
    n::Union{Nothing, Int}
    prop::Union{Nothing, Float64}
    idx::Vector{Any}
    order::Union{Nothing, Node}
    with_ties::Bool
    na_rm::Bool
    replace::Bool
    rng::Any
    weight::Union{Nothing, Node}
end
_slice(kind; n = nothing, prop = nothing, idx = Any[], order = nothing, with_ties = true, na_rm = false, replace = false, rng = nothing, weight = nothing) =
    SliceStep(kind, n === nothing ? nothing : Int(n), prop === nothing ? nothing : Float64(prop), idx, order, with_ties, na_rm, replace, rng, weight)

"`slice_head(; n = 1, prop)`: the first `n` rows (or fraction `prop`) of each group."
slice_head(; n = nothing, prop = nothing) = _slice(:head; (k => v for (k, v) in zip((:n, :prop), _nprop("slice_head", n, prop)))...)
"`slice_tail(; n = 1, prop)`: the last `n` rows (or fraction `prop`) of each group."
slice_tail(; n = nothing, prop = nothing) = _slice(:tail; (k => v for (k, v) in zip((:n, :prop), _nprop("slice_tail", n, prop)))...)
"`slice(idx...)`: rows by position within each group (Ints, ranges, vectors, `Not(...)`); out-of-range positions are ignored."
slice(idx...) = _slice(:slice; idx = Any[idx...])
"`slice_min(order; n = 1, prop, with_ties = true, na_rm = false)`: the rows with the smallest values of `order`, per group."
slice_min(order; n = nothing, prop = nothing, with_ties::Bool = true, na_rm::Bool = false) =
    _slice(:min; (k => v for (k, v) in zip((:n, :prop), _nprop("slice_min", n, prop)))..., order = _ordnode(order), with_ties, na_rm)
"`slice_max(order; n = 1, prop, with_ties = true, na_rm = false)`: the rows with the largest values of `order`, per group."
slice_max(order; n = nothing, prop = nothing, with_ties::Bool = true, na_rm::Bool = false) =
    _slice(:max; (k => v for (k, v) in zip((:n, :prop), _nprop("slice_max", n, prop)))..., order = _ordnode(order), with_ties, na_rm)
"""
    slice_sample(; n = 1, prop, replace = false, weight_by = nothing, rng)

Random rows of each group. Pass `rng` (an `AbstractRNG`) for reproducible draws; the stream
differs from R's, so only properties are comparable.

`weight_by` (a column expression such as `c.w`, or a column name) gives sampling weights,
evaluated per group; they need not sum to 1. Without replacement, rows are drawn one at a time
with probability proportional to the remaining weights (as R's `sample.int`), so a zero-weight
row is never drawn. As in dplyr 1.2.0 (whose errors come from `sample.int`), an `ArgumentError`
is raised for a `missing`, NaN, infinite or negative weight, a non-numeric weight, a constant
(one value, not one per row), and for more rows than positive weights (without replacement) or
no positive weight (with it). A group drawing no rows checks nothing, as dplyr.
"""
function slice_sample(; n = nothing, prop = nothing, replace::Bool = false, weight_by = nothing, rng = nothing)
    weight_by === nothing || weight_by isa Union{Node, Symbol, AbstractString} ||
        throw(ArgumentError("slice_sample: weight_by must be a column expression (c.w) or a column name, got $(repr(weight_by))"))
    w = weight_by === nothing ? nothing : weight_by isa AbstractString ? Col(Symbol(weight_by)) : _ordnode(weight_by)
    return _slice(:sample; (k => v for (k, v) in zip((:n, :prop), _nprop("slice_sample", n, prop)))..., replace, rng, weight = w)
end

function Base.show(io::IO, s::SliceStep)
    name = Dict(:head => "slice_head", :tail => "slice_tail", :slice => "slice", :min => "slice_min", :max => "slice_max", :sample => "slice_sample")[s.kind]
    parts = String[]
    s.kind === :slice && append!(parts, repr.(s.idx))
    s.order === nothing || push!(parts, repr(s.order))
    kws = String[]
    s.kind === :slice || (s.n === nothing ? push!(kws, "prop = $(s.prop)") : push!(kws, "n = $(s.n)"))
    s.kind === :sample && s.replace && push!(kws, "replace = true")
    s.weight === nothing || push!(kws, "weight_by = $(s.weight)")
    return print(io, name, "(", join(parts, ", "), isempty(kws) ? "" : "; " * join(kws, ", "), ")")
end

# Sampling weights of one group, checked as R's `sample.int` does (via dplyr 1.2.0).
function _weights(w::Node, f::Frame, rows)
    v = ev(w, subenv(Env(f), rows))
    v isa Scalar && throw(ArgumentError("slice_sample: weight_by = $w gave one value; it must give one weight per row (dplyr: `weight_by` must have size n)"))
    length(v) == length(rows) || throw(DimensionMismatch("slice_sample: weight_by = $w gave $(length(v)) weights for $(length(rows)) rows"))
    out = Vector{Float64}(undef, length(v))
    for (i, x) in enumerate(v)
        ismissing(x) && throw(ArgumentError("slice_sample: weight_by = $w has a missing weight (R: NA in probability vector)"))
        x isa Real || throw(ArgumentError("slice_sample: weight_by = $w must be numeric, got a $(typeof(x)) value"))
        isfinite(x) || throw(ArgumentError("slice_sample: weight_by = $w has a non-finite weight $x (R: NA in probability vector)"))
        x < 0 && throw(ArgumentError("slice_sample: weight_by = $w has a negative weight $x"))
        out[i] = Float64(x)
    end
    return out
end

# `k` draws from `1:length(w)` with probability proportional to `w` (sequentially without
# replacement: each drawn row's weight is removed).
function _wsample(rng, w::Vector{Float64}, k::Int, replace::Bool)
    k == 0 && return Int[]
    unif() = rng === nothing ? Base.rand() : Base.rand(rng)
    npos = count(>(0), w)
    if replace
        npos == 0 && throw(ArgumentError("slice_sample: no positive weight to draw from (R: too few positive probabilities)"))
    else
        npos < k && throw(ArgumentError("slice_sample: $k rows requested without replacement but only $npos positive weights (R: too few positive probabilities)"))
    end
    w = copy(w)
    out = Vector{Int}(undef, k)
    for d in 1:k
        u = unif() * sum(w)
        acc = 0.0
        pick = 0
        for i in eachindex(w)
            w[i] > 0 || continue
            acc += w[i]
            if acc > u
                pick = i
                break
            end
        end
        pick == 0 && (pick = findlast(>(0), w))   # rounding at the top end
        out[d] = pick
        replace || (w[pick] = 0.0)
    end
    return out
end

function _positions(idx::Vector{Any}, len::Int)
    out = Int[]
    for x in idx
        if x isa InvertedIndices.InvertedIndex
            drop = Set(_positions(Any[x.skip], len))
            append!(out, [i for i in 1:len if !(i in drop)])
        elseif x isa Integer
            x < 0 && throw(ArgumentError("slice: negative positions are R's; write slice(Not($(-x)))"))
            1 <= x <= len && push!(out, x)
        elseif x isa AbstractVector || x isa AbstractRange
            append!(out, _positions(Any[y for y in x], len))
        else
            throw(ArgumentError("slice: expected positions, got $(repr(x))"))
        end
    end
    return out
end

function _sample(rng, len::Int, k::Int, replace::Bool)
    draw(m) = rng === nothing ? Base.rand(1:m) : Base.rand(rng, 1:m)
    replace && return [draw(len) for _ in 1:k]
    p = collect(1:len)
    for i in 1:min(k, len)
        j = i - 1 + draw(len - i + 1)
        p[i], p[j] = p[j], p[i]
    end
    return p[1:min(k, len)]
end

function apply(s::SliceStep, f::Frame)
    rowsets = _rowsets(f)
    order = nothing
    if s.order !== nothing
        rev = (s.kind === :max) ⊻ (s.order isa Desc)
        inner = s.order isa Desc ? s.order.inner : s.order
        order = (_fitcol(ev(inner, Env(f)), f.nrow), rev)
    end
    keep = Int[]
    for rows in rowsets
        len = length(rows)
        if s.kind === :head
            append!(keep, rows[1:_count(len, s.n, s.prop)])
        elseif s.kind === :tail
            k = _count(len, s.n, s.prop)
            append!(keep, rows[(len - k + 1):len])
        elseif s.kind === :slice
            append!(keep, rows[_positions(s.idx, len)])
        elseif s.kind === :sample
            sn = s.n
            k = sn !== nothing ? sn : floor(Int, something(s.prop, 0.0) * len)
            k = s.replace ? max(k, 0) : _count(len, k, nothing)
            if s.weight === nothing
                append!(keep, rows[_sample(s.rng, len, k, s.replace)])
            elseif k > 0   # dplyr's sample_int returns integer(0) before any weight check
                w = _weights(s.weight, f, rows)
                append!(keep, rows[_wsample(s.rng, w, k, s.replace)])
            end
        else
            v, rev = order
            gv = v[rows]
            cand = s.na_rm ? [i for i in 1:len if !_istail(gv[i])] : collect(1:len)
            p = cand[_orderperm(Any[gv[cand]], [rev], length(cand))]
            k = _count(length(p), s.n, s.prop)
            if s.with_ties && 0 < k < length(p)
                last_ = gv[p[k]]
                while k < length(p) && _tied(gv[p[k + 1]], last_)
                    k += 1
                end
            end
            append!(keep, rows[p[1:k]])
        end
    end
    return take(f, keep)
end
_tied(a, b) = (_istail(a) && _istail(b)) || (!_istail(a) && !_istail(b) && isequal(_ordkey(a), _ordkey(b)))

# =============================================================================================
# distinct, count_by, tally, add_count, add_tally (key equality: ADR-0003 rule 8)

struct DistinctStep <: Step
    items::Vector{Any}
    keep_all::Bool
end
"""
    distinct(cols...; keep_all = false)

Unique rows (over all columns, or over `cols`, which may be names, selectors or `:new => expr`),
keeping the first occurrence of each, in order of first appearance. Key equality is ADR-0003
rule 8's. With `keep_all = true`, the other columns of the first occurrence are kept.
"""
distinct(items...; keep_all::Bool = false) = DistinctStep(Any[i isa Pair ? Symbol(i.first) => node(i.second) : i for i in items], keep_all)
Base.show(io::IO, s::DistinctStep) = print(io, "distinct(", join([x isa Pair ? "$(repr(x.first)) => $(x.second)" : _selrepr(x) for x in s.items], ", "), s.keep_all ? "; keep_all = true" : "", ")")
function apply(s::DistinctStep, f::Frame)
    comp = [x for x in s.items if x isa Pair]
    isempty(comp) || (f = apply(MutateStep(_outs(comp), nothing, :all, nothing, nothing), f))
    keys = isempty(s.items) ? copy(f.names) :
        unique!([f.groups; Symbol[x isa Pair ? x.first : n for x in s.items for n in (x isa Pair ? [x.first] : f.names[resolve(x, f)])]])
    _, firstrows = rowcodes(AbstractVector[getcol(f, k) for k in keys], f.nrow)
    g = take(f, firstrows)
    s.keep_all && return g
    sel = [i for (i, n) in enumerate(g.names) if n in keys]
    return Frame(g.names[sel], g.columns[sel], copy(g.groups), g.gindex, g.nrow, g.drop)   # keys hold the groups
end

struct CountStep <: Step
    items::Vector{Any}
    wt::Any
    sort::Bool
    name::Union{Nothing, Symbol}
    add::Bool
end
"""
    count_by(cols...; wt = nothing, sort = false, name = :n)

Count rows per combination of `cols` (and the existing groups): dplyr's `count`, renamed
because `count(c.flag)` is Base's reduction (CF-009). `wt` sums a weight column (missing
weights skipped, as dplyr). `sort = true` puts the largest counts first. Keeps the input's
grouping.
"""
count_by(items...; wt = nothing, sort::Bool = false, name = nothing) = CountStep(Any[items...], wt, sort, name === nothing ? nothing : Symbol(name), false)
"`tally(; wt, sort, name)`: count rows per existing group (`count_by()` with no columns, dropping the last grouping level)."
tally(; wt = nothing, sort::Bool = false, name = nothing) = CountStep(Any[:__tally__], wt, sort, name === nothing ? nothing : Symbol(name), false)
"`add_count(cols...; wt, sort, name)`: add the per-combination count as a column, keeping every row."
add_count(items...; wt = nothing, sort::Bool = false, name = nothing) = CountStep(Any[items...], wt, sort, name === nothing ? nothing : Symbol(name), true)
"`add_tally(; wt, sort, name)`: add the per-group count as a column."
add_tally(; wt = nothing, sort::Bool = false, name = nothing) = CountStep(Any[], wt, sort, name === nothing ? nothing : Symbol(name), true)
Base.show(io::IO, s::CountStep) = print(io, s.add ? "add_count(" : "count_by(", join([x isa Pair ? "$(repr(x.first)) => $(x.second)" : _selrepr(x) for x in s.items], ", "), ")")

function _countname(f::Frame, name)
    name !== nothing && return name
    nm = :n
    while hascolumn(f, nm)
        nm = Symbol(nm, :n)
    end
    return nm
end
function apply(s::CountStep, f::Frame)
    istally = s.items == Any[:__tally__]
    items = istally ? Any[] : s.items
    comp = [x for x in items if x isa Pair]
    isempty(comp) || (f = apply(MutateStep(_outs(Symbol(p.first) => node(p.second) for p in comp), nothing, :all, nothing, nothing), f))
    keys = Symbol[x isa Pair ? Symbol(x.first) : n for x in items for n in (x isa Pair ? [Symbol(x.first)] : f.names[resolve(x, f)])]
    allkeys = unique!([f.groups; keys])
    nm = _countname(f, s.name)
    wt = s.wt === nothing ? nothing : _ordnode(s.wt)
    nnode = wt === nothing ? NRows() : Reduce(:sum, SkipMiss(wt), (), (), _NOKW)
    # the existing groups are counted as they are (empty ones too, with drop = false); extra keys
    # regroup, with the input's drop flag (dplyr's `.drop = group_by_drop_default(x)`)
    g = allkeys == f.groups ? f : regroup(f, allkeys; drop = f.drop)
    if s.add
        out = apply(MutateStep(_outs((nm => nnode,)), nothing, :all, nothing, nothing), g)
        out = Frame(copy(out.names), copy(out.columns), copy(f.groups), allkeys == f.groups ? out.gindex : nothing, out.nrow, f.drop)
        s.sort && (out = apply(ArrangeStep(Node[Desc(Col(nm))], false), out))
        return out
    end
    groupsafter = istally ? :drop_last : :drop
    out = apply(SummariseStep(_outs((nm => nnode,)), nothing, groupsafter, false), g)
    out = istally ? out : (isempty(f.groups) ? out : regroup(out, copy(f.groups); drop = f.drop))
    s.sort && (out = apply(ArrangeStep(Node[Desc(Col(nm))], false), out))
    return out
end
