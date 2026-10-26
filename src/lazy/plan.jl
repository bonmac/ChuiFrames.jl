# The plan IR and the lazy entry point (spec §2-3; ADR-0003 rules 1, 4; CF-007, CF-008).
#
# A plan is a tree of `PlanNode`s: a `ScanNode` leaf (a `Source` plus what the optimizer pushed
# into it) and `StepNode`s, each one verb (`Step`) over one child. The child field is `Any`
# (ChuiCore R6: a parametric child recompiles per tree shape). Plan nodes are their own base
# functor: `Upstream.fmap` maps over the child, so the optimizer's passes are written with the
# adapter's `cata`/`para` (ADR-0003 rule 4, ADR-0014).

"Supertype of the lazy plan's nodes."
abstract type PlanNode end

"""
    ScanNode(source; groups, drop)

The plan's leaf: a [`Source`](@ref) and what the optimizer pushed into it: the projection
`select` (`nothing`: every column), the filter conjuncts `preds` (total predicates, spec §4: the
source receives those that translate to `Tables.Scan`, the engine re-applies all of them, and
all of them drive partition pruning), and a per-partition `limit`. `groups`/`drop` are the
grouping of a grouped input frame; a grouped scan is never pushed into.
"""
struct ScanNode <: PlanNode
    source::Any
    select::Union{Nothing, Vector{Symbol}}
    preds::Vector{Node}
    limit::Union{Nothing, Int}
    groups::Vector{Symbol}
    drop::Bool
end
ScanNode(source; groups::Vector{Symbol} = Symbol[], drop::Bool = true) =
    ScanNode(source, nothing, Node[], nothing, groups, drop)

"`StepNode(step, child)`: the verb `step` applied to the result of `child`."
struct StepNode <: PlanNode
    step::Step
    child::Any
end

"""
    JoinNode(left, right, spec, names)

A join of two subplans (phase-4 spec §1.4): `left` is x's plan, `right` y's, `spec` the
`JoinStep`. `names` (a `JoinNames`) is resolved once, when the node is built, from both sides'
unprojected schemas, so later projection never changes the output names; it is `nothing` when
a side's schema cannot be computed without running it (then the names are resolved at
`collect`). The children are `Any`-typed (ChuiCore R6).
"""
struct JoinNode <: PlanNode
    left::Any
    right::Any
    spec::JoinStep
    names::Union{Nothing, JoinNames}
end

Base.:(==)(a::ScanNode, b::ScanNode) = a.source === b.source && a.select == b.select &&
    a.preds == b.preds && a.limit == b.limit && a.groups == b.groups && a.drop == b.drop
Base.:(==)(a::StepNode, b::StepNode) = a.step === b.step && a.child == b.child
Base.:(==)(a::JoinNode, b::JoinNode) = a.spec === b.spec && a.left == b.left && a.right == b.right

# Plan nodes are a Functor (their own base functor; ChuiCore R6 with the N5 typed style).
struct PlanTag end
UP.constructorclass(::Type{<:PlanNode}) = PlanTag()
UP.FunctorStyle(::PlanTag) = UP.IsFunctor()
UP.fmap(::UP.IsFunctor, f, n::StepNode) = StepNode(n.step, f(n.child))
UP.fmap(::UP.IsFunctor, f, n::ScanNode) = n
UP.fmap(::UP.IsFunctor, f, n::JoinNode) = JoinNode(f(n.left), f(n.right), n.spec, n.names)

"The steps above the bottom node (scan first) and the bottom node (a `ScanNode` or a `JoinNode`)."
function _chain(plan)
    steps = Step[]
    n = plan
    while n isa StepNode
        push!(steps, n.step)
        n = n.child
    end
    return reverse!(steps), n
end

"Does the plan hold a join?"
_hasjoin(n::ScanNode) = false
_hasjoin(n::StepNode) = _hasjoin(n.child)
_hasjoin(::JoinNode) = true

