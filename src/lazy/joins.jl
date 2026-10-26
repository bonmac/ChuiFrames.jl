# Join nodes in lazy plans (phase-4 spec docs/superpowers/specs/2026-10-26-phase4-joins-groupby-codegen-design.md
# §1.2-§1.4): lowering to the three physical shapes at `collect`, streamability and totality of
# the join steps, the cost stage's estimates, and the helpers of filter and projection pushdown.
# Join lane. No change to execute.jl: the methods below put the breakers in `rest`.

isstreamable(::ProbeStep) = true
isstreamable(::JoinTailStep) = false
isstreamable(::PartitionedJoinStep) = false

"""
A join is total for pushdown and early stops (spec §1.3) when it cannot raise: `unmatched =
:drop` and `multiple != :error` (semi/anti/cross joins always; nest joins when `unmatched =
:drop`).
"""
_jointotal(s::JoinStep) = s.unmatched === :drop && s.multiple !== :error

# A limit may stop the scan early past a probe only in shape (a) with no tail, for a total join.
_steptotal(p::ProbeStep, below) = p.side === :y && !p.tail && _jointotal(p.spec)

# ---------------------------------------------------------------------------------------------
# Estimates for the cost stage

# Steps that keep the row count (an exact source count stays exact through them).
_rowpreserving(s::Step) = s isa Union{RenameStep, RenameWithStep, RelocateStep, SelectStep, MutateStep, ArrangeStep, GroupByStep, UngroupStep}

"""
    _plan_estimate(plan) -> SideEstimate

The rows (from the source's `row_count`; exact only through row-preserving steps, with no
pushed predicate or limit) and the column types (from `node_schema`, when static) of a side.
"""
function _plan_estimate(plan)
    sch = node_schema(plan)
    types = sch === nothing ? nothing : sch[2]
    steps, bottom = _chain(plan)
    bottom isa ScanNode || return SideEstimate(nothing, false, types)
    rc = row_count(bottom.source)
    rc === nothing && return SideEstimate(nothing, false, types)
    rows, exact = rc
    exact = exact && isempty(bottom.preds) && bottom.limit === nothing && all(_rowpreserving, steps)
    return SideEstimate(Int(rows), exact, types)
end

# ---------------------------------------------------------------------------------------------
# Lowering for execution (spec §1.4)

"""
    _run_subplan(plan; morsel, threads) -> Frame

Run an inner subplan, `execute(physical(_lower_joins(plan)))`, without the CF-008 replay
guard: only the top-level `collect` guards, so a failure anywhere replays the whole plan once
(critic pass 3 m6).
"""
_run_subplan(plan; morsel::Int = DEFAULT_MORSEL, threads::Bool = true) =
    execute(physical(_lower_joins(plan; morsel, threads)); morsel, threads)

"""
    _lower_joins(plan; morsel, threads) -> linear plan

Lower every `JoinNode` (innermost first) to one of the three physical shapes (spec §1.2,
§1.4), so `physical` sees a linear plan:

1. sides whose names are not resolved, or whose key types are not static, are collected first
   and replaced by `lazy(collected)` (exact rows and types; it can still stream); the compare
   types and the key checks run on their column types;
2. `join_decision` picks the build side from estimates; the build side is collected, and the
   strategy confirmed on its collected size (unless `_FORCE_JOIN` forces it);
3. (a) broadcast, build y: `ProbeStep(:y)` over x's plan, with a `JoinTailStep` when needed;
   (b) broadcast, build x: `JoinTailStep(:x)` over `ProbeStep(:x)` over y's plan;
   (c) partitioned: `PartitionedJoinStep` over x's plan (y passed collected, or as its plan);
   a cross join: `ProbeStep(:y)` over x's plan with the collected y (no table, no tail).

Subplans run through [`_run_subplan`](@ref) (unguarded). The join property tests call this
function, never a copy of it.
"""
_lower_joins(n::ScanNode; kw...) = n
function _lower_joins(n::StepNode; kw...)
    c = _lower_joins(n.child; kw...)
    return c === n.child ? n : StepNode(n.step, c)
