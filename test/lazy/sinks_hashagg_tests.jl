# The lazy hash-aggregate sink (phase-4 spec §2.1, §2.3; plan task 5): `group_by ⨟ summarise`
# and `summarise(...; by)` with simple aggregates fold the streamed stage's morsels per task
# (typed keys, typed accumulators), merge in morsel order and sort by the keys, with no gathered
# frame; the result equals eager (CF-008: exactly; floats from reductions within CC-004's
# tolerance, test/contracts/chui-core.md; the Float64 checks here use the stricter rtol = 1e-12,
# the Float32 test CC-004's √eps(Float32) and τ), element types too.

@testsnippet SK begin
    using Tables, Statistics
    using DataAPI: nrow
    const ⨟ = ChuiFrames.Upstream.:⨟
    const CF = ChuiFrames
    function outcome(f)
        try
            return (:ok, f())
        catch err
            return (:err, typeof(err))
        end
    end
    unwrap(err) = err isa CF.MorselError ? err.err : CF._taskerror(err)
    valeq(a, b, approx) = isequal(a, b) || (approx && a isa AbstractFloat && b isa AbstractFloat && isapprox(a, b; rtol = 1.0e-12))
    # names, grouping, drop flag, element types and values (floats within tolerance)
    function same(a, b; approx = true)
        a.names == b.names && a.nrow == b.nrow && a.groups == b.groups && a.drop == b.drop || return false
        for (ca, cb) in zip(a.columns, b.columns)
            eltype(ca) == eltype(cb) || return false
            all(i -> valeq(ca[i], cb[i], approx), eachindex(ca)) || return false
        end
        return true
    end
    # the engine without collect's replay, and which sink ran
    function rawrun(q; morsel, threads)
        st = CF.ExecStats()
        r = CF.execute(CF.physical(CF.optimize(q).plan); morsel, threads, stats = st)
        return r, st
    end
    # lazy == eager on every morsel size and threading, and the sink ran (when `sink`)
    function agrees(p, input; morsels = 1:7, sink = true, approx = true)
        e = outcome(() -> p(input isa CF.Source ? CF.read_source(input) : input))
        for m in morsels, th in (true, false)
            l = outcome(() -> collect(p(lazy(input)); morsel = m, threads = th))
            e[1] === l[1] || return false
            e[1] === :err && (e[2] === l[2] || return false; continue)
            same(e[2], l[2]; approx) || return false
            r, st = rawrun(p(lazy(input)); morsel = m, threads = th)
            same(e[2], r; approx) || return false
            st.sink === (sink ? :hashagg : :none) || return false
        end
        return true
    end
    t = (
        g = ["a", "b", "a", "c", "b", "a", "c", "a"],
        k = [1, 2, 1, 2, 1, 2, 1, 2],
        x = Union{Missing, Float64}[1.5, NaN, -0.0, missing, 0.0, 2.5, -1.0, 4.0],
        y = [3, -1, 4, 1, -5, 9, 2, 6],
        i = Int8[100, 100, 100, -7, 3, 1, 2, 3],
        f = Float32[1.5, 2.25, -0.5, 3.0, 0.125, 8.0, -2.0, 1.0],
        b = [true, false, true, true, false, false, true, true],
        s = ["p", "q", "r", "s", "t", "u", "v", "w"],
    )
end

@testitem "hash-aggregate sink: explain says when it runs and why not" tags = [:unit] setup = [SK] begin
    ex(p) = sprint(explain, p(lazy(t)))
    s = ex(group_by(:g) ⨟ summarise(n = n_rows(), m = mean(c.y)))
    @test occursin("then hash-aggregate sink: group_by(:g) ⨟ summarise(n = n_rows(), m = mean(c.y))", s)
    @test !occursin("then materialize", s)
    s = ex(summarise(n = n_rows(); by = :g) ⨟ arrange(c.n))
    @test occursin("then hash-aggregate sink: summarise(n = n_rows(); by = :g)", s)
    @test occursin("then eagerly: arrange(c.n)", s)
    s = ex(group_by(:g) ⨟ summarise(m = median(c.y)))
    @test occursin("then materialize", s) && occursin("then eagerly: group_by(:g) ⨟ summarise(m = median(c.y))", s)
    @test occursin("no hash-aggregate sink: not a simple aggregate: `median`", s)
    @test occursin("no hash-aggregate sink: a computed group key", ex(group_by(:h => c.y .% 2) ⨟ summarise(n = n_rows())))
    @test occursin("no hash-aggregate sink: not a simple aggregate", ex(group_by(:g) ⨟ summarise(m = mean(c.y) .+ 1)))
    @test occursin("no hash-aggregate sink: refers to the earlier output `y`", ex(group_by(:g) ⨟ summarise(y = sum(c.y), z = mean(c.y))))
    # no candidate: no note
    @test !occursin("hash-aggregate", ex(group_by(:g) ⨟ mutate(z = c.y .- mean(c.y))))
    @test !occursin("hash-aggregate", ex(filter(c.y .> 1)))
