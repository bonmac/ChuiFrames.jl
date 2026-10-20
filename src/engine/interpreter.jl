# The single-threaded interpreter (ADR-0003 rules 1-3, 7): evaluates a node over the rows of a
# frame (or of one group, as views), one dynamic dispatch per node, with Base's broadcast loops
# inside. Grouped evaluation runs per group and scatters back in row order (the grouped-window
# operator).

"A one-value result (a reduction, a constant, `n_rows()`), as opposed to a column."
struct Scalar{T}
    x::T
end

"""
    Env

Evaluation context: the frame, the rows evaluated (`nothing` = all), their count, earlier
outputs of the same verb call (`overlay`), and the context kind (`:column` or `:summary`).
"""
struct Env
    frame::Frame
    rows::Union{Nothing, AbstractVector{Int}}
    n::Int
    overlay::Dict{Symbol, Any}
    ctx::Symbol
end
Env(f::Frame; ctx::Symbol = :column) = Env(f, nothing, f.nrow, Dict{Symbol, Any}(), ctx)
subenv(e::Env, rows) = Env(e.frame, rows, length(rows), e.overlay, e.ctx)

function _colvalue(e::Env, name::Symbol)
    if haskey(e.overlay, name)
        v = e.overlay[name]
        v isa Scalar && return v
        return e.rows === nothing ? v : view(v, e.rows)
    end
    col = getcol(e.frame, name)
    return e.rows === nothing ? col : view(col, e.rows)
end

_bcarg(x::Scalar) = Ref(x.x)
_bcarg(x) = x
_ascol(x::Scalar, n) = fill(x.x, n)
_ascol(x, n) = x
_unwrap(x::Scalar) = x.x
_unwrap(x) = x

ev(x::Col, e::Env) = _colvalue(e, x.name)
ev(x::Lit, e::Env) = x.scalar ? Scalar(x.value) : x.value
ev(::NRows, e::Env) = Scalar(e.n)
ev(::Desc, e::Env) = throw(ArgumentError("desc(...) is valid only where an ordering is consumed (arrange, ranking, slice_min/slice_max)"))
ev(::SkipMiss, e::Env) = throw(ArgumentError("skipmissing(c.x) is valid only as the argument of a reduction: sum(skipmissing(c.x))"))

function ev(x::Call, e::Env)
    args = Any[ev(a, e) for a in x.args]
    _lint_eval(x, args)
    all(a -> a isa Scalar, args) && return Scalar(x.f(map(_unwrap, args)...))
    return broadcast(x.f, map(_bcarg, args)...)
end

function ev(x::Reduce, e::Env)
    arg = x.arg isa SkipMiss ? x.arg.inner : x.arg
    v = ev(arg, e)
    v = v isa Scalar ? [v.x] : v
    return Scalar(UP.aggregate(_aggregator(x), UP.Map(identity), (v,)))
end

function ev(x::Pipe, e::Env)
    v = ev(x.arg, e)
    r = x.f(_ascol(v, e.n))
    e.ctx === :summary && return Scalar(r)
    e.ctx === :reframe && return r isa AbstractVector ? r : Scalar(r)
    if r isa AbstractVector
        length(r) == e.n ||
            throw(DimensionMismatch("c.x |> $(_fname(x.f)) returned $(length(r)) values for $(e.n) rows; a column result must have one value per row (CF-006)"))
        return r
    end
    return Scalar(r)
end

function ev(x::Window, e::Env)
    k = x.kind
    if k === :row_number && isempty(x.args)
        return collect(1:e.n)
    elseif k in (:row_number, :min_rank, :dense_rank)
        a = x.args[1]
        rev = a isa Desc
        v = _ascol(ev(rev ? a.inner : a, e), e.n)
        return _rank(k, v, rev)
    end
    cols = Any[_ascol(ev(a, e), e.n) for a in x.args]
    v = cols[1]
    r = if k === :cumsum
        cumsum(v)
    elseif k === :cumprod
        cumprod(v)
    elseif k === :accumulate
        haskey(x.kw, :init) ? accumulate(x.params[1], v; init = x.kw.init) : accumulate(x.params[1], v)
    elseif k === :cummean
        _cummean(v)
    elseif k === :lag
        _shift(v, x.params[1], get(x.kw, :default, missing))
    elseif k === :lead
        _shift(v, -x.params[1], get(x.kw, :default, missing))
    elseif k === :consecutive_id
        _consecutive(cols)
    else
        throw(ArgumentError("unknown window function $k"))
    end
    return r