end
function _lower_joins(n::JoinNode; morsel::Int = DEFAULT_MORSEL, threads::Bool = true)
    s = n.spec
    left, right = n.left, n.right
    names = n.names
    xf = nothing
    yf = nothing
    run(p) = _run_subplan(p; morsel, threads)
    if names === nothing
        xn = _plan_names(left)
        xn === nothing && (xf = run(left); xn = xf.names)
        yn = _plan_names(right)
        yn === nothing && (yf = _ungrouped(run(right)); yn = yf.names)
        names = _resolve_names(s, xn, yn; log = true)
    end
    lowered(p) = _lower_joins(p; morsel, threads)
    if s.kind === :cross
        yf === nothing && (yf = _ungrouped(run(right)))
        return StepNode(ProbeStep(:y, yf, s, names, false), xf === nothing ? lowered(left) : lazy(xf).plan)
    end
    T = names.compare
    if T === nothing
        xs = xf === nothing ? node_schema(left) : nothing
        ys = yf === nothing ? node_schema(right) : nothing
        (xf === nothing && xs === nothing) && (xf = run(left))
        (yf === nothing && ys === nothing) && (yf = _ungrouped(run(right)))
        xt = xf === nothing ? _keytypes(xs, _xkeys(names)) : _keytypes(xf, _xkeys(names))
        yt = yf === nothing ? _keytypes(ys, _ykeys(names)) : _keytypes(yf, _ykeys(names))
        T = _join_compare_types(names, xt, yt)
        names = _withcompare(names, T)
    end
    xf === nothing || (left = lazy(xf).plan)
    yf === nothing || (right = lazy(yf).plan)
    strategy, build, p, _ = join_decision(s, _plan_estimate(left), _plan_estimate(right))
    forced = _FORCE_JOIN[] !== :auto
    never = s.na_matches === :never
    if build === :y
        yf === nothing && (yf = _ungrouped(run(right)))
        forced || (strategy = _broadcast_ok(yf.nrow, _estimated_bytes(_frame_estimate(yf))) ? :broadcast : :partitioned)
        if strategy === :broadcast
            b = JoinBuild(yf, _ykeys(names), T, never)
            tail = _needs_ytail(s)
            node = StepNode(ProbeStep(:y, b, s, names, tail), lowered(left))
            return tail ? StepNode(JoinTailStep(:y, b, s, names), node) : node
        end
        return StepNode(PartitionedJoinStep(yf, s, names, :y, p, T, morsel, threads), lowered(left))
    end
    xf === nothing && (xf = run(left))
    forced || (strategy = _broadcast_ok(xf.nrow, _estimated_bytes(_frame_estimate(xf))) ? :broadcast : :partitioned)
    if strategy === :broadcast
        b = JoinBuild(xf, _xkeys(names), T, never)
        return StepNode(JoinTailStep(:x, b, s, names), StepNode(ProbeStep(:x, b, s, names, true), lowered(right)))
    end
    return StepNode(PartitionedJoinStep(yf === nothing ? right : yf, s, names, :x, p, T, morsel, threads), lazy(xf).plan)
end

# ---------------------------------------------------------------------------------------------
# Filter pushdown through a join (spec §1.3; critic B1, N2, pass 3 m1/m3/MAJOR-1)

"Can a predicate on the output key of pair `src` move to x (N2: inner/left/nest, static, no conversion)?"
function _keypush_ok(j::JoinNode, src::Symbol)
    s = j.spec
    (s.kind === :inner || s.kind === :left || s.kind === :nest) || return false
    names = j.names::JoinNames
    T = names.compare
    T === nothing && return false
    xs = node_schema(j.left)
    xs === nothing && return false
    p = findfirst(q -> q.first === src, names.pairs)::Int
    Tx = _typedict(xs)[src]
    return T[p] === nonmissingtype(Tx)
end

"""
A total filter directly above a total join, reading columns of one side only, moves to that
side (spec §1.3): inner x or y (y only under `multiple = :all`), semi/anti x, left x, right y
(`multiple = :all`), full never, nest x (never the nested column), cross either. A key
predicate (keep = false) moves to x only under the N2 condition. Names map back through the
join's construction-time names.
"""
function _push_into_join(n::StepNode, f::FilterStep, j::JoinNode, log::OptLog)
    s = j.spec
    names = j.names
    names === nothing && return n
    _jointotal(s) || return n
    cols = Set{Symbol}()
    for p in f.preds
        union!(cols, _reads(p))
    end
    isempty(cols) && return n
    sides = Set{Symbol}()
    back = Dict{Symbol, Symbol}()
    for c in cols
        k = findfirst(==(c), names.outnames)
        k === nothing && return n
        side, src = names.outside[k], names.outsrc[k]
        side === :nest && return n
        if side === :key
            _keypush_ok(j, src) || return n
            side = :x
        end
        push!(sides, side)
        back[c] = src
    end
    length(sides) == 1 || return n
    side = only(sides)
    kind = s.kind
    ok = if side === :x
        kind in (:inner, :semi, :anti, :left, :nest, :cross)
    else
        kind === :cross || ((kind === :inner || kind === :right) && s.multiple === :all)
    end
    ok || return n
    g = FilterStep(Node[_rename(p, back) for p in f.preds], false)
    push!(log.fired, "predicate pushdown: $(f) below $(_joinlabel(j)) into $(side)")
    return side === :x ? JoinNode(StepNode(g, j.left), j.right, s, names) : JoinNode(j.left, StepNode(g, j.right), s, names)
end

# ---------------------------------------------------------------------------------------------
# Projection pushdown per side (spec §1.4)

"""
The columns each side must supply given the columns `need` above the join (`nothing`: all):
its keys, the columns read above (mapped through the names), and every clashing column on both
sides, so a suffix never disappears. A needed nested column needs all of y.
"""
function _join_need(j::JoinNode, need)
    names = j.names
    (names === nothing || need === nothing) && return (nothing, nothing)
    s = j.spec
    nx = Set{Symbol}(_xkeys(names))
    union!(nx, names.xclash)
    ny = Set{Symbol}(_ykeys(names))
    union!(ny, names.yclash)
    ally = false
    for c in need
        k = findfirst(==(c), names.outnames)
        k === nothing && continue
        side, src = names.outside[k], names.outsrc[k]
        if side === :x || side === :key
            push!(nx, src)
        elseif side === :y
            push!(ny, src)
        else
            ally = true
        end
    end
    return (nx, ally ? nothing : ny)
end
