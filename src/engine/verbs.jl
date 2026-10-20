# The core eager verbs (dplyr parity rows of phase 2). Each is a Step struct with an `apply`
# method over a `Frame`; verbs sharing a Base name are methods of the Base function on a
# ChuiFrames-owned argument (ADR-0002 rule 4).

_newframe(f::Frame, names, cols; groups = f.groups) =
    Frame(Vector{Symbol}(names), Vector{AbstractColumn}(cols), Symbol[g for g in groups if g in names], nothing, f.nrow)

_rowsets(f::Frame) = (gi = gindex(f); gi === nothing ? [collect(1:f.nrow)] : [collect(group_rows(gi, g)) for g in 1:ngroups(gi)])

# =============================================================================================
# filter / filter_out (ADR-0002 rules 11-12)

struct FilterStep <: Step
    preds::Vector{Node}
    out::Bool   # filter_out: drop rows where the conditions are true
end

"""
    filter(cond::Node, conds::Node...)

Keep the rows where every condition is `true`; `false` and `missing` drop the row (ADR-0002
rule 11). Conditions are evaluated per group on grouped frames. A condition whose declared
element type is concrete and not `Bool` is an `ArgumentError` at plan time. NaN follows IEEE:
`NaN .> 1` is `false`, `.!(NaN .> 1)` is `true` (rule 12, a documented divergence from dplyr).
"""
Base.filter(p::Node, ps::Node...) = FilterStep(Node[p, ps...], false)

"`filter_out(cond...)`: drop the rows where the conditions are all `true`; keep `false` and `missing` rows (dplyr 1.2.0)."
filter_out(p::Node, ps::Node...) = FilterStep(Node[p, ps...], true)

Base.show(io::IO, s::FilterStep) = (print(io, s.out ? "filter_out(" : "filter("); join(io, s.preds, ", "); print(io, ")"))

# Plan-time check of a predicate's declared type: :bool, or :check (row by row).
function _predclass(p::Node, ctx::SelectCtx, verb)
    T = static_type(p, ctx)
    _isboolish(T) && return :bool
    S = nonmissingtype(T)
    if T !== Any && isconcretetype(S)
        throw(ArgumentError("$verb: the condition $(p) has element type $T, not Bool; write a comparison such as $(p) .> 0 (dplyr also rejects non-logical conditions)"))
    end
    return :check
end

function apply(s::FilterStep, f::Frame)
    ctx = SelectCtx(f)
    verb = s.out ? "filter_out" : "filter"
    for p in s.preds
        _predclass(p, ctx, verb)
    end
    gi = gindex(f)
    env = Env(f)
    n = f.nrow
    # three-valued AND over the conditions: 1 true, 0 false, -1 missing
    state = fill(Int8(1), n)
    for p in s.preds
        v = eval_column(p, env, gi)
        for i in 1:n
            b = v[i]
            if b === false
                state[i] = 0
            elseif ismissing(b)
                state[i] == 1 && (state[i] = -1)
            elseif b !== true
                throw(ArgumentError("$verb: the condition $(p) gave a $(typeof(b)) value at row $i; conditions must be Bool or missing"))
            end
        end
    end
    keep = s.out ? findall(x -> x != 1, state) : findall(==(1), state)
    return take(f, keep)
end

# =============================================================================================
# select / rename / rename_with / relocate (ADR-0002 rules 7, 15)

struct SelectStep <: Step
    items::Vector{Any}
end

"""
    select(sel...; new = expr...)

Keep (and order) columns: Symbols, strings, `c.x`, selectors (ADR-0002 rule 7), and
`:new => expr` / `new = expr` to rename or compute. `select(:a => :b)` is an `ArgumentError`:
write `select(:new => c.old)` or `rename`. Grouping columns are always kept (added first).
"""
function select(args...; kw...)
    items = Any[]
    for a in args
        if a isa Pair
            a.second isa Union{Symbol, AbstractString} &&
                throw(ArgumentError("select($(repr(a))): a Symbol => Symbol pair is ambiguous (DataFrames reads it old => new); write select(:new => c.old) to rename while selecting, or rename(new = :old)"))
            a.first isa Union{Symbol, AbstractString} || throw(ArgumentError("select: a Pair needs a column name first, got $(repr(a))"))
            push!(items, Symbol(a.first) => node(a.second))
        else
            push!(items, a)
        end
    end
    for (k, v) in pairs(kw)
        v isa Union{Symbol, AbstractString} &&
            throw(ArgumentError("select($k = $(repr(v))): write select($k = c.$v) to rename while selecting"))
        push!(items, k => node(v))
    end
    return SelectStep(items)
end
Base.show(io::IO, s::SelectStep) = print(io, "select(", join([x isa Pair ? "$(repr(x.first)) => $(x.second)" : _selrepr(x) for x in s.items], ", "), ")")