"The steps from the scan up, and the scan."
function linearize(plan)
    steps = Step[]
    n = plan
    while n isa StepNode
        push!(steps, n.step)
        n = n.child
    end
    return n::ScanNode, reverse!(steps)
end

"Rebuild a plan from a scan and steps (scan first)."
build(scan::ScanNode, steps) = foldl((n, s) -> StepNode(s, n), steps; init = scan)

# ---------------------------------------------------------------------------------------------
# The lazy query

"""
    LazyFrame

A lazy query: a plan that nothing has run yet (CF-008). Build one with [`lazy`](@ref), or by
applying a verb to a [`ChuiFrames.Source`](@ref) such as `scan_file(path)`; apply verbs to it
(each returns a new `LazyFrame`, CF-007); run it with
`collect(q)`; inspect it with [`explain`](@ref) and `code_lowered(q)`.
"""
struct LazyFrame
    plan::Any
end

"""
    lazy(t) -> LazyFrame

The lazy view of `t`: a `Frame`, any Tables.jl table (converted once with `Frame(t)`), or a
[`ChuiFrames.Source`](@ref). Verbs applied to it record themselves in the plan; `collect`
runs the optimized plan. For every deterministic, pure pipeline `p`,
`collect(p(lazy(t)))` agrees with `p(t)` (CF-008).
"""
lazy(q::LazyFrame) = q
lazy(s::Source) = LazyFrame(ScanNode(s))
function lazy(t)
    f = _asframe(t)
    return LazyFrame(ScanNode(FrameSource(f); groups = copy(f.groups), drop = f.drop))
end

# Applying a step to a query appends it (CF-007); a pipeline appends each of its steps. A step
# applied to a Source (`scan_file(path) |> filter(…)`) starts a lazy query over it.
(s::Step)(q::LazyFrame) = _append(s, q)
(s::Step)(src::Source) = _append(s, lazy(src))
_append(s::Step, q::LazyFrame) = LazyFrame(StepNode(s, q.plan))
_append(p::Pipeline, q::LazyFrame) = foldl((acc, s) -> _append(s, acc), p.steps; init = q)
# A join applied to a query builds a JoinNode, resolving its names now (spec §1.4).
_append(s::JoinStep, q::LazyFrame) = LazyFrame(_joinnode(s, q.plan))

Base.show(io::IO, q::LazyFrame) = (print(io, "LazyFrame: "); _showplan(io, q.plan))
function Base.show(io::IO, ::MIME"text/plain", q::LazyFrame)
    println(io, "LazyFrame (collect(q) runs it; explain(q) shows the plans)")
    return _printplan(io, q.plan, "  ")
end

_showplan(io::IO, n::ScanNode) = print(io, "scan(", source_label(n.source), ")")
_showplan(io::IO, n::StepNode) = (_showplan(io, n.child); print(io, " ⨟ "); show(io, n.step))
function _showplan(io::IO, n::JoinNode)
    print(io, _joinlabel(n), "(x: ")
    _showplan(io, n.left)
    print(io, "; y: ")
    _showplan(io, n.right)
    return print(io, ")")
end

# The plan, last step first; a join prints as a tree with its `x:` and `y:` subplans (linear
# plans print as in phase 3).
function _printplan(io::IO, plan, indent::String)
    steps, bottom = _chain(plan)
    for s in reverse(steps)
        println(io, indent, s)
    end
    bottom isa ScanNode && return _printscan(io, bottom, indent)
    j = bottom::JoinNode
    println(io, indent, _joinlabel(j))
    println(io, indent, "├─ x:")
    _printplan(io, j.left, indent * "│    ")
    println(io, indent, "└─ y:")
    return _printplan(io, j.right, indent * "     ")
end

