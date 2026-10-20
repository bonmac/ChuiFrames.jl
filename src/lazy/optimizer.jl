# The rule-based optimizer (spec §5; ADR-0003 rule 4). Ordered passes, each a bottom-up rewrite
# of the plan (`Upstream.cata` over the plan functor) repeated to a fixpoint, at most
# `MAX_FIXPOINT` iterations. Every rule that fires is logged for `explain`. Every rule obeys
# spec §1's R-total: it skips evaluating a step on some rows only when that step is total.

const MAX_FIXPOINT = 100

"The optimizer's log: rules fired, in order, and passes that hit the fixpoint cap."
struct OptLog
    fired::Vector{String}
    capped::Vector{String}
end
OptLog() = OptLog(String[], String[])

function _fixpoint(pass, plan, name::String, log::OptLog; cap::Int = MAX_FIXPOINT)
    for _ in 1:cap
        new = pass(plan, log)
        new == plan && return plan
        plan = new
    end
    push!(log.capped, name)
    return plan
end

# A bottom-up pass from a local rule `rule(node, log) -> node` (catamorphism, ChuiCore R6).
_bottomup(rule) = (plan, log) -> UP.cata(n -> rule(n, log), plan)

"""
    optimize(q::LazyFrame) -> LazyFrame

The optimized plan of `q` (spec §5): constant folding, filter splitting, predicate pushdown,
projection pushdown and limit pushdown, in that order, each to a fixpoint. `explain(q)` shows
the rules that fired.
"""
optimize(q::LazyFrame) = LazyFrame(first(optimize_plan(q.plan)))

"`optimize_plan(plan; cap) -> (plan, log::OptLog)`."
function optimize_plan(plan; cap::Int = MAX_FIXPOINT)
    log = OptLog()
    plan = _fixpoint(_bottomup(_fold_rule), plan, "constant folding", log; cap)
    plan = _fixpoint(_bottomup(_split_rule), plan, "filter splitting", log; cap)
    plan = _fixpoint(_bottomup(_pushdown_rule), plan, "predicate pushdown", log; cap)
    plan = _projection(plan, log)
    plan = _fixpoint(_bottomup(_limit_rule), plan, "limit pushdown", log; cap)
    return plan, log
end

# ---------------------------------------------------------------------------------------------
# 1. Constant folding: a `Call` of scalar literals becomes a literal, when the call does not
# throw and its declared (static) type is the type of its value, so every type-directed check
# (a filter's Bool check, ADR-0002 rule 11) sees the same type.

const _NOCTX = SelectCtx(Symbol[], Type[], Symbol[])

_fold(x::Node) = x
function _fold(x::Call)
    args = Node[_fold(a) for a in x.args]
    y = args == x.args ? x : Call(x.f, args)
    all(a -> a isa Lit && a.scalar, args) || return y
    v = try
        x.f((a.value for a in args)...)
    catch
        return y
    end
    T = try
        static_type(y, _NOCTX)
    catch
        return y
    end
    return T === typeof(v) ? Lit(v, true) : y
end

function _fold_rule(n, log::OptLog)
    n isa StepNode || return n
    s = n.step
    if s isa FilterStep
        ps = Node[_fold(p) for p in s.preds]
        ps == s.preds && return n
        push!(log.fired, "constant folding: $(s) → $(FilterStep(ps, s.out))")
        return StepNode(FilterStep(ps, s.out), n.child)
    elseif s isa MutateStep && all(o -> o isa Pair, s.outs)
        outs = Output[o.second isa Node ? Pair{Symbol, Any}(o.first, _fold(o.second)) : o for o in s.outs]
        all(i -> isequal(outs[i].second, s.outs[i].second), eachindex(outs)) && return n
        t = MutateStep(outs, s.by, s.keep, s.before, s.after)
        push!(log.fired, "constant folding: $(s) → $(t)")
        return StepNode(t, n.child)
    end
    return n
end

# ---------------------------------------------------------------------------------------------
# 2. Filter splitting: a filter whose conjuncts are all total becomes one filter per conjunct.