end

function ev(x::CaseWhen, e::Env)
    conds = Any[ev(a, e) for a in x.conds]
    vals = Any[ev(a, e) for a in x.vals]
    d = ev(x.default, e)
    n = e.n
    out = Vector{Any}(undef, n)
    for i in 1:n
        chosen = false
        for (k, cnd) in enumerate(conds)
            b = cnd isa Scalar ? cnd.x : cnd[i]
            b isa Union{Bool, Missing} || throw(ArgumentError("case_when conditions must be Bool or missing, got $(typeof(b))"))
            if b === true
                v = vals[k]
                out[i] = v isa Scalar ? v.x : v[i]
                chosen = true
                break
            end
        end
        chosen || (out[i] = d isa Scalar ? d.x : d[i])
    end
    return _narrowvec(out)
end

function ev(x::IfAnyAll, e::Env)
    ctx = _envctx(e)
    names = ctx.names[resolve(x.sel, ctx)]
    isempty(names) && return Scalar(x.isall)
    acc = nothing
    for nm in names
        r = x.pred(Col(nm))
        r isa Node || throw(ArgumentError("$(x.isall ? "if_all" : "if_any"): the predicate returned a $(typeof(r)) for column $nm, not a column expression (write it dotted, e.g. v -> v .> 0)"))
        acc = acc === nothing ? r : (x.isall ? Call(&, Node[acc, r]) : Call(|, Node[acc, r]))
    end
    return ev(acc, e)
end

# Selection context of an environment: frame columns plus earlier outputs.
function _envctx(e::Env)
    f = e.frame
    names = copy(f.names)
    types = Type[eltype(col) for col in f.columns]
    for (k, v) in e.overlay
        k in names && continue
        push!(names, k)
        push!(types, v isa Scalar ? typeof(v.x) : eltype(v))
    end
    return SelectCtx(names, types, f.groups)
end

"""
Narrow a vector of values whose type is not known statically. A few distinct element types
become a small `Union` (so `column` can promote `Union{Int,Float64}` losslessly, ADR-0001
rule 12) instead of the `typejoin` (`Real`) a comprehension would give.
"""
function _narrowvec(v::AbstractVector)
    isempty(v) && return v
    isconcretetype(eltype(v)) && return v
    ts = Set{Any}()
    for x in v
        push!(ts, typeof(x))
        length(ts) > 4 && return [x for x in v]
    end
    return collect(Union{ts...}, v)
end

"""
    typed_column(v, T) -> AbstractColumn

The output column of an expression whose static type (from the declared schema, ADR-0002
rule 11) is `T`. When `nonmissingtype(T)` is concrete, the column has that value type
(nullable when `T` admits `missing` or a value is `missing`), whatever the values happen to be:
an all-`missing` group, or an empty group's neutral `0` in a `Float64` sum (ADR-0001 rule 1).
Values are converted only when nothing is lost (`isequal`); otherwise, and when `T` is not
known, the values are narrowed with [`_narrowvec`](@ref).
"""
function typed_column(v::AbstractVector, @nospecialize(T))
    S = nonmissingtype(T)
    if T !== Any && isconcretetype(S)
        E = (Missing <: T || any(ismissing, v)) ? Union{Missing, S} : S
        out = Vector{E}(undef, length(v))
        ok = true
        for (i, x) in enumerate(v)
            if ismissing(x) || x isa S
                out[i] = x
            else
                y = try
                    convert(S, x)
                catch
                    ok = false
                    break
                end
                isequal(y, x) || (ok = false; break)
                out[i] = y
            end
        end
        ok && return column(out)
    end
    return column(_narrowvec(v))
end

# ---------------------------------------------------------------------------------------------
# Row-wise detection: a node that needs no other rows can run ungrouped even on grouped frames.

isrowwise(::Union{Col, Lit}) = true
isrowwise(x::Call) = all(isrowwise, x.args)
isrowwise(x::CaseWhen) = all(isrowwise, x.conds) && all(isrowwise, x.vals) && isrowwise(x.default)
isrowwise(::Node) = false