end

@testitem "hash-aggregate sink: lazy == eager on simple aggregates" tags = [:unit] setup = [SK] begin
    simple = Any[
        group_by(:g) ⨟ summarise(n = n_rows()),
        group_by(:g) ⨟ summarise(n = n_rows(), sy = sum(c.y), m = mean(c.x), mx = maximum(c.y), mn = minimum(c.y)),
        group_by(:g, :k) ⨟ summarise(sx = sum(skipmissing(c.x)), v = var(c.y), sd = std(c.f), e = extrema(c.y)),
        group_by(:k) ⨟ summarise(si = sum(c.i), mi = mean(c.i), pf = prod(c.f), sf = sum(c.f), cb = count(c.b), ab = any(c.b), al = all(c.b)),
        group_by(:x) ⨟ summarise(n = n_rows(), fs = first(c.s), ls = last(c.s), rs = reduce(*, c.s)),
        group_by(:g) ⨟ summarise(l = length(c.y), sa = sum(abs, c.y), mr = mapreduce(abs, +, c.y), ms = maximum(skipmissing(c.x))),
        group_by(:g) ⨟ summarise(s = sum(c.y), groups = :keep),
        group_by(:g, :k) ⨟ summarise(s = sum(c.y)),
        group_by(:g, :k) ⨟ summarise(s = sum(c.y), groups = :drop),
        summarise(n = n_rows(), m = mean(c.y); by = [:k, :g]),
        filter(c.y .> 0) ⨟ mutate(z = c.y .* 2) ⨟ group_by(:g) ⨟ summarise(sz = sum(c.z), fz = first(c.z)),
        group_by(:s) ⨟ summarise(n = n_rows()),
        group_by(:b, :g) ⨟ summarise(n = n_rows(), m = mean(c.f)) ⨟ arrange(c.m),
        filter(c.y .> 100) ⨟ group_by(:g) ⨟ summarise(n = n_rows(), s = sum(c.y)),
    ]
    for p in simple
        @test agrees(p, t)
    end
    # not simple: the gathered frame through the eager path (no sink), same results
    for p in (group_by(:g) ⨟ summarise(m = median(c.y)), group_by(:g) ⨟ summarise(d = n_distinct(c.s)))
        @test agrees(p, t; sink = false)
    end
    # empty input, and a source with no rows at all
    e = (g = String[], y = Int[])
    @test agrees(group_by(:g) ⨟ summarise(n = n_rows(), s = sum(c.y)), e; morsels = 1:2)
end

@testitem "hash-aggregate sink: exceptions as eager (CC-007, non-numeric sums)" tags = [:unit] setup = [SK] begin
    for p in (
            group_by(:g) ⨟ summarise(s = sum(c.s)),            # strings: + is a MethodError
            group_by(:g) ⨟ summarise(a = any(c.y)),            # any over non-Bool: TypeError
            group_by(:g) ⨟ summarise(m = maximum(skipmissing(c.x))) ⨟ filter(c.m .> 0),
            filter(ismissing.(c.x)) ⨟ group_by(:g) ⨟ summarise(m = maximum(skipmissing(c.x))),
        )
        @test agrees(p, t)
    end
    @test outcome(() -> (group_by(:g) ⨟ summarise(s = sum(c.s)))(t))[1] === :err
end