function apply(s::SelectStep, f::Frame)
    ctx = SelectCtx(f)
    outnames = Symbol[]
    outcols = AbstractColumn[]
    renamed = Dict{Symbol, Symbol}()
    gi = nothing
    function add!(nm, col)
        i = findfirst(==(nm), outnames)
        return if i === nothing
            push!(outnames, nm)
            push!(outcols, col)
        else
            outcols[i] = col
        end
    end
    for it in s.items
        if it isa Pair
            nm, x = it.first, it.second
            if x isa Col
                add!(nm, getcol(f, x.name))
                x.name in f.groups && (renamed[x.name] = nm)
            else
                gi === nothing && (gi = gindex(f))
                add!(nm, column(eval_column(x, Env(f), gi)))
            end
        else
            for i in resolve(it, ctx)
                f.names[i] in outnames || add!(f.names[i], f.columns[i])
            end
        end
    end
    groups = Symbol[get(renamed, g, g) for g in f.groups]
    missingg = [g for g in f.groups if !haskey(renamed, g) && !(g in outnames)]
    if !isempty(missingg)
        outnames = [missingg; outnames]
        outcols = AbstractColumn[[getcol(f, g) for g in missingg]; outcols]
    end
    return Frame(outnames, outcols, groups, isempty(renamed) && groups == f.groups ? f.gindex : nothing, f.nrow)
end

struct RenameStep <: Step
    pairs::Vector{Pair{Symbol, Symbol}}   # new => old
end

"""
    rename(new = :old, ...)
    rename(:new => :old, "new name" => :old, ...)

Rename columns, output name first, as in dplyr (ADR-0002 rule 15). The opposite of
DataFrames' `rename(df, :old => :new)`.
"""
function rename(args::Pair...; kw...)
    ps = Pair{Symbol, Symbol}[]
    for a in args
        push!(ps, Symbol(a.first) => _oldname(a.second))
    end
    for (k, v) in pairs(kw)
        push!(ps, k => _oldname(v))
    end
    return RenameStep(ps)
end
_oldname(x::Union{Symbol, AbstractString}) = Symbol(x)
_oldname(x::Col) = x.name
_oldname(x) = throw(ArgumentError("rename: the old name must be a Symbol, string or c.x, got $(repr(x))"))
Base.show(io::IO, s::RenameStep) = print(io, "rename(", join(["$(repr(p.first)) => $(repr(p.second))" for p in s.pairs], ", "), ")")

function _renamed(f::Frame, map::Dict{Symbol, Symbol})
    names = Symbol[get(map, n, n) for n in f.names]
    allunique(names) || throw(ArgumentError("renaming would give duplicate column names: $(names)"))
    groups = Symbol[get(map, g, g) for g in f.groups]
    return Frame(names, copy(f.columns), groups, f.gindex, f.nrow)
end
function apply(s::RenameStep, f::Frame)
    m = Dict{Symbol, Symbol}()
    for (new, old) in s.pairs
        hascolumn(f, old) || throw(ArgumentError("rename: no column $(repr(old)); columns are $(join(repr.(f.names), ", "))"))
        m[old] = new
    end
    return _renamed(f, m)
end

struct RenameWithStep{F, S} <: Step
    fn::F
    sel::S
end
"`rename_with(fn, sel = everything())`: rename the selected columns to `fn(name::String)`."
rename_with(fn, sel = everything()) = RenameWithStep(fn, sel)
Base.show(io::IO, s::RenameWithStep) = print(io, "rename_with(", _fname(s.fn), ", ", _selrepr(s.sel), ")")
apply(s::RenameWithStep, f::Frame) =
    _renamed(f, Dict{Symbol, Symbol}(f.names[i] => Symbol(s.fn(string(f.names[i]))) for i in resolve(s.sel, f)))

struct RelocateStep <: Step
    sels::Vector{Any}
    before::Any
    after::Any
end
"`relocate(sel...; before = nothing, after = nothing)`: move columns (to the front by default)."
function relocate(sels...; before = nothing, after = nothing)
    before !== nothing && after !== nothing && throw(ArgumentError("relocate: give before or after, not both"))
    return RelocateStep(Any[sels...], before, after)
end
Base.show(io::IO, s::RelocateStep) = print(
    io, "relocate(", join(_selrepr.(s.sels), ", "),
    s.before === nothing ? "" : "; before = $(_selrepr(s.before))", s.after === nothing ? "" : "; after = $(_selrepr(s.after))", ")"
)
apply(s::RelocateStep, f::Frame) = _relocate(f, isempty(s.sels) ? Int[] : resolve(s.sels, f), s.before, s.after)
function _relocate(f::Frame, moving::Vector{Int}, before, after)
    rest = [i for i in eachindex(f.names) if !(i in moving)]
    pos = if before !== nothing
        b = resolve(before, f)
        anchor = minimum(b)
        count(i -> i < anchor, rest)
    elseif after !== nothing
        a = resolve(after, f)
        anchor = maximum(a)
        count(i -> i <= anchor, rest)
    else
        0
    end
    order = [rest[1:pos]; moving; rest[(pos + 1):end]]
    return Frame(f.names[order], f.columns[order], copy(f.groups), f.gindex, f.nrow)