# ---------------------------------------------------------------------------------------------
# Column evaluation: the full-length result of a node, per group when grouped.

"""
    eval_column(node, env, gi) -> AbstractVector

`node` evaluated to one value per row of `env`'s frame: ungrouped when `gi === nothing` or the
node is row-wise, else per group on views and scattered back in row order (ADR-0003 rule 3).
"""
function eval_column(x::Node, e::Env, gi::Union{Nothing, GroupIndex})
    n = e.frame.nrow
    if gi === nothing || isrowwise(x)
        return _fitcol(ev(x, e), n)
    end
    ng = ngroups(gi)
    ng == 0 && return Vector{_emptytype(x, e)}()
    parts = Vector{Any}(undef, ng)
    T = Union{}
    for g in 1:ng
        rows = group_rows(gi, g)
        p = _fitcol(ev(x, subenv(e, rows)), length(rows))
        parts[g] = p
        T = promote_type(T, eltype(p))
    end
    out = Vector{T}(undef, n)
    for g in 1:ng
        rows = group_rows(gi, g)
        p = parts[g]
        for (k, r) in enumerate(rows)
            out[r] = p[k]
        end
    end
    return out
end

function _fitcol(v, n::Int)
    v isa Scalar && return fill(v.x, n)
    v isa AbstractVector || return fill(v, n)
    length(v) == n || throw(DimensionMismatch("expression gave $(length(v)) values for $n rows"))
    return v
end

# Element type of an expression over zero groups: the static type when it is concrete, else Any.
function _emptytype(x::Node, e::Env)
    T = static_type(x, _envctx(e))
    return isconcretetype(nonmissingtype(T)) ? T : Any
end

# ---------------------------------------------------------------------------------------------
# Static element types from the declared schema (ADR-0002 rule 11), never from the data and
# never from `Base.promote_op`. `Any` means "not known": a filter then checks row by row.

const _BOOLFUNS = Set{Any}(
    [
        ==, !=, <, <=, >, >=, isless, isequal, in, ∉, occursin, startswith, endswith, contains,
        isnan, isinf, isfinite, iszero, isone, iseven, isodd, ismissing, isnothing, !, between, xor, ⊻,
        isempty, isdigit, isletter, isspace, isuppercase, islowercase, signbit,
    ]
)
const _ARITH = Set{Any}([+, -, *, /, ^, abs, abs2, sqrt, exp, log, log2, log10, div, rem, mod, fld, cld, round, floor, ceil, trunc, min, max, sign, float, inv])

_cty(ctx::SelectCtx, s::Symbol) = (i = findfirst(==(s), ctx.names); i === nothing ? Any : ctx.types[i])
_isboolish(T) = T !== Union{} && (T <: Union{Bool, Missing})
_nullable(T) = Missing <: T && T !== Any

static_type(x::Col, ctx::SelectCtx) = _cty(ctx, x.name)
static_type(x::Lit, ::SelectCtx) = x.scalar ? typeof(x.value) : (x.value isa AbstractArray ? eltype(x.value) : Any)
static_type(::NRows, ::SelectCtx) = Int
static_type(::Node, ::SelectCtx) = Any
static_type(x::Desc, ctx::SelectCtx) = static_type(x.inner, ctx)
function static_type(x::Call, ctx::SelectCtx)
    ts = Any[static_type(a, ctx) for a in x.args]
    anynull = any(_nullable, ts)
    wrap(T) = anynull ? Union{Missing, T} : T
    if x.f in _BOOLFUNS
        return x.f in (isequal, ismissing, isnothing) ? Bool : wrap(Bool)
    elseif x.f === (&) || x.f === (|)
        all(_isboolish, ts) && return wrap(Bool)
        nm = map(nonmissingtype, ts)
        all(T -> isconcretetype(T) && T <: Integer, nm) && return wrap(promote_type(nm...))
        return Any
    elseif x.f === ifelse && length(ts) == 3
        a, b = ts[2], ts[3]
        _isboolish(a) && _isboolish(b) && return Union{a, b}
        return Union{a, b}
    elseif x.f in _ARITH
        nm = map(nonmissingtype, ts)
        all(T -> isconcretetype(T) && T <: Number && T !== Bool, nm) && return wrap(promote_type(nm...))
        return Any
    end
    return Any
