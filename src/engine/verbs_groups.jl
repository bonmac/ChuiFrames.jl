# Grouping and summary verbs: group_by, ungroup, summarise/summarize, reframe (ADR-0003 rules 3, 8).

# group_by / ungroup (ADR-0003 rules 3, 8)

struct GroupByStep <: Step
    keys::Vector{Any}
    computed::Vector{Pair{Symbol, Any}}
    add::Bool
    drop::Union{Nothing, Bool}   # nothing: inherit the input's flag
end
"""
    group_by(keys...; add = false, drop = nothing)

Group by columns (names, `c.x`, selectors) or computed keys (`:k => expr`, `k = expr`). The
frame carries a group index: groups in ascending key order, NaN/-NaN one group, ±0.0 one group
(shown as the first seen), `missing` its own group (ADR-0003 rule 8).

`drop = false` is dplyr's `.drop = FALSE`: for a dictionary-encoded key (a `DictColumn`, e.g. an
Arrow dictionary column), every dictionary entry is a level, and absent levels are kept as empty
groups, so `summarise(n = n_rows())` gives 0 for them (`sum` gives 0, `mean` NaN, and `maximum`
an `ArgumentError`, CC-007, where R warns and gives `-Inf`). For other keys it changes nothing,
as in dplyr for character and numeric keys.

The flag is stored on the frame (dplyr's `.drop` attribute) and survives the verbs that keep the
grouping: row verbs (`filter`, `filter_out`, `arrange`, the slices, `distinct`) keep
every existing group, even one they leave empty and whatever the key type (as dplyr does);
`head` and `pivot_longer(values_drop_na = true)` regroup (only empty dictionary levels stay, as
dplyr's `head` and tidyr do); and
`mutate`, `select`, `rename`, `relocate`, a partial `ungroup`, `count_by`/`tally`/`add_count`
and a `summarise` that keeps groups carry it on. `ungroup()` resets it. Differences from dplyr:
- groups stay in CF-008's ascending order of the key values, not in level order;
- `mutate`/`filter` do not evaluate empty groups (they have no rows), so a `maximum` there does
  not raise, where dplyr evaluates and warns;

The default `drop = nothing` inherits the input's flag, as dplyr's
`.drop = group_by_drop_default(.data)`: a `group_by` on a `drop = false` frame stays
`drop = false`, and on an ungrouped frame (always `drop = true`) it is `true`. An explicit
`drop = true` or `drop = false` wins.
"""
function group_by(keys...; add::Bool = false, drop::Union{Nothing, Bool} = nothing, kw...)
    ks = Any[]
    comp = Pair{Symbol, Any}[]
    for k in keys
        if k isa Pair
            push!(comp, Symbol(k.first) => node(k.second))
            push!(ks, Symbol(k.first))
        else
            push!(ks, k)
        end
    end
    for (k, v) in pairs(kw)
        push!(comp, k => node(v))
        push!(ks, k)
    end
    return GroupByStep(ks, comp, add, drop)
end
function Base.show(io::IO, s::GroupByStep)
    opts = String[]
    s.add && push!(opts, "add = true")
    s.drop === nothing || push!(opts, "drop = $(s.drop)")
    return print(io, "group_by(", join([_selrepr(k) for k in s.keys], ", "), isempty(opts) ? "" : "; " * join(opts, ", "), ")")
end
function apply(s::GroupByStep, f::Frame)
    isempty(s.computed) || (f = apply(MutateStep(_outs(s.computed), nothing, :all, nothing, nothing), f))
    keys = isempty(s.keys) ? Symbol[] : Symbol[f.names[i] for i in resolve(s.keys, f)]
    s.add && (keys = unique!([f.groups; keys]))
    return regroup(f, keys; drop = something(s.drop, f.drop))
end

struct UngroupStep <: Step
    sels::Vector{Any}
end
"`ungroup()` removes the grouping; `ungroup(sel...)` removes only those grouping columns."
ungroup(sels...) = UngroupStep(Any[sels...])
Base.show(io::IO, s::UngroupStep) = print(io, "ungroup(", join(_selrepr.(s.sels), ", "), ")")
function apply(s::UngroupStep, f::Frame)
    isempty(s.sels) && return Frame(copy(f.names), copy(f.columns), Symbol[], nothing, f.nrow)
    drop = Set(f.names[i] for i in resolve(s.sels, f))
    return regroup(f, Symbol[g for g in f.groups if !(g in drop)]; drop = f.drop)   # dplyr keeps .drop
end

# =============================================================================================
# summarise / reframe (CF-004, CF-006, CF-008; ADR-0002 rule 14; CF-017)

struct SummariseStep <: Step
    outs::Vector{Output}
    by::Any
    groups::Symbol
    reframe::Bool
end

const SUMMARISE_RESERVED = (:by, :groups)

