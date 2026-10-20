# The macro-free expression grammar (ADR-0002; CF-002 to CF-006): `c.x` builds a `Col` node,
# dotted calls build elementwise `Call` nodes through a custom BroadcastStyle, plain calls of the
# supported reductions build whole-column `Reduce` nodes, and `c.x |> f` builds a `Pipe`.

"""
    Node

Supertype of ChuiFrames' column expressions. Nodes are immutable values: `==`, `isequal` and
`hash` are structural (CF-005), so they work as `Dict` keys.
"""
abstract type Node end

"`Col(name)`: a deferred reference to column `name` (CF-002)."
struct Col <: Node
    name::Symbol
end

"`Lit(value, scalar)`: a constant; `scalar` constants are broadcast as one value."
struct Lit{T} <: Node
    value::T
    scalar::Bool
end
Lit(x) = Lit(x, !(x isa Union{AbstractArray, Tuple}))

"`Call(f, args)`: `f` applied elementwise (broadcast) over its arguments (CF-003)."
struct Call{F} <: Node
    f::F
    args::Vector{Node}
end

"""
`Reduce(fname, arg, pre, post, kw)`: a whole-column reduction (CF-004), evaluated through an
aggregator (ADR-0003 rule 7). Printed as `fname(pre..., arg, post...; kw...)`.
"""
struct Reduce <: Node
    fname::Symbol
    arg::Node
    pre::Tuple
    post::Tuple
    kw::NamedTuple
end

"`Pipe(arg, f)`: `c.x |> f`, `f` applied once to the whole column or group (CF-006)."
struct Pipe{F} <: Node
    arg::Node
    f::F
end

"""
`Window(kind, args, params, kw)`: a whole-column call returning one value per row, evaluated per
group (`cumsum`, `lag`, `row_number`, ...; ADR-0002 rule 9).
"""
struct Window <: Node
    kind::Symbol
    args::Vector{Node}
    params::Tuple
    kw::NamedTuple
end

"`n_rows()`: the number of rows of the table or group (dplyr's `n()`)."
struct NRows <: Node end

"`desc(x)`: descending order, valid where an ordering is consumed (ADR-0002 rule 9)."
struct Desc <: Node
    inner::Node
end

"""
`skipmissing(c.x)`: valid only as the argument of a reduction (ADR-0002 rule 10). It skips
`missing` only, as Base does; NaN stays, so `sum(skipmissing(c.x))` is NaN when a value is
NaN. R's `na.rm = TRUE` drops NaN as well: a documented divergence, in the family of ADR-0002
rule 12 (see `filter`).
"""
struct SkipMiss <: Node
    inner::Node
end

"`case_when(cond => value, ...; default)` (ADR-0002 rule 10)."
struct CaseWhen <: Node
    conds::Vector{Node}
    vals::Vector{Node}
    default::Node
end

"`if_any(sel, pred)` / `if_all(sel, pred)` (ADR-0002 rule 8), resolved against the table."
struct IfAnyAll{S, P} <: Node
    sel::S
    pred::P
    isall::Bool
end

node(x::Node) = x
node(x::Ref) = Lit(x[], true)
node(x::Broadcast.Broadcasted) = Lit(copy(x))
node(x) = Lit(x)

# ---------------------------------------------------------------------------------------------
# `c`: the singleton of deferred column references (CF-002, CF-010).

"""
    c

The deferred column reference: `c.x`, `c[:x]`, `c["my col"]` build column nodes; `c[sel]` with a
selector (`[:a, :b]`, `r"^x"`, `where(Number)`, `Not(:a)`, ...) builds a selector (ADR-0002
rule 7).
"""
struct ColumnRefs end
const c = ColumnRefs()
Base.getproperty(::ColumnRefs, s::Symbol) = Col(s)
Base.getindex(::ColumnRefs, s::Symbol) = Col(s)
Base.getindex(::ColumnRefs, s::AbstractString) = Col(Symbol(s))
Base.propertynames(::ColumnRefs, private::Bool = false) = ()
Base.show(io::IO, ::ColumnRefs) = print(io, "c")

# ---------------------------------------------------------------------------------------------
# Structural equality and hashing (CF-005; ADR-0002 rule 2: exactly three `==` methods).

_feq(a, b) = isequal(a, b)
_feq(a::Function, b) = a === b
_feq(a, b::Function) = a === b
_feq(a::Function, b::Function) = a === b
function _seq(a::Node, b::Node)
    typeof(a) === typeof(b) || return false
    for i in 1:fieldcount(typeof(a))
        _feq(getfield(a, i), getfield(b, i)) || return false
    end
    return true