function _split_rule(n, log::OptLog)
    (n isa StepNode && n.step isa FilterStep && !n.step.out) || return n
    cs = Node[c for p in n.step.preds for c in conjuncts(p)]
    length(cs) > 1 || return n
    sch = node_schema(n.child)
    sch === nothing && return n
    types = _typedict(sch)
    all(c -> istotal(c, types), cs) || return n
    push!(log.fired, "filter splitting: $(n.step) → $(length(cs)) filters")
    return foldl((acc, c) -> StepNode(FilterStep(Node[c], false), acc), cs; init = n.child)
end

# ---------------------------------------------------------------------------------------------
# 3. Predicate pushdown: a total filter moves below name-only steps and total filter_outs, and
# into an ungrouped, unlimited scan.

_rename(x::Col, m::Dict{Symbol, Symbol}) = Col(get(m, x.name, x.name))
_rename(x::Call, m::Dict{Symbol, Symbol}) = Call(x.f, Node[_rename(a, m) for a in x.args])
_rename(x::Node, ::Dict{Symbol, Symbol}) = x

_reads(x::Node) = _usedcols!(Set{Symbol}(), x)

function _totalfilter(n::StepNode, out::Bool)
    s = n.step
    (s isa FilterStep && s.out == out) || return false
    sch = node_schema(n.child)
    sch === nothing && return false
    types = _typedict(sch)
    return all(p -> istotal(p, types), s.preds)
end

function _pushdown_rule(n, log::OptLog)
    (n isa StepNode && _totalfilter(n, false)) || return n
    f = n.step::FilterStep
    below = n.child
    if below isa ScanNode
        (isempty(below.groups) && below.limit === nothing) || return n
        push!(log.fired, "predicate pushdown: $(f) into the scan")
        return ScanNode(below.source, below.select, Node[below.preds; f.preds], nothing, below.groups, below.drop)
    end
    below isa StepNode || return n
    s = below.step
    if s isa FilterStep && s.out && _totalfilter(below, true)
        push!(log.fired, "predicate pushdown: $(f) below $(s)")
        return StepNode(s, StepNode(f, below.child))
    end
    _isnameonly(s) || return n
    sch = node_schema(below.child)
    sch === nothing && return n
    m = name_map(s, sch...)
    m === nothing && return n
    back = Dict{Symbol, Symbol}(m)            # output name => input name
    all(c -> haskey(back, c), union((_reads(p) for p in f.preds)...)) || return n
    g = FilterStep(Node[_rename(p, back) for p in f.preds], false)
    push!(log.fired, "predicate pushdown: $(f) below $(s)")
    return StepNode(s, StepNode(g, below.child))
end

# ---------------------------------------------------------------------------------------------
# 4. Projection pushdown: the source columns the plan reads become the scan's `select`. Only
# source columns are dropped; no computation is removed (spec §5).

_plainname(x) = x isa Union{Symbol, AbstractString, Col}
_nm(x::Union{Symbol, AbstractString}) = Symbol(x)
_nm(x::Col) = x.name