"`join(inner; by = [:a => :b], …)`: a join node's label (resolved keys when known)."
function _joinlabel(j::JoinNode)
    s = j.spec
    opts = String[]
    if s.kind !== :cross
        if j.names !== nothing
            push!(opts, "by = " * _bystr(j.names))
        elseif s.by !== nothing
            push!(opts, "by = " * _bystr(s.by))
        else
            push!(opts, "by = nothing (resolved at collect)")
        end
    end
    s.suffix == ("_x", "_y") || s.kind in (:semi, :anti, :nest) || push!(opts, "suffix = $(repr(s.suffix))")
    s.na_matches === :na || push!(opts, "na_matches = :never")
    s.keep && push!(opts, "keep = true")
    s.multiple === :all || push!(opts, "multiple = $(repr(s.multiple))")
    s.unmatched === :drop || push!(opts, "unmatched = :error")
    s.kind === :nest && push!(opts, "name = $(repr(s.name))")
    return "join(" * string(s.kind) * (isempty(opts) ? "" : "; " * join(opts, ", ")) * ")"
end
function _printscan(io::IO, n::ScanNode, indent::String)
    print(io, indent, "scan ", source_label(n.source))
    isempty(n.groups) || print(io, " grouped by ", join(n.groups, ", "), n.drop ? "" : " (drop = false)")
    n.select === nothing || print(io, "\n", indent, "  select: ", join(n.select, ", "))
    isempty(n.preds) || print(io, "\n", indent, "  filter: ", join(string.(n.preds), ", "))
    n.limit === nothing || print(io, "\n", indent, "  limit: ", n.limit, " per partition")
    return println(io)
end

# ---------------------------------------------------------------------------------------------
# Static schemas: exact column names and element types at a plan node, through the steps that
# never compute values (spec §5): scan, filters, arrange, head, and name-only select, rename,
# rename_with, relocate. `nothing` anywhere else (a mutate, a grouping, any other verb).

"An empty frame with exactly these names and element types (selector resolution only)."
_probe(names::Vector{Symbol}, types::Vector{Type}) =
    Frame(copy(names), AbstractColumn[column(Vector{T}()) for T in types])

"`(names, types)` of the scan's output, or `nothing` for a grouped scan."
function scan_schema(n::ScanNode)
    isempty(n.groups) || return nothing
    sch = source_schema(n.source)
    sch.types === nothing && return nothing        # no declared types: nothing is total
    names = collect(Symbol, sch.names)
    types = schema_types(sch)
    n.select === nothing && return (names, types)
    idx = [findfirst(==(c), names) for c in n.select]
    any(isnothing, idx) && return nothing
    return (names[idx], types[idx])
end

"""
    name_map(step, names, types) -> Union{Nothing, Vector{Pair{Symbol,Symbol}}}

For a step that only selects, reorders or renames columns (no computed values): the output
columns as `out => in` pairs, found by applying the step to an empty probe frame and matching
the column objects. `nothing` for any other step, or when the step throws on the probe.
"""
function name_map(s::Step, names::Vector{Symbol}, types::Vector{Type})
    _isnameonly(s) || return nothing
    p = _probe(names, types)
    out = try
        apply(s, p)
    catch
        return nothing
    end
    pairs = Pair{Symbol, Symbol}[]
    for (j, col) in enumerate(out.columns)
        i = findfirst(c -> c === col, p.columns)
        i === nothing && return nothing
        push!(pairs, out.names[j] => p.names[i])
    end
    return pairs
end
_isnameonly(::Step) = false
_isnameonly(::Union{RenameStep, RenameWithStep, RelocateStep}) = true
_isnameonly(s::SelectStep) = all(it -> !(it isa Pair) || it.second isa Col, s.items)

"`(names, types)` at `plan`'s output, or `nothing` (spec §5)."
function node_schema(n::ScanNode)
    return scan_schema(n)
end
function node_schema(n::StepNode)
    sch = node_schema(n.child)
    sch === nothing && return nothing
    s = n.step
    s isa Union{FilterStep, ArrangeStep, HeadStep} && return sch
    m = name_map(s, sch...)
    m === nothing && return nothing
    names, types = sch
    return (Symbol[p.first for p in m], Type[types[findfirst(==(p.second), names)] for p in m])
end