end

# =============================================================================================
# mutate (ADR-0002 rule 14; CF-003, CF-004, CF-006, CF-017)

struct MutateStep <: Step
    outs::Vector{Output}
    by::Any
    keep::Symbol
    before::Any
    after::Any
end

const MUTATE_RESERVED = (:by, :keep, :before, :after)

"""
    mutate(name = expr, ...; by, keep = :all, before, after)
    mutate("name" => expr, across(...), ...)

Add or replace columns. Keyword outputs apply in order, so later ones see earlier ones;
positional outputs (`across`, `"name" => expr`) are allowed only without keyword outputs.
`by`, `keep`, `before` and `after` are reserved options (CF-017): create such a column with a
Pair. Under grouping, expressions are evaluated per group (window functions). `name = nothing`
removes a column. `keep` is `:all`, `:used`, `:unused` or `:none`.
"""
function mutate(args...; kw...)
    outs, opts = _outputs(:mutate, args, kw, MUTATE_RESERVED)
    keep = Symbol(get(opts, :keep, :all))
    keep in (:all, :used, :unused, :none) || throw(ArgumentError("mutate: keep must be :all, :used, :unused or :none, got $(repr(keep))"))
    before, after = get(opts, :before, nothing), get(opts, :after, nothing)
    before !== nothing && after !== nothing && throw(ArgumentError("mutate: give before or after, not both"))
    return MutateStep(outs, get(opts, :by, nothing), keep, before, after)
end
Base.show(io::IO, s::MutateStep) = print(io, "mutate(", _fmtoutputs(s.outs), _fmtopts(s), ")")
function _fmtopts(s::MutateStep)
    o = String[]
    s.by === nothing || push!(o, "by = $(repr(s.by))")
    s.keep === :all || push!(o, "keep = $(repr(s.keep))")
    s.before === nothing || push!(o, "before = $(repr(s.before))")
    s.after === nothing || push!(o, "after = $(repr(s.after))")
    return isempty(o) ? "" : "; " * join(o, ", ")
end

function _withby(f::Frame, by, verb)
    by === nothing && return f, nothing
    isgrouped(f) && throw(ArgumentError("$verb: by = … cannot be used on a grouped frame; ungroup() first"))
    keys = Symbol[f.names[i] for i in resolve(by, f)]
    return regroup(f, keys), keys
end

function apply(s::MutateStep, f0::Frame)
    f, by = _withby(f0, s.by, "mutate")
    gi = gindex(f)
    names = copy(f.names)
    cols = copy(f.columns)
    used = Set{Symbol}()
    created = Symbol[]
    cur = f
    for o in s.outs
        for (nm, x) in _expand(Output[o], SelectCtx(cur))
            nm in f.groups && throw(ArgumentError("mutate: cannot modify the grouping column $(repr(nm)); ungroup() first"))
            i = findfirst(==(nm), names)
            if x === nothing
                i === nothing || (deleteat!(names, i); deleteat!(cols, i))
            else
                _usedcols!(used, x)
                col = column(eval_column(x, Env(cur), gi))
                if i === nothing
                    push!(names, nm)
                    push!(cols, col)
                    push!(created, nm)
                else
                    cols[i] = col
                end
            end
            cur = Frame(names, cols, copy(f.groups), gi, f.nrow)
        end
    end
    if s.keep !== :all
        orig = Set(f.names)
        keepit(n) = n in f.groups || n in created || !(n in orig) ? true :
            s.keep === :used ? n in used : s.keep === :unused ? !(n in used) : false
        sel = [i for (i, n) in enumerate(names) if keepit(n) || (n in orig && any(o -> o isa Pair && o.first == n, s.outs))]
        cur = Frame(names[sel], cols[sel], copy(f.groups), gi, f.nrow)
    end
    if (s.before !== nothing || s.after !== nothing) && !isempty(created)
        moving = [i for (i, n) in enumerate(cur.names) if n in created]
        cur = _relocate(cur, moving, s.before, s.after)
    end
    by === nothing || (cur = Frame(copy(cur.names), copy(cur.columns), Symbol[], nothing, cur.nrow))
    return cur
end

# =============================================================================================
# pull

struct PullStep <: Step
    x::Any
end
"`pull(x = -1)`: the column `x` (a name, `c.x`, a position, negative from the end, or an expression) as a vector."
pull(x = -1) = PullStep(x)
Base.show(io::IO, s::PullStep) = print(io, "pull(", s.x isa Node ? s.x : repr(s.x), ")")
function apply(s::PullStep, f::Frame)
    x = s.x
    x isa Integer && return f.columns[x < 0 ? length(f.names) + x + 1 : x]
    x isa Union{Symbol, AbstractString} && return getcol(f, Symbol(x))
    x isa Col && return getcol(f, x.name)
    x isa Node && return column(eval_column(x, Env(f), gindex(f)))
    throw(ArgumentError("pull: expected a column name, position or expression, got $(repr(x))"))
end
