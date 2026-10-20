# Filter predicates of the lazy optimizer (spec docs/superpowers/specs/2026-10-20-phase3-lazy-design.md
# §4; ADR-0004 rules 1, 3, 4; CF-012, CF-013): conjuncts, totality, the `Tables.Scan`
# translation (with its differential test, ADR-0004 rule 1) and statistics pruning.

@testsnippet Pred begin
    using Tables, Dates
    using ChuiFrames: Node, Call, Lit, conjuncts, istotal, to_scan, may_match
    tys(t) = Dict{Symbol, Type}(k => eltype(v) for (k, v) in pairs(t))
    # The rows (by index) eager `filter(p)` keeps.
    function kept(p, t)
        n = length(first(values(t)))
        f = filter(p)(merge(t, (i__ = collect(1:n),)))
        return collect(Tables.getcolumn(Tables.columns(f), :i__))
    end
    st(; lo = nothing, hi = nothing, nnull = nothing, nnan = nothing) = (; lo, hi, nnull, nnan, ndistinct = nothing)
    statsof(d) = col -> get(d, col, nothing)
end

@testitem "predicates: conjuncts splits on .& only" tags = [:unit] setup = [Pred] begin
    a, b, d = c.x .> 1, c.y .< 2, ismissing.(c.z)
    @test conjuncts(a) == [a]
    @test conjuncts(a .& b) == [a, b]
    @test conjuncts((a .& b) .& d) == [a, b, d]
    @test conjuncts(a .& (b .& d)) == [a, b, d]
    @test conjuncts(a .| b) == [a .| b]
    @test conjuncts(.!(a .& b)) == [.!(a .& b)]
    @test conjuncts(c.x) == [c.x]
end

@testitem "predicates: istotal" tags = [:unit] setup = [Pred] begin
    T = Dict{Symbol, Type}(
        :i => Int, :mi => Union{Missing, Int}, :b => Bool, :f => Float64, :mf => Union{Missing, Float64},
        :f32 => Float32, :s => String, :ms => Union{Missing, String}, :d => Date, :dt => DateTime,
        :ts => ArrowTimestamp{Millisecond, nothing}, :tz => ArrowTimestamp{Millisecond, :UTC},
        :a => Any, :r => Real, :m => Missing, :sym => Symbol, :v => Vector{Int}
    )
    for op in (==, !=, <, <=, >, >=)
        @test istotal(broadcast(op, c.i, 1), T)
        @test istotal(broadcast(op, 1, c.i), T)                  # literal first
        @test istotal(broadcast(op, c.mf, 1.5), T)
        @test istotal(broadcast(op, c.f, NaN), T)
        @test istotal(broadcast(op, c.f32, 1), T)
        @test istotal(broadcast(op, c.b, true), T)
        @test istotal(broadcast(op, c.ms, "x"), T)
        @test istotal(broadcast(op, c.d, Date(2020)), T)
        @test istotal(broadcast(op, c.dt, DateTime(2020)), T)
        @test istotal(broadcast(op, c.ts, DateTime(2020)), T)    # naive vs DateTime compares
        @test !istotal(broadcast(op, c.a, 1), T)                 # abstract column: barrier
        @test !istotal(broadcast(op, c.r, 1), T)
        @test !istotal(broadcast(op, c.m, 1), T)
        @test !istotal(broadcast(op, c.sym, :a), T)              # not a total family
        @test !istotal(broadcast(op, c.v, 1), T)
        @test !istotal(broadcast(op, c.nope, 1), T)              # column not in the schema
        @test !istotal(Call(op, Node[c.i, Lit(missing)]), T)     # (built directly: no lint warning)
        @test !istotal(broadcast(op, c.i, c.mi), T)              # column vs column
        @test !istotal(broadcast(op, c.i .+ 1, 1), T)
        @test !istotal(broadcast(op, c.i, Ref([1, 2])), T)       # scalar Lit holding a vector
    end
    # vector literal: not scalar
    @test !istotal(Call(==, Node[c.i, Lit([1, 2])]), T)
    # String column vs Int literal: == / != compare (false / true), ordering throws
    @test istotal(c.s .== 1, T) && istotal(c.s .!= 1, T)
    @test !istotal(c.s .< 1, T) && !istotal(1 .<= c.s, T)
    # zoned timestamp vs DateTime: every comparison throws (ADR-0021 rule 5)
    @test !istotal(c.tz .== DateTime(2020), T) && !istotal(c.tz .< DateTime(2020), T)
    @test istotal(c.tz .< ArrowTimestamp{Second, :UTC}(0), T)
    # isnan / ismissing
    @test istotal(isnan.(c.f), T) && istotal(isnan.(c.mf), T) && istotal(isnan.(c.f32), T)
    @test !istotal(isnan.(c.i), T) && !istotal(isnan.(c.a), T) && !istotal(isnan.(c.s), T)
    @test istotal(ismissing.(c.mi), T) && istotal(ismissing.(c.s), T) && istotal(ismissing.(c.sym), T)
    @test !istotal(ismissing.(c.a), T) && !istotal(ismissing.(c.m), T) && !istotal(ismissing.(c.nope), T)
    # combinators
    @test istotal(.!(c.f .<= 2.0), T)
    @test istotal((c.i .> 1) .& (c.s .== "a"), T)
    @test istotal((c.i .> 1) .| ismissing.(c.mf), T)
    @test istotal(.!((c.i .> 1) .| isnan.(c.f)), T)
    @test !istotal((c.i .> 1) .& (c.a .== 1), T)
    @test !istotal((c.i .> 1) .| (c.s .< 1), T)
    @test !istotal(c.b, T)                                    # bare Bool column: not classified
    @test !istotal(startswith.(c.s, "a"), T)
    @test !istotal(in.(c.i, Ref(Set([1]))), T)