"""
`(names, types)` at a join's output (phase-4 spec §1.4): only when both sides' `node_schema`
give their types (proven static, critic pass 3 MAJOR-1) and the names are resolved; the types
follow §1.1's static rules by kind, so a join of static joins stays static.
"""
function node_schema(n::JoinNode)
    n.names === nothing && return nothing
    xs = node_schema(n.left)
    xs === nothing && return nothing
    ys = node_schema(n.right)
    ys === nothing && return nothing
    (n.spec.kind === :cross || n.names.compare !== nothing) || return nothing
    return _join_schema(n.spec, n.names, xs, ys)
end

function _join_schema(s::JoinStep, names::JoinNames, xs, ys)
    xt, yt = _typedict(xs), _typedict(ys)
    xnull = s.kind === :right || s.kind === :full
    ynull = s.kind === :left || s.kind === :full
    outn = Symbol[]
    types = Type[]
    for (j, nm) in enumerate(names.outnames)
        side, src = names.outside[j], names.outsrc[j]
        T = if side === :x
            haskey(xt, src) || continue
            xnull ? Union{Missing, xt[src]} : xt[src]
        elseif side === :y
            haskey(yt, src) || continue
            ynull ? Union{Missing, yt[src]} : yt[src]
        elseif side === :nest
            Frame
        else
            p = findfirst(q -> q.first === src, names.pairs)::Int
            Tx, Ty = xt[src], yt[names.pairs[p].second]
            C = (names.compare::Vector{Type})[p]
            base = _needsconv(Tx, C) ? C : nonmissingtype(Tx)
            (Missing <: Tx || Missing <: Ty) ? Union{Missing, base} : base
        end
        push!(outn, nm)
        push!(types, T)
    end
    return (outn, types)
end

_typedict(sch) = Dict{Symbol, Type}(zip(sch[1], sch[2]))

# ---------------------------------------------------------------------------------------------
# Building join nodes (spec §1.4)

"y's plan: a `LazyFrame`'s plan, a `Source`'s scan, or an ungrouped frame's scan."
_rightplan(y::LazyFrame) = y.plan
_rightplan(y::Source) = ScanNode(y)
_rightplan(y::Frame) = ScanNode(FrameSource(_ungrouped(y)))

"""
The empty output of a plan: each side's subplan applied to the empty frame of its source
schema (the probe technique of `render_kernel`). Trusted for names only, never for types.
"""
function _empty_output(n::ScanNode)
    src = n.source
    f = src isa FrameSource ? take(src.frame, Int[]) : empty_frame(source_schema(src))
    n.select === nothing || (f = apply_scan(f, Tables.Scan(; select = n.select)))
    isempty(n.groups) || (f = regroup(f, n.groups; drop = n.drop))
    return f
end
_empty_output(n::StepNode) = apply(n.step, _empty_output(n.child))
function _empty_output(n::JoinNode)
    names = n.names
    names === nothing && throw(ArgumentError("the join's names are resolved at collect"))
    return _join_frames(n.spec, names, _empty_output(n.left), _empty_output(n.right))
end

"The column names at a plan's output from the empty-frame probe, or `nothing` when it throws."
function _plan_names(plan)
    return try
        _empty_output(plan).names
    catch
        nothing
    end
end

"The element types of `keys` in a static schema."
_keytypes(sch, keys::Vector{Symbol}) = (d = _typedict(sch); Type[d[k] for k in keys])
_keytypes(f::Frame, keys::Vector{Symbol}) = Type[eltype(getcol(f, k)) for k in keys]