@testitem "hash-aggregate sink: Float32 sums and moments within CC-004's tolerance (review m1)" tags = [:unit] setup = [SK] begin
    # CF-008's tolerance for floats from reductions is CC-004's (test/contracts/chui-core.md,
    # "Float tolerance"): ε = √eps(T) of the input's float type, atol τ(agg, v) per aggregator.
    n = 3_000
    g = [string("k", mod(i * 31, 7)) for i in 1:n]
    f = Float32[sin(i) * 10.0f0^mod(i, 4) for i in 1:n]
    w = (g = g, f = f)
    p = group_by(:g) ⨟ summarise(s = sum(c.f), m = mean(c.f), v = var(c.f), sd = std(c.f))
    e = p(w)
    ε = sqrt(eps(Float32))
    τs = Dict(
        :s => v -> ε * sum(abs, v), :m => v -> ε * sum(abs, v) / length(v),
        :v => v -> ε * sum(abs2, v) / length(v), :sd => v -> sqrt(ε * sum(abs2, v) / length(v)),
    )
    for m in (7, 64, 1_000), th in (true, false)
        r, st = rawrun(p(lazy(w)); morsel = m, threads = th)
        @test st.sink === :hashagg
        @test r.names == e.names && collect(r.columns[1]) == collect(e.columns[1])
        @test all(eltype(a) == eltype(b) for (a, b) in zip(r.columns, e.columns))
        for (j, nm) in enumerate(e.names[2:end]), (k, key) in enumerate(e.columns[1])
            v = f[g .== key]
            a, b = e.columns[j + 1][k], r.columns[j + 1][k]
            @test isequal(a, b) || isapprox(a, b; atol = τs[nm](v), rtol = ε)
        end
    end
end

@testitem "dictionary levels with a statistics-pruned partition (review MAJOR 1, CF-008)" tags = [:unit] setup = [SK] begin
    # Two partitions with their own dictionaries; partition 2 is pruned by `y` statistics. Eager
    # (`read_source`) concatenates both, so `g` decodes and `drop = false` adds no level; the lazy
    # run must not keep partition 1's dictionary (with its unobserved level "zz") either.
    struct StatDictSource <: CF.Source
        parts::Vector{Frame}
    end
    CF.source_schema(s::StatDictSource) = Tables.Schema((:g, :y), (eltype(s.parts[1].columns[1]), Int))
    CF.source_label(::StatDictSource) = "dictionary source with y statistics"
    CF.plan_partitions(s::StatDictSource, scan::Tables.Scan; morsel::Int = 1) = (collect(eachindex(s.parts)), scan)
    CF.read_partition(s::StatDictSource, p::Int) = s.parts[p]
    function CF.partition_stats(s::StatDictSource, p::Int, col::Symbol)
        col === :y || return nothing
        y = s.parts[p].columns[2]
        return (; lo = minimum(y), hi = maximum(y), nnull = 0, nnan = 0, ndistinct = nothing)
    end
    mk(lv, g, y) = Frame(g = CF.DictColumn(UInt8[findfirst(==(v), lv) for v in g], CF.column(lv)), y = y)
    src = StatDictSource([mk(["a", "b", "zz"], ["a", "b", "a"], [1, 2, 3]), mk(["c", "a"], ["c", "a"], [10, 11])])
    for (red, sink) in ((summarise(n = n_rows()), true), (summarise(m = median(c.y)), false))
        p = filter(c.y .< 10) ⨟ group_by(:g; drop = false) ⨟ red
        e = p(CF.read_source(src))
        @test e.nrow == 2                                  # "a", "b": no "zz" level (decoded)
        for th in (true, false)
            r, st = rawrun(p(lazy(src)); morsel = 1, threads = th)
            @test st.pruned == 1                           # the partition is still pruned
            @test st.sink === (sink ? :hashagg : :none)
            @test same(e, r)
            @test same(e, collect(p(lazy(src)); threads = th))
        end
    end
end

@testitem "hash-aggregate sink: forced radix switch at 4 groups (First, Last, ReduceM(string *))" tags = [:unit] setup = [SK, Force] begin
    n = 300
    w = (
        g = [string("g", mod(i * 37, 41)) for i in 1:n],
        k = [mod(i, 3) for i in 1:n],
        s = [string(Char('a' + mod(i, 26))) for i in 1:n],
        y = [mod(i * 13, 17) - 8 for i in 1:n],
        x = [isodd(i) ? i / 7 : -i / 3 for i in 1:n],
    )
    ps = Any[
        group_by(:g) ⨟ summarise(f = first(c.s), l = last(c.s), r = reduce(*, c.s), n = n_rows()),
        group_by(:g, :k) ⨟ summarise(r = reduce(*, c.s), sy = sum(c.y), m = mean(c.x), v = var(c.x)),
        summarise(f = first(c.y), l = last(c.y); by = :k),
    ]
    withforce(CF._FORCE_RADIX_SWITCH => 4) do
        for p in ps
            @test agrees(p, w; morsels = (1, 3, 7, 64))
        end
    end
    # mixed modes: the first morsels hold many groups (those tasks switch), the later ones one
    mixed = (g = [i <= 40 ? string("m", i) : "z" for i in 1:400], s = [string(Char('a' + mod(i, 26))) for i in 1:400])
    withforce(CF._FORCE_RADIX_SWITCH => 4) do
        @test agrees(group_by(:g) ⨟ summarise(r = reduce(*, c.s), f = first(c.s), l = last(c.s)), mixed; morsels = (5, 50))
    end