end
function static_type(x::Reduce, ctx::SelectCtx)
    f = x.fname
    f in (:length, :n_distinct) && return Int
    T = static_type(x.arg isa SkipMiss ? x.arg.inner : x.arg, ctx)
    x.arg isa SkipMiss && (T = nonmissingtype(T))
    if f in (:any, :all)
        return isempty(x.pre) && _isboolish(T) ? T : Any
    elseif f === :count
        return _nullable(T) ? Any : Int
    elseif f in (:maximum, :minimum, :first, :last)
        return isempty(x.pre) ? T : Any
    elseif f in (:sum, :prod, :mean, :var, :std)
        S = nonmissingtype(T)
        isempty(x.pre) && isconcretetype(S) && S <: Number && S !== Bool || return Any
        R = f === :sum || f === :prod ? promote_type(S, Int) : Float64
        return _nullable(T) ? Union{Missing, R} : R
    end
    return Any
end
function static_type(x::Window, ctx::SelectCtx)
    if x.kind in (:row_number, :min_rank, :dense_rank)
        # a rank is `missing` only where its argument is, so it is nullable only when the
        # argument's declared type is (review B1)
        isempty(x.args) && return Int
        return any(a -> _nullable(static_type(a, ctx)) || static_type(a, ctx) === Any, x.args) ? Union{Missing, Int} : Int
    end
    x.kind === :consecutive_id && return Int
    return Any
end
function static_type(x::CaseWhen, ctx::SelectCtx)
    ts = Any[static_type(v, ctx) for v in x.vals]
    push!(ts, static_type(x.default, ctx))
    all(_isboolish, ts) && return Union{Missing, Bool}
    return Any
end
static_type(x::IfAnyAll, ::SelectCtx) = Union{Missing, Bool}

# ---------------------------------------------------------------------------------------------
# Lints (ADR-0002 rule 17): warnings, at most a few per kind per session; silenced by
# `ChuiFrames.lints(false)` or the usual logging filters.

const _LINTS_ON = Ref(true)
const _LINT_COUNT = Dict{Symbol, Int}()
const _LINT_MAX = 3

"`ChuiFrames.lints(on::Bool)`: switch the grammar lints (ADR-0002 rule 17) on or off."
lints(on::Bool) = (_LINTS_ON[] = on; nothing)
_reset_lints!() = (empty!(_LINT_COUNT); nothing)
function _lint(id::Symbol, msg::String)
    _LINTS_ON[] || return nothing
    k = get(_LINT_COUNT, id, 0)
    k >= _LINT_MAX && return nothing
    _LINT_COUNT[id] = k + 1
    @warn msg _id = id
    return nothing
end

const _CMPS = Set{Any}([<, <=, >, >=, ==, !=])
function _lint_build(n::Call)
    # GR-03: `a .> 1 .& b .< 2` lowers to `&(>(a, X), <(X, 2))` with X = `&.(1, b)`.
    if (n.f === (&) || n.f === (|)) && length(n.args) == 2
        a, b = n.args
        if a isa Call && b isa Call && a.f in _CMPS && b.f in _CMPS && length(a.args) == 2 &&
                length(b.args) == 2 && a.args[2] == b.args[1] && a.args[2] isa Call &&
                (a.args[2].f === (&) || a.args[2].f === (|))
            _lint(:chained_comparison, "this looks like `a .> 1 .& b .< 2`, which Julia parses as a chained comparison: parenthesise each comparison, `(a .> 1) .& (b .< 2)`")
        end
    end
    if (n.f === (==) || n.f === (!=)) && any(a -> a isa Lit && ismissing(a.value), n.args)
        _lint(:eq_missing, "`.== missing` / `.!= missing` is always missing; use ismissing.(c.x) or .!ismissing.(c.x)")
    end
    return nothing
end
function _lint_eval(n::Call, args)
    if n.f === cumsum || n.f === cumprod || n.f === accumulate
        for a in args
            if a isa AbstractVector && !(nonmissingtype(eltype(a)) <: AbstractVector)
                _lint(:dotted_scan, "$(nameof(n.f)).(c.x) is elementwise and gives one-element results; for a running total write $(nameof(n.f))(c.x)")
                break
            end
        end
    end
    return nothing
end