"""
    _joinnode(s::JoinStep, left) -> JoinNode

The join of the plan `left` (x) with `s.y` (spec §1.4). The names are resolved now, from both
sides' unprojected schemas (the natural-join `@info` and the nest_join `@warn` are logged here),
unless a side's probe throws. The compare types, and the key-pair and abstract-type checks,
run now only when both sides' key types are static (`node_schema`); otherwise at `collect`.
"""
function _joinnode(s::JoinStep, left)
    right = _rightplan(s.y)
    xn = _plan_names(left)
    yn = _plan_names(right)
    (xn === nothing || yn === nothing) && return JoinNode(left, right, s, nothing)
    names = _resolve_names(s, xn, yn; log = true)
    if s.kind !== :cross
        xs, ys = node_schema(left), node_schema(right)
        if xs !== nothing && ys !== nothing
            names = _withcompare(names, _join_compare_types(names, _keytypes(xs, _xkeys(names)), _keytypes(ys, _ykeys(names))))
        end
    end
    return JoinNode(left, right, s, names)
end

# ---------------------------------------------------------------------------------------------
# The in-memory source behind `lazy(frame)`

"""
    FrameSource(frame)

A frame as a [`Source`](@ref): row-range partitions of `morsel` rows over the frame's own
columns, so every partition has the frame's exact column types. A grouped frame is one
partition, the whole frame, grouping kept. Thread-safe (reads copy rows out of the frame and
never write to it),
with exact row counts and exact per-partition statistics of plain numeric, string and
timestamp columns.
"""
struct FrameSource <: Source
    frame::Frame
end
source_schema(s::FrameSource) = Tables.schema(s.frame)
source_label(s::FrameSource) = "Frame $(s.frame.nrow)×$(length(s.frame.names))"
isthreadsafe(::FrameSource) = true
row_count(s::FrameSource) = (s.frame.nrow, true)
# Handles are `(rows, cols)`: a row range and the pushed projection (`nothing`: every column,
# `pushed_columns`), so a morsel copies only the columns the query reads. The residual is the
# whole request, valid over that subset.
function plan_partitions(s::FrameSource, scan::Tables.Scan; morsel::Int = DEFAULT_MORSEL)
    morsel >= 1 || throw(ArgumentError("morsel must be at least 1, got $morsel"))
    n = s.frame.nrow
    isgrouped(s.frame) && return ([(1:n, nothing)], scan)
    cols = pushed_columns(scan, s.frame.names)
    return ([(i:min(i + morsel - 1, n), cols) for i in 1:morsel:max(n, 1) if i <= n], scan)
end
function read_partition(s::FrameSource, (r, cols)::Tuple{UnitRange{Int}, Any})
    f = s.frame
    (isgrouped(f) || (cols === nothing && r == 1:f.nrow)) && return f
    cs = cols === nothing ? f.columns : AbstractColumn[getcol(f, c) for c in cols]
    names = cols === nothing ? copy(f.names) : copy(cols)
    idx = collect(r)
    return Frame(names, AbstractColumn[r == 1:f.nrow ? c : take(c, idx) for c in cs], Symbol[], nothing, length(r))
end
partition_row_count(::FrameSource, (r, _)::Tuple{UnitRange{Int}, Any}) = (length(r), true)

function partition_stats(s::FrameSource, (r, _)::Tuple{UnitRange{Int}, Any}, col::Symbol)
    hascolumn(s.frame, col) || return nothing
    c = getcol(s.frame, col)
    T = nonmissingtype(eltype(c))
    (T <: Union{Real, AbstractString, Dates.TimeType, ArrowTimestamp} && !(T <: Bool) && isconcretetype(T)) || return nothing
    return _colstats(c, r, T)
end
# A function barrier: the column's concrete type and `T` are known here.
function _colstats(c, r::UnitRange{Int}, ::Type{T}) where {T}
    lo, hi = Ref{T}(), Ref{T}()
    seen = false
    nnull = nnan = 0
    for i in r
        x = c[i]
        if ismissing(x)
            nnull += 1
        elseif x isa AbstractFloat && isnan(x)
            nnan += 1
        elseif !seen
            lo[] = hi[] = x
            seen = true
        else
            isless(x, lo[]) && (lo[] = x)
            isless(hi[], x) && (hi[] = x)
        end
    end
    return (; lo = seen ? lo[] : nothing, hi = seen ? hi[] : nothing, nnull, nnan, ndistinct = nothing)
end