"""
    summarise(name = reduction, ...; by, groups = :drop_last)
    summarise("name" => expr, across(...), ...)

One row per group (one row for an ungrouped frame), rows sorted ascending by the group keys
(CF-008). Outputs apply in order; later ones see earlier ones as values. Every reduction goes
through an aggregator, so `maximum` of an empty group is an `ArgumentError` (CC-007). `by` and
`groups` are reserved options (CF-017). `groups`: `:drop_last` (default), `:drop`, `:keep`.

**Difference from dplyr:** `summarise(…; by = :g)` also sorts its rows by the keys (CF-008),
whereas dplyr's `.by` keeps the order in which groups first appear. Add `arrange` after
`summarise` for another order. Group-key order (NaN before `missing`) is not `arrange` order
(NaN and `missing` tied), as in dplyr.
"""
function summarise(args...; kw...)
    outs, opts = _outputs(:summarise, args, kw, SUMMARISE_RESERVED)
    g = Symbol(get(opts, :groups, :drop_last))
    g in (:drop_last, :drop, :keep) || throw(ArgumentError("summarise: groups must be :drop_last, :drop or :keep, got $(repr(g))"))
    return SummariseStep(outs, get(opts, :by, nothing), g, false)
end
"`summarize`: the same verb as [`summarise`](@ref)."
const summarize = summarise

"""
    reframe(name = expr, ...; by)

Like `summarise`, but each output may have any number of rows per group (outputs of one group
must have equal lengths, or length 1, which is recycled). The result is ungrouped.
"""
function reframe(args...; kw...)
    outs, opts = _outputs(:reframe, args, kw, (:by,))
    return SummariseStep(outs, get(opts, :by, nothing), :drop, true)
end
Base.show(io::IO, s::SummariseStep) = print(
    io, s.reframe ? "reframe(" : "summarise(", _fmtoutputs(s.outs),
    s.by === nothing ? "" : "; by = $(repr(s.by))", s.groups === :drop_last || s.reframe ? "" : "; groups = $(repr(s.groups))", ")"
)

function apply(s::SummariseStep, f0::Frame)
    f, by = _withby(f0, s.by, s.reframe ? "reframe" : "summarise")
    gi = gindex(f)
    outs = _expand(s.outs, SelectCtx(f))
    for (nm, x) in outs
        nm in f.groups && throw(ArgumentError("summarise: the output $(repr(nm)) is a grouping column"))
        x === nothing && throw(ArgumentError("summarise: $(nm) = nothing is not an output"))
    end
    rowsets = gi === nothing ? [collect(1:f.nrow)] : [group_rows(gi, g) for g in 1:ngroups(gi)]
    names = unique!([o.first for o in outs])
    vals = Dict{Symbol, Vector{Any}}(nm => Any[] for nm in names)
    reps = Int[]   # reframe: rows per group
    for (g, rows) in enumerate(rowsets)
        env = Env(f, rows, length(rows), Dict{Symbol, Any}(), s.reframe ? :reframe : :summary)
        res = Dict{Symbol, Any}()
        for (nm, x) in outs
            r = ev(x, env)
            if !s.reframe
                if !(r isa Scalar)
                    length(r) == 1 || throw(ArgumentError("summarise: $(nm) gave $(length(r)) values for a group; summarise gives one value per group (use reframe for several rows)"))
                    r = Scalar(r[1])
                end
                env.overlay[nm] = r
            else
                r isa Scalar && r.x isa AbstractVector && (r = collect(r.x))   # quantile(c.x, [p...])
                env.overlay[nm] = r isa Scalar ? r : collect(r)
            end
            res[nm] = r
        end
        if s.reframe
            lens = [r isa Scalar ? 1 : length(r) for r in values(res) if !(r isa Scalar)]
            len = isempty(lens) ? 1 : lens[1]
            all(==(len), lens) || throw(DimensionMismatch("reframe: outputs of one group have different lengths $(lens)"))
            push!(reps, len)
            for nm in names
                r = res[nm]
                append!(vals[nm], r isa Scalar ? fill(r.x, len) : collect(r))
            end
        else
            for nm in names
                push!(vals[nm], res[nm].x)
            end
        end
    end
    keynames = gi === nothing ? Symbol[] : copy(f.groups)
    keyrows = s.reframe ? reduce(vcat, [fill(g, reps[g]) for g in eachindex(reps)]; init = Int[]) : collect(eachindex(rowsets))
    keycols = gi === nothing ? AbstractColumn[] : AbstractColumn[take(k, keyrows) for k in gi.keys]
    ctx = SelectCtx(f)
    outcols = AbstractColumn[]
    for nm in names
        v = vals[nm]
        x = last(outs[findlast(o -> o.first == nm, outs)])
        T = static_type(x, ctx)
        if isempty(v)
            push!(outcols, column(Vector{isconcretetype(nonmissingtype(T)) ? T : Any}()))
        else
            # Element type from the static type, not the data (ADR-0001 rule 1; review B1).
            push!(outcols, typed_column(v, T))
        end
    end
    allnames = [keynames; names]
    allcols = AbstractColumn[keycols; outcols]
    groups = if by !== nothing || s.reframe || s.groups === :drop
        Symbol[]
    elseif s.groups === :keep
        keynames
    else
        keynames[1:(end - 1)]
    end
    out = Frame(allnames, allcols, Symbol[], nothing, length(keyrows))
    return isempty(groups) ? out : regroup(out, groups; drop = f.drop)
end