end

@testitem "hash-aggregate sink: dictionary keys (global remap, drop = false levels)" tags = [:unit] setup = [SK] begin
    lv = CF.column(["b", "a", "zz", "c"])
    d = CF.DictColumn(UInt8[1, 2, 1, 4, 2, 1, 4, 2], lv)
    fr = Frame(g = d, y = t.y, x = t.x)
    for drop in (true, false)
        p = group_by(:g; drop) ⨟ summarise(n = n_rows(), s = sum(c.y), m = mean(c.x))
        @test agrees(p, fr)
        @test nrow(p(fr)) == (drop ? 3 : 4)
        # every row filtered away: the empty levels only (drop = false), as eager
        q = filter(c.y .> 100) ⨟ p
        @test agrees(q, fr; morsels = 1:3)
    end
    # an empty level under maximum raises as eager (CC-007)
    @test agrees(group_by(:g; drop = false) ⨟ summarise(m = maximum(c.y)), fr)
    # a nullable dictionary key and a two-column key with a dictionary
    dn = CF.DictColumn(UInt8[1, 2, 0, 4, 2, 0, 4, 2], lv, BitVector([1, 1, 0, 1, 1, 0, 1, 1]))
    fn = Frame(g = dn, k = t.k, y = t.y)
    for drop in (true, false)
        @test agrees(group_by(:g, :k; drop) ⨟ summarise(n = n_rows(), s = sum(c.y)), fn)
    end

    # partitions with different, permuted dictionaries (per-batch Arrow dictionaries, critic M6)
    struct PermDictSource <: CF.Source
        parts::Vector{Frame}
    end
    CF.source_schema(s::PermDictSource) = Tables.Schema((:g, :y), (eltype(s.parts[1].columns[1]), Int))
    CF.source_label(::PermDictSource) = "permuted-dictionary test source"
    CF.plan_partitions(s::PermDictSource, scan::Tables.Scan; morsel::Int = 1) = (collect(eachindex(s.parts)), scan)
    CF.read_partition(s::PermDictSource, p::Int) = s.parts[p]
    mk(dict, codes, y) = Frame(g = CF.DictColumn(UInt8.(codes), CF.column(dict)), y = y)
    src = PermDictSource(
        [
            mk(["a", "b", "c"], [1, 2, 3, 1], [1, 2, 3, 4]),
            mk(["c", "a", "b"], [1, 2, 3, 3], [5, 6, 7, 8]),
            mk(["b", "zz"], [2, 1, 2], [9, 10, 11]),
            mk(["a", "b", "c"], Int[], Int[]),
        ]
    )
    for drop in (true, false)
        p = group_by(:g; drop) ⨟ summarise(n = n_rows(), s = sum(c.y), f = first(c.y), l = last(c.y))
        @test agrees(p, src; morsels = 1:2)
        @test collect(p(lazy(src))).columns[1] == ["a", "b", "c", "zz"]
    end
    # regression (found by the grouped-sinks property): partitions with different dictionaries
    # are decoded by the eager read (`read_source` → `vcat_columns`), so a lone non-empty morsel
    # must not bring its own dictionary's levels to `drop = false`; nor may the empty gather.
    # Both the sink and the gathered path (a holistic summary) follow the eager read.
    for drop in (true, false), red in (summarise(n = n_rows()), summarise(m = median(c.y)))
        for pre in (filter(c.y .< 5), filter(c.y .> 100))
            p = pre ⨟ group_by(:g; drop) ⨟ red
            @test agrees(p, src; morsels = 1:2, sink = red.outs[1].first === :n)
        end
    end
end