end
Base.isequal(a::Node, b::Node) = _seq(a, b)
Base.:(==)(a::Node, b::Node) = _seq(a, b)
Base.:(==)(::Node, ::Missing) = false
Base.:(==)(::Missing, ::Node) = false
function Base.hash(a::Node, h::UInt)
    h = hash(nameof(typeof(a)), h)
    for i in 1:fieldcount(typeof(a))
        h = hash(getfield(a, i), h)
    end
    return h
end

# ---------------------------------------------------------------------------------------------
# Elementwise: Julia's own broadcasting builds `Call` nodes (CF-003).

"Broadcast style of column expressions: every broadcast touching a node builds a node."
struct NodeStyle <: Broadcast.BroadcastStyle end
Base.broadcastable(x::Node) = x
Broadcast.BroadcastStyle(::Type{<:Node}) = NodeStyle()
Broadcast.BroadcastStyle(s::NodeStyle, ::Broadcast.BroadcastStyle) = s
Broadcast.BroadcastStyle(s::NodeStyle, ::NodeStyle) = s
Broadcast.BroadcastStyle(s::NodeStyle, ::Broadcast.Unknown) = s
function Broadcast.broadcasted(::NodeStyle, f, args...)
    n = Call(f, Node[node(a) for a in args])
    _lint_build(n)
    return n
end
# `x .^ 3` lowers to `literal_pow`; keep it a plain `^` node (ADR-0002 rule 1, GR-02).
Broadcast.broadcasted(s::NodeStyle, ::typeof(Base.literal_pow), ::Ref{typeof(^)}, x, ::Ref{Val{p}}) where {p} =
    Broadcast.broadcasted(s, ^, x, p)

Base.map(f, a::Node, rest::Node...) = Call(f, Node[a, rest...])

# ---------------------------------------------------------------------------------------------
# Whole-column reductions (CF-004): methods of the Base/Statistics functions on nodes.

const _NOKW = NamedTuple()

function _reduce(fname::Symbol, a, pre::Tuple = (), post::Tuple = (), kw::NamedTuple = _NOKW)
    a = node(a)
    a isa Desc && throw(ArgumentError("desc(...) is valid only where an ordering is consumed (arrange, ranking, slice_min/slice_max)"))
    return Reduce(fname, a, pre, post, kw)
end
_nokw(fname, kw) = isempty(kw) ||
    throw(ArgumentError("$fname(c.x; ...) keywords are not supported; write c.x |> v -> $fname(v; ...)"))

for f in (:sum, :prod, :maximum, :minimum, :extrema, :any, :all, :count)
    @eval Base.$f(a::Node; kw...) = (_nokw($(QuoteNode(f)), kw); _reduce($(QuoteNode(f)), a))
    @eval Base.$f(g, a::Node; kw...) = (_nokw($(QuoteNode(f)), kw); _reduce($(QuoteNode(f)), a, (g,)))
end
Base.length(a::Node) = _reduce(:length, a)
Base.first(a::Node) = _reduce(:first, a)
Base.last(a::Node) = _reduce(:last, a)
Base.reduce(op, a::Node; kw...) = (_nokw(:reduce, kw); _reduce(:reduce, a, (op,)))
Base.mapreduce(f, op, a::Node; kw...) = (_nokw(:mapreduce, kw); _reduce(:mapreduce, a, (f, op)))
Statistics.mean(a::Node) = _reduce(:mean, a)
Statistics.mean(f, a::Node) = _reduce(:mean, a, (f,))
Statistics.median(a::Node) = _reduce(:median, a)
Statistics.var(a::Node; corrected::Bool = true) = _reduce(:var, a, (), (), corrected ? _NOKW : (corrected = false,))
Statistics.std(a::Node; corrected::Bool = true) = _reduce(:std, a, (), (), corrected ? _NOKW : (corrected = false,))
Statistics.quantile(a::Node, p; kw...) = _reduce(:quantile, a, (), (p,), NamedTuple(kw))

"""
    n_distinct(x)

The number of distinct values of a column (or group), with `missing` counted as a value and
NaN/-NaN and ±0.0 each one value (ADR-0003 rule 8). On a vector, the same count directly.
"""
n_distinct(a::Node) = _reduce(:n_distinct, a)
n_distinct(v::AbstractVector) = UP.aggregate(NDistinct(), UP.Map(identity), (v,))