end

@testitem "predicates: to_scan shapes" tags = [:unit] setup = [Pred] begin
    T = Dict{Symbol, Type}(:f => Union{Missing, Float64}, :s => String, :a => Any)
    @test to_scan(c.f .> 1.0, T) == Tables.colcmp(>, Tables.col(:f), 1.0)
    @test to_scan(1.0 .< c.f, T) == Tables.colcmp(>, Tables.col(:f), 1.0)    # flipped
    @test to_scan(1.0 .>= c.f, T) == Tables.colcmp(<=, Tables.col(:f), 1.0)
    @test to_scan(1.0 .!= c.f, T) == Tables.colcmp(!=, Tables.col(:f), 1.0)
    @test to_scan(ismissing.(c.f), T) == Tables.isnull(Tables.col(:f))
    @test to_scan(.!ismissing.(c.f), T) == !Tables.isnull(Tables.col(:f))
    @test to_scan(.!(c.f .> 1.0), T) isa Tables.ScanExpr
    @test to_scan((c.f .> 1.0) .& (c.s .== "a"), T) isa Tables.ScanExpr
    @test to_scan(isnan.(c.f), T) === nothing
    @test to_scan((c.f .> 1.0) .& isnan.(c.f), T) === nothing
    @test to_scan(.!isnan.(c.f), T) === nothing
    @test to_scan(c.a .> 1, T) === nothing                 # not total
    @test to_scan(c.s .< 1, T) === nothing                 # throws on a String
    @test to_scan(startswith.(c.s, "a"), T) === nothing    # not classified
end

