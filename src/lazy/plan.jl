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

Base.:(==)(a::ScanNode, b::ScanNode) = a.source === b.source && a.select == b.select &&
    a.preds == b.preds && a.limit == b.limit && a.groups == b.groups && a.drop == b.drop
Base.:(==)(a::StepNode, b::StepNode) = a.step === b.step && a.child == b.child

# Plan nodes are a Functor (their own base functor; ChuiCore R6 with the N5 typed style).
struct PlanTag end
UP.constructorclass(::Type{<:PlanNode}) = PlanTag()
UP.FunctorStyle(::PlanTag) = UP.IsFunctor()
UP.fmap(::UP.IsFunctor, f, n::StepNode) = StepNode(n.step, f(n.child))
UP.fmap(::UP.IsFunctor, f, n::ScanNode) = n

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

Base.show(io::IO, q::LazyFrame) = (print(io, "LazyFrame: "); _showplan(io, q.plan))
function Base.show(io::IO, ::MIME"text/plain", q::LazyFrame)
    println(io, "LazyFrame (collect(q) runs it; explain(q) shows the plans)")
    return _printplan(io, q.plan, "  ")
end

_showplan(io::IO, n::ScanNode) = print(io, "scan(", source_label(n.source), ")")
_showplan(io::IO, n::StepNode) = (_showplan(io, n.child); print(io, " ⨟ "); show(io, n.step))

function _printplan(io::IO, plan, indent::String)
    scan, steps = linearize(plan)
    for s in reverse(steps)
        println(io, indent, s)
    end
    return _printscan(io, scan, indent)
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

_typedict(sch) = Dict{Symbol, Type}(zip(sch[1], sch[2]))

# ---------------------------------------------------------------------------------------------
# The in-memory source behind `lazy(frame)`

"""
    FrameSource(frame)

A frame as a [`Source`](@ref): row-range partitions of `morsel` rows over the frame's own
columns, so every partition has the frame's exact column types. A grouped frame is one
partition, the whole frame, grouping kept. Thread-safe (reads are views of immutable columns),
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
function plan_partitions(s::FrameSource, scan::Tables.Scan; morsel::Int = DEFAULT_MORSEL)
    morsel >= 1 || throw(ArgumentError("morsel must be at least 1, got $morsel"))
    n = s.frame.nrow
    isgrouped(s.frame) && return (UnitRange{Int}[1:n], scan)
    return (UnitRange{Int}[i:min(i + morsel - 1, n) for i in 1:morsel:max(n, 1) if i <= n], scan)
end
read_partition(s::FrameSource, r::UnitRange{Int}) =
    (isgrouped(s.frame) || r == 1:s.frame.nrow) ? s.frame : take(s.frame, collect(r))
partition_row_count(::FrameSource, r::UnitRange{Int}) = (length(r), true)

function partition_stats(s::FrameSource, r::UnitRange{Int}, col::Symbol)
    hascolumn(s.frame, col) || return nothing
    c = getcol(s.frame, col)
    T = nonmissingtype(eltype(c))
    (T <: Union{Real, AbstractString, Dates.TimeType, ArrowTimestamp} && !(T <: Bool) && isconcretetype(T)) || return nothing
    lo = hi = nothing
    nnull = nnan = 0
    for i in r
        x = c[i]
        if ismissing(x)
            nnull += 1
        elseif x isa AbstractFloat && isnan(x)
            nnan += 1
        else
            lo = lo === nothing || isless(x, lo) ? x : lo
            hi = hi === nothing || isless(hi, x) ? x : hi
        end
    end
    return (; lo, hi, nnull, nnan, ndistinct = nothing)
end
