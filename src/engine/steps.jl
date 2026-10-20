# Verbs are values (CF-007; ADR-0003 rule 1): each verb call without a table returns a `Step`.
# Applying a step to ANY Tables.jl source converts it with `Frame(t)` and runs the physical
# operators now, on the calling task, with the optimizer off. `step(t)` ≡ `t |> step`.

"""
    Step

Supertype of verb values. `s(t)` (or `t |> s`) applies the verb to any Tables.jl table `t`.
"""
abstract type Step end

"`Pipeline(steps)`: steps applied left to right; built by `⨟` (CF-007)."
struct Pipeline <: Step
    steps::Vector{Step}
end

steps(p::Pipeline) = p.steps
steps(s::Step) = Step[s]
UP.:⨟(a::Step, b::Step) = Pipeline(Step[steps(a); steps(b)])

(s::Step)(t) = apply(s, _asframe(t))
_asframe(f::Frame) = f
_asframe(t) = Frame(t)

function apply(p::Pipeline, f)
    for s in p.steps
        f = s(f)
    end
    return f
end

Base.show(io::IO, p::Pipeline) = join(io, p.steps, " ⨟ ")
Base.show(io::IO, ::MIME"text/plain", s::Step) = show(io, s)

# ---------------------------------------------------------------------------------------------
# Output arguments of mutate/summarise/reframe (ADR-0002 rule 14; CF-017).

"An output of a verb: a name and a node (`nothing` removes the column in `mutate`)."
const Output = Union{Pair{Symbol, Any}, Across}

_out(p::Pair) = Pair{Symbol, Any}(Symbol(p.first), p.second)
_outs(ps) = Output[_out(p) for p in ps]

_outnode(v::Node) = v
_outnode(::Nothing) = nothing
_outnode(v::AbstractVector) = Lit(v, false)
_outnode(v) = Lit(v, true)

_bool_lint(v) = v isa Bool &&
    _lint(:bare_bool, "a bare Bool was passed as a column value (did you mean a dotted comparison such as c.x .== 1?); write lit($v) to silence this")

"""
    _outputs(verb, args, kw, reserved) -> (outputs, options)

Split a verb call into its outputs (in order) and its reserved option keywords.
"""
function _outputs(verb::Symbol, args::Tuple, kw, reserved::Tuple)
    opts = Dict{Symbol, Any}()
    outs = Output[]
    kwouts = Pair{Symbol, Any}[]
    for (k, v) in pairs(kw)
        if k in reserved
            v isa Union{Node, Across} &&
                throw(ArgumentError("`$k` is a reserved option of $verb; to create a column named $k use the Pair form: $verb(\"$k\" => $(v))"))
            opts[k] = v
        else
            _bool_lint(v)
            push!(kwouts, k => _outnode(v))
        end
    end
    if !isempty(args) && !isempty(kwouts)
        ex = verb === :mutate ? "mutate(across(…), :y => c.x .+ 1)" : "$verb(across(…), :n => n_rows())"
        throw(ArgumentError("$verb: positional outputs (across(…), \"name\" => expr) cannot be mixed with keyword outputs, because Julia loses their relative order; write every output positionally, e.g. $ex"))
    end
    for a in args
        if a isa Across
            push!(outs, a)
        elseif a isa Pair && a.first isa Union{Symbol, AbstractString}
            _bool_lint(a.second)
            push!(outs, _out(a.first => _outnode(a.second)))
        else
            throw(ArgumentError("$verb: a positional argument must be across(…) or a \"name\" => expr Pair, got $(repr(a))"))
        end
    end
    append!(outs, kwouts)
    return outs, opts
end

_fmtoutputs(outs) = join([o isa Across ? repr(o) : (Base.isidentifier(o.first) ? "$(o.first) = $(o.second)" : "$(repr(string(o.first))) => $(o.second)") for o in outs], ", ")

"Expand `across` against the selection context (grouping columns are never selected)."
function _expand(outs::Vector{Output}, ctx::SelectCtx)
    res = Pair{Symbol, Any}[]
    for o in outs
        if o isa Across
            append!(res, _expand_across(o, ctx))
        else
            push!(res, o)
        end
    end
    return res
end
function _expand_across(a::Across, ctx::SelectCtx)
    cols = [ctx.names[i] for i in resolve(a.sel, ctx) if !(ctx.names[i] in ctx.groups)]
    tmpl = a.names === nothing ? (length(a.fns) == 1 ? "{col}" : "{col}_{fn}") : a.names
    res = Pair{Symbol, Any}[]
    for col in cols, (fname, f) in a.fns
        r = f(Col(col))
        r isa Node || throw(ArgumentError("across: $(fname) returned a $(typeof(r)) for column $col, not a column expression; write the function over columns (v -> round.(v)) or use each(f)"))
        nm = replace(replace(tmpl, "{col}" => string(col)), "{fn}" => fname)
        push!(res, Symbol(nm) => r)
    end
    return res
end

# Columns an expression reads (for mutate's keep = :used/:unused).
_usedcols!(s::Set{Symbol}, x::Col) = push!(s, x.name)
_usedcols!(s::Set{Symbol}, x::Union{Call, Window}) = (foreach(a -> _usedcols!(s, a), x.args); s)
_usedcols!(s::Set{Symbol}, x::Union{Reduce, Pipe}) = _usedcols!(s, x.arg)
_usedcols!(s::Set{Symbol}, x::Union{Desc, SkipMiss}) = _usedcols!(s, x.inner)
_usedcols!(s::Set{Symbol}, x::CaseWhen) = (foreach(a -> _usedcols!(s, a), [x.conds; x.vals; x.default]); s)
_usedcols!(s::Set{Symbol}, ::Any) = s

_names(x::Union{Symbol, AbstractString}) = [Symbol(x)]
_names(x::Col) = [x.name]
_names(x::AbstractVector) = Symbol[n for v in x for n in _names(v)]
_names(x) = throw(ArgumentError("expected column names, got $(repr(x))"))