@testitem "predicates: Tables.Scan differential (ADR-0004 rule 1)" tags = [:unit] setup = [Pred] begin
    vals = Union{Missing, Float64}[NaN, -NaN, 0.0, -0.0, missing, Inf, -Inf, 1.0, 2.5, -1.0]
    t = (
        f = vals,
        g = Float64[x === missing ? 7.0 : x for x in vals],
        i = Union{Missing, Int}[1, missing, 0, -1, 2, 3, missing, 1, 0, 5],
        s = Union{Missing, String}["a", "b", missing, "", "ab", "b", "B", missing, "a", "z"],
        d = Union{Missing, Date}[Date(2020, i) for i in 1:10],
    )
    t = merge(t, (d = Union{Missing, Date}[i == 4 ? missing : t.d[i] for i in 1:10],))
    T = tys(t)
    lits = Dict(
        :f => [0.0, -0.0, 1.0, Inf, -Inf, NaN, 1], :g => [0.0, -0.0, 7.0, NaN, -Inf],
        :i => [0, 1, 1.5, -1], :s => ["a", "", "b", "B"], :d => [Date(2020, 3)]
    )
    preds = Node[]
    for (col, ls) in lits, v in ls, op in (==, !=, <, <=, >, >=)
        push!(preds, broadcast(op, c[col], v), broadcast(op, v, c[col]))
    end
    append!(preds, [c.s .== 1, c.s .!= 1])                 # == / != of String vs Int
    for col in keys(t)
        push!(preds, ismissing.(c[col]), .!ismissing.(c[col]))
    end
    base = copy(preds)
    for k in 1:3:length(base)
        p, q = base[k], base[mod1(k + 7, length(base))]
        push!(preds, .!p, p .& q, p .| q, .!(p .| q), .!(p .& .!q), (p .| ismissing.(c.f)) .& .!q)
    end
    nchecked = Ref(0)
    for p in preds
        @test istotal(p, T)
        sc = to_scan(p, T)
        @test sc !== nothing
        sc === nothing && continue
        want = kept(p, t)
        @test findall(Tables.filtermask(sc, t)) == want
        got = Tables.scan(merge(t, (i__ = collect(1:10),)), Tables.Scan(; filter = sc))
        ok = collect(Tables.getcolumn(Tables.columns(got), :i__)) == want
        ok || @info "Scan differs from filter" p sc want
        @test ok
        nchecked[] += 1
    end
    @test nchecked[] == length(preds) > 400
end

@testitem "predicates: may_match comparisons and bounds" tags = [:unit] setup = [Pred] begin
    mm(p, s) = may_match(p, statsof(Dict(:x => s)))
    full = st(lo = 1.0, hi = 3.0, nnull = 0, nnan = 0)
    # ranges (lo/hi are bounds)
    @test !mm(c.x .> 3.0, full) && mm(c.x .> 2.9, full)
    @test !mm(c.x .>= 3.5, full) && mm(c.x .>= 3.0, full)
    @test !mm(c.x .< 1.0, full) && mm(c.x .< 1.1, full)
    @test !mm(c.x .<= 0.5, full) && mm(c.x .<= 1.0, full)
    @test !mm(c.x .== 0.0, full) && !mm(c.x .== 4.0, full) && mm(c.x .== 2.0, full)
    @test !mm(3.0 .< c.x, full) && !mm(0.5 .>= c.x, full)          # literal first
    @test !mm(c.x .!= 1.0, st(lo = 1.0, hi = 1.0, nnull = 3, nnan = 0))
    @test mm(c.x .!= 1.0, st(lo = 1.0, hi = 2.0, nnan = 0))
    # Int column, Float literal
    @test !mm(c.x .> 2.5, st(lo = 0, hi = 2)) && mm(c.x .> 1.5, st(lo = 0, hi = 2))
    # -0.0 and 0.0 are equal (IEEE)
    z = st(lo = -0.0, hi = 0.0, nnan = 0)
    @test mm(c.x .== 0.0, z) && mm(c.x .== -0.0, z)
    @test !mm(c.x .!= 0.0, z) && !mm(c.x .!= -0.0, st(lo = 0.0, hi = 0.0, nnan = 0))
    @test !mm(c.x .< 0.0, st(lo = -0.0, hi = 1.0)) && !mm(c.x .< -0.0, st(lo = 0.0, hi = 1.0))
    @test !mm(c.x .> 0.0, st(lo = -1.0, hi = -0.0)) && mm(c.x .>= 0.0, st(lo = -1.0, hi = -0.0))
    # unknown statistics, fields, NaN/missing bounds, NaN literal: keep
    @test may_match(c.x .> 5.0, _ -> nothing)
    @test may_match(c.x .> 5.0, _ -> error("statistics failed"))
    @test mm(c.x .> 5.0, st(lo = 1.0)) && mm(c.x .< 0.0, st(hi = 3.0))
    @test mm(c.x .> 5.0, st(lo = 1.0, hi = NaN)) && mm(c.x .> 5.0, st(lo = 1.0, hi = missing))
    @test mm(c.x .== NaN, full) && mm(c.x .> NaN, full)
    @test may_match(c.y .> 5.0, statsof(Dict(:x => full)))
    # a comparison that throws keeps: String bounds vs Int literal; zoned vs naive timestamps
    @test mm(c.x .< 1, st(lo = "a", hi = "b"))
    @test mm(c.x .== 1, st(lo = "a", hi = "b", nnan = 0))
    tz = ArrowTimestamp{Millisecond, :UTC}
    @test mm(c.x .> DateTime(2030), st(lo = tz(0), hi = tz(1000)))
    @test !mm(c.x .> DateTime(2030), st(lo = DateTime(2000), hi = DateTime(2001)))
    @test !mm(c.x .> ArrowTimestamp{Second}(10), st(lo = DateTime(1970), hi = DateTime(1970, 1, 1, 0, 0, 5)))
    @test !mm(c.x .< "b", st(lo = "c", hi = "d")) && mm(c.x .< "cc", st(lo = "c", hi = "d"))
    # vector literal, unclassified predicates
    @test mm(Call(==, Node[c.x, Lit([9.0])]), full)
    @test mm(startswith.(c.x, "z"), full) && mm(c.x .+ 1 .> 100.0, full) && mm(c.x, full)