"""
    nth(x, k; default = missing)

The `k`-th value of a column (or group); negative `k` counts from the end; out of range gives
`default` (dplyr's `nth`).
"""
nth(a::Node, k::Integer; default = missing) = _reduce(:nth, a, (), (Int(k),), ismissing(default) ? _NOKW : (default = default,))
function nth(v::AbstractVector, k::Integer; default = missing)
    n = length(v)
    i = k > 0 ? k : n + k + 1
    return (k != 0 && 1 <= i <= n) ? v[i] : default
end

Base.skipmissing(a::Node) = SkipMiss(a)

# The aggregator behind each reduction (ADR-0003 rule 7).
function _aggregator(r::Reduce)
    f = r.fname
    agg = if f === :sum
        isempty(r.pre) ? UP.Sum() : UP.MapM(r.pre[1], UP.Sum())
    elseif f === :prod
        isempty(r.pre) ? UP.Prod() : UP.MapM(r.pre[1], UP.Prod())
    elseif f === :maximum
        isempty(r.pre) ? UP.Max() : UP.MapM(r.pre[1], UP.Max())
    elseif f === :minimum
        isempty(r.pre) ? UP.Min() : UP.MapM(r.pre[1], UP.Min())
    elseif f === :extrema
        isempty(r.pre) ? UP.Extrema() : UP.MapM(r.pre[1], UP.Extrema())
    elseif f === :any
        isempty(r.pre) ? UP.AnyM() : UP.MapM(r.pre[1], UP.AnyM())
    elseif f === :all
        isempty(r.pre) ? UP.AllM() : UP.MapM(r.pre[1], UP.AllM())
    elseif f === :count
        isempty(r.pre) ? UP.CountTrue() : UP.MapM(r.pre[1], UP.CountTrue())
    elseif f === :length
        UP.Count()
    elseif f === :first
        UP.First()
    elseif f === :last
        UP.Last()
    elseif f === :reduce
        UP.ReduceM(r.pre[1])
    elseif f === :mapreduce
        UP.MapM(r.pre[1], UP.ReduceM(r.pre[2]))
    elseif f === :mean
        isempty(r.pre) ? UP.Mean() : UP.MapM(r.pre[1], UP.Mean())
    elseif f === :var || f === :std
        Spread(UP.Moments(f === :std, get(r.kw, :corrected, true)))
    elseif f === :median
        Holistic(Statistics.median, "median")
    elseif f === :quantile
        p, kw = r.post[1], r.kw
        Holistic(v -> Statistics.quantile(v, p; kw...), "quantile")
    elseif f === :n_distinct
        NDistinct()
    elseif f === :nth
        k, d = r.post[1], get(r.kw, :default, missing)
        Holistic(v -> nth(v, k; default = d), "nth")
    else
        throw(ArgumentError("unknown reduction $f"))
    end
    return r.arg isa SkipMiss ? SkipMissingAgg(agg) : agg
end

# ---------------------------------------------------------------------------------------------
# Whole-column escape hatch, windows and guards.

Base.:|>(a::Node, f) = Pipe(a, f)

"""
    Typed{T}

The callable built by [`typed(T, f)`](@ref): `f` with a declared result type `T`. Printed as
`typed(T, f)`; equal when `T` and `f` are (CF-005).
"""
struct Typed{T, F}
    f::F
end

"""
    typed(T, f)

Declare the result type of a whole-column function: `c.x |> typed(T, f)` is `c.x |> f` whose
static type is `T` (ADR-0002 rule 11), instead of unknown (`Any`). `T` is the **element** type
when `f` returns a vector in a column context (`mutate`, `filter`, `reframe`), and the type of
the value when `f` returns one value (always in `summarise`). So
`filter(c.s |> typed(Bool, v -> occursin.("a", v)))` is planned as a `Bool` predicate (no
row-by-row check), and `filter(c.x |> typed(Int, identity))` is an `ArgumentError` at plan time.

The result is checked when evaluated: a value that is not `isa T` is an `ArgumentError` naming
the expression, `T` and the value's type. Nothing is converted. Called directly,
`typed(T, f)(v)` applies `f` and checks the same way.
"""
typed(::Type{T}, f) where {T} = Typed{T, typeof(f)}(f)
typed(T, f) = throw(ArgumentError("typed(T, f): T must be a type, got $(repr(T))"))
(t::Typed{T})(v) where {T} = (r = t.f(v); _checktyped(r, T, true, t); r)
Base.show(io::IO, t::Typed{T}) where {T} = print(io, "typed(", T, ", ", _fname(t.f), ")")
Base.:|>(a::Node, t::Typed) = Pipe(a, t)

