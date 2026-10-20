# An independent reference evaluator (ADR-0003 "Testing"): row loops and Base/Statistics only,
# no optimizer, no threads, no engine code. It shares only the expression AST (the node
# structs) and CC-007's exception table with the engine. Tables are NamedTuples of Vectors plus
# a vector of grouping column names.

@testmodule Oracle begin
    using Statistics
    import ChuiFrames
    const CF = ChuiFrames

    struct OTable
        cols::Vector{Pair{Symbol, Vector{Any}}}
        groups::Vector{Symbol}
    end
    OTable(nt::NamedTuple) = OTable([k => Any[x for x in v] for (k, v) in pairs(nt)], Symbol[])
    nrows(t::OTable) = isempty(t.cols) ? 0 : length(t.cols[1].second)
    getc(t::OTable, n::Symbol) = (i = findfirst(p -> p.first == n, t.cols); i === nothing ? throw(ArgumentError("no column $n")) : t.cols[i].second)
    function setc(t::OTable, n::Symbol, v::Vector{Any})
        cols = copy(t.cols)
        i = findfirst(p -> p.first == n, cols)
        i === nothing ? push!(cols, n => v) : (cols[i] = n => v)
        return OTable(cols, t.groups)
    end
    takerows(t::OTable, rows) = OTable([k => v[rows] for (k, v) in t.cols], t.groups)

    # --- key equality (ADR-0003 rule 8), written out explicitly -----------------------------
    canon(x) = x isa AbstractFloat ? (isnan(x) ? NaN : (x == 0 ? 0.0 : x)) : x
    keyeq(a, b) = isequal(canon(a), canon(b))
    # groups: first-seen keys, then sorted ascending by isless on canonical keys
    function groups(t::OTable)
        isempty(t.groups) && return [collect(1:nrows(t))]
        keycols = [getc(t, g) for g in t.groups]
        reps = Vector{Any}[]
        members = Vector{Int}[]
        for r in 1:nrows(t)
            k = Any[kc[r] for kc in keycols]
            j = findfirst(rep -> all(keyeq(a, b) for (a, b) in zip(rep, k)), reps)
            if j === nothing
                push!(reps, k)
                push!(members, [r])
            else
                push!(members[j], r)
            end
        end
        lt(a, b) = begin
            for (x, y) in zip(a, b)
                cx, cy = canon(x), canon(y)
                isless(cx, cy) && return true
                isless(cy, cx) && return false
            end
            false
        end
        order = sortperm(reps; lt = lt)
        return members[order]
    end

    # --- expression evaluation, one row at a time --------------------------------------------
    # CC-007's exception table for empty input
    function red(f::Symbol, v::Vector, pre)
        if f === :sum
            return isempty(v) ? 0 : sum(v)
        elseif f === :length
            return length(v)
        elseif f === :mean
            return isempty(v) ? NaN : mean(v)
        elseif f === :maximum
            isempty(v) && throw(ArgumentError("empty"))
            return maximum(v)
        elseif f === :minimum
            isempty(v) && throw(ArgumentError("empty"))
            return minimum(v)
        elseif f === :first
            isempty(v) && throw(BoundsError())
            return first(v)
        elseif f === :count
            return isempty(v) ? 0 : count(v)
        end
        error("oracle: reduction $f not modelled")
    end
    # value of node `x` at row `r` of table `t`, within the group `rows`
    function val(x, t::OTable, r::Int, rows::Vector{Int})
        if x isa CF.Col
            return getc(t, x.name)[r]
        elseif x isa CF.Lit
            return x.scalar ? x.value : x.value[r]
        elseif x isa CF.NRows
            return length(rows)
        elseif x isa CF.Call
            return x.f(Any[val(a, t, r, rows) for a in x.args]...)
        elseif x isa CF.Reduce
            arg = x.arg isa CF.SkipMiss ? x.arg.inner : x.arg
            vs = Any[val(arg, t, q, rows) for q in rows]
            x.arg isa CF.SkipMiss && filter!(!ismissing, vs)
            return red(x.fname, [v for v in vs], x.pre)
        end
        error("oracle: node $(typeof(x)) not modelled")
    end
    # a reduction evaluated once per group (summarise), with no row
    function groupval(x, t::OTable, rows::Vector{Int})
        x isa CF.Reduce || x isa CF.NRows || error("oracle: summarise output must be a reduction")
        return val(x, t, isempty(rows) ? 0 : rows[1], rows)
    end

    # --- verbs ------------------------------------------------------------------------------
    function ofilter(t::OTable, p)
        keep = Int[]
        for rows in groups(t), r in rows
            b = val(p, t, r, rows)
            b isa Union{Bool, Missing} || throw(ArgumentError("non-Bool"))
            b === true && push!(keep, r)
        end
        return takerows(t, sort!(keep))
    end
    function omutate(t::OTable, name::Symbol, x)
        out = Vector{Any}(undef, nrows(t))
        for rows in groups(t), r in rows
            out[r] = val(x, t, r, rows)
        end
        return setc(t, name, out)
    end
    ogroup(t::OTable, keys::Vector{Symbol}) = OTable(t.cols, keys)
    oungroup(t::OTable) = OTable(t.cols, Symbol[])
    function osummarise(t::OTable, outs::Vector{Pair{Symbol, Any}})
        gs = groups(t)
        if !isempty(t.groups) && nrows(t) == 0
            gs = Vector{Int}[]
        end
        cols = Pair{Symbol, Vector{Any}}[]
        for g in t.groups
            kc = getc(t, g)
            push!(cols, g => Any[kc[rows[1]] for rows in gs])
        end
        for (nm, x) in outs
            push!(cols, nm => Any[groupval(x, t, rows) for rows in gs])
        end
        g = isempty(t.groups) ? Symbol[] : t.groups[1:(end - 1)]
        return OTable(cols, g)
    end
    # arrange: insertion sort (stable), regular values by isless with ±0 tied, then NaN and
    # missing as one class in input order, in both directions (ADR-0002 rule 13)
    tail(x) = ismissing(x) || (x isa AbstractFloat && isnan(x))
    function before(a, b, rev)          # strictly before?
        tail(a) && return false
        tail(b) && return true
        ca, cb = canon(a), canon(b)
        return rev ? isless(cb, ca) : isless(ca, cb)
    end
    function oarrange(t::OTable, keys::Vector)
        rows = collect(1:nrows(t))
        kv = [(getc(t, k isa CF.Desc ? k.inner.name : k.name), k isa CF.Desc) for k in keys]
        lt(i, j) = begin
            for (v, rev) in kv
                before(v[i], v[j], rev) && return true
                before(v[j], v[i], rev) && return false
            end
            false
        end
        for i in 2:length(rows)
            j = i
            while j > 1 && lt(rows[j], rows[j - 1])
                rows[j], rows[j - 1] = rows[j - 1], rows[j]
                j -= 1
            end
        end
        return takerows(t, rows)
    end

    "Run a list of step specs (the same specs drive the engine pipeline)."
    function run(t::OTable, specs)
        for s in specs
            kind = s[1]
            t = kind === :filter ? ofilter(t, s[2]) :
                kind === :mutate ? omutate(t, s[2], s[3]) :
                kind === :group ? ogroup(t, s[2]) :
                kind === :ungroup ? oungroup(t) :
                kind === :summarise ? osummarise(t, s[2]) :
                kind === :arrange ? oarrange(t, s[2]) : error("oracle: $kind")
        end
        return t
    end

    "The engine step for a spec."
    function step(s)
        kind = s[1]
        kind === :filter && return Base.filter(s[2])
        kind === :mutate && return CF.mutate(; (s[2] => s[3],)...)
        kind === :group && return CF.group_by(s[2]...)
        kind === :ungroup && return CF.ungroup()
        kind === :summarise && return CF.summarise(; (p.first => p.second for p in s[2])...)
        kind === :arrange && return CF.arrange(s[2]...)
        error("oracle: $kind")
    end

    "Approximate frame equality (CF-008 Definitions) between an engine result and the oracle."
    function agree(f, o::OTable)
        names = collect(CF.Tables.columnnames(f))
        names == [p.first for p in o.cols] || return false
        CF.groupcols(f) == o.groups || return false
        for (n, ov) in o.cols
            ev = collect(CF.Tables.getcolumn(f, n))
            length(ev) == length(ov) || return false
            for (a, b) in zip(ev, ov)
                isequal(a, b) && continue
                a isa AbstractFloat && b isa AbstractFloat && isapprox(a, b; rtol = sqrt(eps()), atol = 1.0e-9) && continue
                return false
            end
        end
        return true
    end
end