end

@testitem "predicates: may_match NaN and missing conditions (CF-013)" tags = [:unit] setup = [Pred] begin
    mm(p, s) = may_match(p, statsof(Dict(:x => s)))
    # CF-013's cases
    @test kept(.!(c.f .<= 2.0), (f = [1.0, NaN, 2.0],)) == [2]
    @test may_match(.!(c.f .<= 2.0), statsof(Dict(:f => st(lo = 1.0, hi = 2.0, nnull = 0))))
    @test !may_match(.!(c.f .<= 2.0), statsof(Dict(:f => st(lo = 1.0, hi = 2.0, nnull = 0, nnan = 0))))
    @test kept(c.f .!= 1.0, (f = [1.0, NaN],)) == [2]
    @test may_match(c.f .!= 1.0, statsof(Dict(:f => st(lo = 1.0, hi = 1.0))))
    # negations push inward and need nnan == 0
    @test mm(.!(c.x .< 5.0), st(lo = 1.0, hi = 3.0, nnan = 1))
    @test !mm(.!(c.x .< 5.0), st(lo = 1.0, hi = 3.0, nnan = 0))
    @test mm(.!(c.x .== 2.0), st(lo = 2.0, hi = 2.0))
    @test !mm(.!(c.x .== 2.0), st(lo = 2.0, hi = 2.0, nnan = 0))
    @test !mm(.!(c.x .!= 9.0), st(lo = 1.0, hi = 3.0))       # !(x != v) is false on NaN
    @test !mm(.!(.!(c.x .> 5.0)), st(lo = 1.0, hi = 3.0))    # double negation: no NaN condition
    # missing never makes a comparison or its negation true
    @test !mm(c.x .> 5.0, st(lo = 1.0, hi = 3.0, nnull = 10))
    # ismissing / isnan
    @test !mm(ismissing.(c.x), st(nnull = 0)) && mm(ismissing.(c.x), st(nnull = 2)) && mm(ismissing.(c.x), st())
    @test !mm(isnan.(c.x), st(nnan = 0)) && mm(isnan.(c.x), st(nnan = 1)) && mm(isnan.(c.x), st())
    @test mm(.!ismissing.(c.x), st(nnull = 0, lo = 1.0, hi = 1.0))
    @test mm(.!isnan.(c.x), st(nnan = 0, nnull = 0))
    # & prunes when either side does; | when both do (De Morgan under !)
    s = st(lo = 1.0, hi = 3.0, nnull = 1, nnan = 0)
    @test !mm((c.x .> 5.0) .& startswith.(c.x, "q"), s)
    @test mm((c.x .> 5.0) .| ismissing.(c.x), s)
    @test !mm((c.x .> 5.0) .| (c.x .< 0.0), s)
    @test !mm((c.x .> 5.0) .| ismissing.(c.x), st(lo = 1.0, hi = 3.0, nnull = 0))
    @test !mm(.!((c.x .<= 5.0) .| ismissing.(c.x)), s)       # !a & !b: !a prunes (nnan 0)
    @test mm(.!((c.x .<= 5.0) .& ismissing.(c.x)), s)        # !a | !b: !ismissing keeps
    @test !mm(.!((c.x .<= 5.0) .& (c.x .>= 0.0)), s)
    @test mm(.!((c.x .<= 5.0) .& (c.x .>= 0.0)), st(lo = 1.0, hi = 3.0))