# Columns needed below step `s` given those needed above (`nothing`: every column), or
# `nothing` when `s` cannot be analysed (selectors, across, options that depend on the schema).
function _need_in(s::Step, need::Union{Nothing, AbstractSet{Symbol}})
    if s isa FilterStep
        need === nothing && return nothing
        all(p -> !_hasselector(p), s.preds) || return nothing
        return union(need, (_reads(p) for p in s.preds)...)
    elseif s isa ArrangeStep
        need === nothing && return nothing
        all(p -> !_hasselector(p), s.keys) || return nothing
        return union(need, (_reads(p) for p in s.keys)...)
    elseif s isa HeadStep
        return need
    elseif s isa SelectStep
        out = Set{Symbol}()
        for it in s.items
            if _plainname(it)
                push!(out, _nm(it))
            elseif it isa Pair && it.second isa Node && !_hasselector(it.second)
                union!(out, _reads(it.second))
            else
                return nothing
            end
        end
        return out
    elseif s isa RenameStep
        need === nothing && return nothing
        back = Dict{Symbol, Symbol}(p.first => p.second for p in s.pairs)
        # the old names must exist, and the new names too when they already exist: `rename`
        # raises on the duplicate, so dropping either would hide eager's error (review B2)
        return union!(Set{Symbol}(get(back, c, c) for c in need), Symbol[p.second for p in s.pairs], Symbol[p.first for p in s.pairs])
    elseif s isa MutateStep
        (need === nothing || s.keep !== :all || s.before !== nothing || s.after !== nothing) && return nothing
        by = _plainnames(s.by)
        by === nothing && return nothing
        out = union(need, by)
        for o in s.outs
            o isa Pair || return nothing
            push!(out, o.first)
            o.second === nothing && continue
            (o.second isa Node && !_hasselector(o.second)) || return nothing
            union!(out, _reads(o.second))
        end
        return out
    elseif s isa GroupByStep
        (need === nothing || s.add) && return nothing
        out = copy(need)
        for k in s.keys
            _plainname(k) || return nothing
            push!(out, _nm(k))
        end
        for (k, x) in s.computed
            _hasselector(x) && return nothing
            union!(out, _reads(x))
        end
        return out
    elseif s isa SummariseStep
        by = _plainnames(s.by)
        by === nothing && return nothing
        out = Set{Symbol}(by)
        for o in s.outs
            (o isa Pair && o.second isa Node && !_hasselector(o.second)) || return nothing
            union!(out, _reads(o.second))
        end
        return out
    end
    return nothing
end
_plainnames(::Nothing) = Symbol[]
_plainnames(x) = _plainname(x) ? [_nm(x)] : (x isa AbstractVector && all(_plainname, x) ? Symbol[_nm(v) for v in x] : nothing)

# Selectors inside an expression (if_any/if_all) resolve against the schema: not analysable.
_hasselector(::IfAnyAll) = true
_hasselector(x::Union{Call, Window}) = any(_hasselector, x.args)
_hasselector(x::Union{Reduce, Pipe}) = _hasselector(x.arg)
_hasselector(x::Union{Desc, SkipMiss}) = _hasselector(x.inner)
_hasselector(x::CaseWhen) = any(_hasselector, x.conds) || any(_hasselector, x.vals) || _hasselector(x.default)
_hasselector(::Node) = false

function _projection(plan, log::OptLog)
    scan, steps = linearize(plan)
    (isempty(scan.groups) && scan.select === nothing) || return plan
    need = nothing
    for s in reverse(steps)
        need = _need_in(s, need)
    end
    need === nothing && return plan
    for p in scan.preds
        union!(need, _reads(p))
    end
    names = collect(Symbol, source_schema(scan.source).names)
    sel = Symbol[c for c in names if c in need]
    length(sel) < length(names) || return plan
    push!(log.fired, "projection pushdown: the scan reads $(length(sel)) of $(length(names)) columns ($(join(sel, ", ")))")
    return build(ScanNode(scan.source, sel, scan.preds, scan.limit, scan.groups, scan.drop), steps)
end

# ---------------------------------------------------------------------------------------------
# 5. Limit pushdown: `head(n)` directly above an ungrouped scan whose predicates all translate to
# the `Scan` becomes the scan's per-partition limit; the `head` stays (ADR-0004 rule 3).

function _limit_rule(n, log::OptLog)
    (n isa StepNode && n.step isa HeadStep && n.step.n >= 0 && n.child isa ScanNode) || return n
    scan = n.child
    (isempty(scan.groups) && scan.limit === nothing) || return n
    if !isempty(scan.preds)
        _pushesfilters(scan.source) || return n
        sch = scan_schema(ScanNode(scan.source))
        sch === nothing && return n
        types = _typedict(sch)
        all(p -> to_scan(p, types) !== nothing, scan.preds) || return n
    end
    push!(log.fired, "limit pushdown: $(n.step) into the scan (per partition)")
    return StepNode(n.step, ScanNode(scan.source, scan.select, scan.preds, n.step.n, scan.groups, scan.drop))
end