# `r` checked against the declared type `T`: elementwise for a vector when `elementwise`.
function _checktyped(r, ::Type{T}, elementwise::Bool, what) where {T}
    if elementwise && r isa AbstractVector
        eltype(r) <: T && return nothing
        for y in r
            y isa T || _typederror(what, T, typeof(y), "an element")
        end
    else
        r isa T || _typederror(what, T, typeof(r), "a value")
    end
    return nothing
end
_typederror(what, T, S, kind) = throw(ArgumentError("$(what) declares result type $T but gave $kind of type $S; typed(T, f) checks and never converts (convert inside f)"))

Base.cumsum(a::Node) = Window(:cumsum, Node[a], (), _NOKW)
Base.cumprod(a::Node) = Window(:cumprod, Node[a], (), _NOKW)
Base.accumulate(op, a::Node; init = nothing) =
    Window(:accumulate, Node[a], (op,), init === nothing ? _NOKW : (init = init,))

# ADR-0002 rule 3: these would silently return a constant; point to the dotted form.
Base.coalesce(::Node, ::Any, ::Any...) =
    throw(ArgumentError("coalesce on a column expression is elementwise: write coalesce.(c.x, 0)"))
Base.something(::Node, ::Any, ::Any...) =
    throw(ArgumentError("something on a column expression is elementwise: write something.(c.x, 0)"))

# ---------------------------------------------------------------------------------------------
# Printing round-trips (ADR-0002 rule 18): a non-identifier column prints as `c.var"my col"`.

function _showname(io::IO, s::Symbol)
    str = string(s)
    return if Base.isidentifier(s) && !(str in ("true", "false"))
        print(io, "c.", str)
    else
        print(io, "c.var", repr(str))
    end
end
Base.show(io::IO, x::Col) = _showname(io, x.name)
function Base.show(io::IO, x::Lit)
    return if x.scalar && x.value isa Union{AbstractArray, Tuple}
        print(io, "Ref(")
        show(io, x.value)
        print(io, ")")
    else
        show(io, x.value)
    end
end
_fname(f) = (s = string(f isa Function ? nameof(f) : f); startswith(s, "#") ? "(" * repr(f) * ")" : s)
_isop(s) = Base.isoperator(Symbol(s)) && !all(isletter, s)
function Base.show(io::IO, x::Call)
    name = _fname(x.f)
    return if length(x.args) == 2 && _isop(name)
        print(io, "(", x.args[1], " .", name, " ", x.args[2], ")")
    elseif length(x.args) == 1 && _isop(name)
        print(io, "(.", name, x.args[1], ")")
    else
        print(io, name, ".(")
        join(io, x.args, ", ")
        print(io, ")")
    end
end
function _showcall(io::IO, name, args, kw::NamedTuple)
    print(io, name, "(")
    join(io, [x isa Node ? sprint(show, x) : (x isa Function ? _fname(x) : repr(x)) for x in args], ", ")
    if !isempty(kw)
        print(io, "; ")
        join(io, ["$k = $(repr(v))" for (k, v) in pairs(kw)], ", ")
    end
    return print(io, ")")
end
Base.show(io::IO, x::Reduce) = _showcall(io, x.fname, (x.pre..., x.arg, x.post...), x.kw)
Base.show(io::IO, x::Pipe) = print(io, "(", x.arg, " |> ", _fname(x.f), ")")
Base.show(io::IO, x::Window) = x.kind === :row_number && isempty(x.args) ? print(io, "row_number()") :
    x.kind === :ntile && isempty(x.args) ? print(io, "ntile(n = ", x.params[1], ")") :
    _showcall(io, x.kind, x.kind === :accumulate ? (x.params..., x.args...) : (x.args..., x.params...), x.kw)
Base.show(io::IO, ::NRows) = print(io, "n_rows()")
Base.show(io::IO, x::Desc) = print(io, "desc(", x.inner, ")")
Base.show(io::IO, x::SkipMiss) = print(io, "skipmissing(", x.inner, ")")
function Base.show(io::IO, x::CaseWhen)
    print(io, "case_when(")
    join(io, ["$(a) => $(b)" for (a, b) in zip(x.conds, x.vals)], ", ")
    isequal(x.default, Lit(missing)) || print(io, "; default = ", x.default)
    return print(io, ")")
end
Base.show(io::IO, x::IfAnyAll) = print(io, x.isall ? "if_all(" : "if_any(", _selrepr(x.sel), ", ", _fname(x.pred), ")")