end

@testsnippet PredProp begin
    using Supposition, Supposition.Data
    using Tables
    using ChuiFrames: may_match
    const PV = Union{Missing, Float64}[NaN, -NaN, 0.0, -0.0, 1.0, 2.0, 3.0, missing, Inf, -Inf]
    const PL = [0.0, -0.0, 1.0, 2.0, 3.0, Inf, -Inf]
    const OPS = (==, !=, <, <=, >, >=)
    # Decode a code stream into a predicate over c.x (depth-bounded).
    function decode(codes, pos, depth)
        k = pos[] <= length(codes) ? codes[pos[]] : 0
        pos[] += 1
        nxt() = (v = pos[] <= length(codes) ? codes[pos[]] : 0; pos[] += 1; v)
        kind = depth >= 3 ? k % 8 : k % 11
        if kind < 6
            v = PL[nxt() % length(PL) + 1]
            return isodd(nxt()) ? broadcast(OPS[kind + 1], v, c.x) : broadcast(OPS[kind + 1], c.x, v)
        elseif kind == 6
            return isnan.(c.x)
        elseif kind == 7
            return ismissing.(c.x)
        elseif kind == 8
            return .!decode(codes, pos, depth + 1)
        else
            a = decode(codes, pos, depth + 1)
            b = decode(codes, pos, depth + 1)
            return kind == 9 ? a .& b : a .| b
        end
    end
    const LOOSEN = [0.0, 0.0, 0.5, 1.0, Inf]
    partgen = Data.Vectors(Data.SampledFrom(PV); min_size = 0, max_size = 8)
    codegen = Data.Vectors(Data.Integers(0, 10_000); min_size = 1, max_size = 16)
    knobgen = Data.Vectors(Data.Integers(0, 10_000); min_size = 8, max_size = 8)
    # Valid statistics for `x`, shaped by the knobs.
    function mkstats(x, kn)
        kn[1] % 6 == 0 && return nothing
        fin = [v for v in x if !ismissing(v) && !isnan(v)]
        lo, hi = if isempty(fin)
            (PL[kn[2] % length(PL) + 1], PL[kn[3] % length(PL) + 1])      # vacuous bounds
        else
            (minimum(fin) - LOOSEN[kn[2] % length(LOOSEN) + 1], maximum(fin) + LOOSEN[kn[3] % length(LOOSEN) + 1])
        end
        iszero(lo) && (lo = isodd(kn[4]) ? -0.0 : 0.0)                   # ±0.0 bounds are equal
        iszero(hi) && (hi = isodd(kn[5]) ? -0.0 : 0.0)
        kn[6] % 4 == 0 && (lo = nothing)
        kn[6] % 4 == 1 && (hi = nothing)
        nnan = isodd(kn[7]) ? count(v -> !ismissing(v) && isnan(v), x) : nothing
        nnull = isodd(kn[8]) ? count(ismissing, x) : nothing
        return (; lo, hi, nnull, nnan, ndistinct = nothing)
    end
end

@testitem "property: may_match never prunes a partition with a kept row (CF-013)" tags = [:property] setup = [PredProp] begin
    function sound(x, codes, knobs)
        p = decode(codes, Ref(1), 0)
        s = mkstats(x, knobs)
        may_match(p, col -> col === :x ? s : nothing) && return true
        f = filter(p)((x = Union{Missing, Float64}[x...],))
        return length(Tables.getcolumn(Tables.columns(f), :x)) == 0
    end
    t0 = time()
    sr = @check record = false db = false max_examples = 3000 sound(partgen, codegen, knobgen)
    @test Supposition.results(sr).ispass
    @test time() - t0 < 300
end
