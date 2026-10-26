# A row limit (`head(n)`) that stops the scan early, before a step that shows dictionary levels
# (CF-008; follow-up to review MAJOR 1 of p4-groupby2). Eager `read_source` reads every
# partition, so partitions with different dictionaries decode `g` and `group_by(:g; drop = false)`
# adds no level; the lazy run must not keep the first partition's dictionary (with its
# unobserved level "zz") because it stopped reading before the second partition.

@testsnippet LimDict begin
    using Tables, Statistics
    const ⨟ = ChuiFrames.Upstream.:⨟
    const CF = ChuiFrames
    # names, grouping, drop flag, column kinds' element types and values
    function same(a, b)
        a.names == b.names && a.nrow == b.nrow && a.groups == b.groups && a.drop == b.drop || return false
        for (ca, cb) in zip(a.columns, b.columns)
            eltype(ca) == eltype(cb) || return false
            all(i -> isequal(ca[i], cb[i]), eachindex(ca)) || return false
        end
        return true
    end
    # the engine without collect's replay
    function rawrun(q; morsel = 1, threads)
        st = CF.ExecStats()
        r = CF.execute(CF.physical(CF.optimize(q).plan); morsel, threads, stats = st)
        return r, st
    end
    struct LimitDictSource <: CF.Source
        parts::Vector{Frame}
    end
    CF.source_schema(s::LimitDictSource) = Tables.Schema((:g, :y), (eltype(s.parts[1].columns[1]), Int))
    CF.source_label(::LimitDictSource) = "dictionary source with y statistics (row limit)"
    CF.plan_partitions(s::LimitDictSource, scan::Tables.Scan; morsel::Int = 1) = (collect(eachindex(s.parts)), scan)
    CF.read_partition(s::LimitDictSource, p::Int) = s.parts[p]
    function CF.partition_stats(s::LimitDictSource, p::Int, col::Symbol)
        col === :y || return nothing
        y = s.parts[p].columns[2]
        return (; lo = minimum(y), hi = maximum(y), nnull = 0, nnan = 0, ndistinct = nothing)
    end
    mk(lv, g, y) = Frame(g = CF.DictColumn(UInt8[findfirst(==(v), lv) for v in g], CF.column(lv)), y = y)
    src = LimitDictSource([mk(["a", "b", "zz"], ["a", "b", "a"], [1, 2, 3]), mk(["c", "a"], ["c", "a"], [10, 11])])
end

@testitem "row limit before drop = false: skipped partitions' dictionaries count (CF-008)" tags = [:unit] setup = [LimDict] begin
    tails = (summarise(n = n_rows()), summarise(m = median(c.y)))
    heads = Any[
        head(2),
        filter(c.y .< 10) ⨟ head(2),                       # partition 2 is also prunable
        mutate(z = c.y .* 2) ⨟ head(2),                    # a streamed stage before the limit
        head(4),                                            # the limit spans both partitions
        head(0),
    ]
    for h in heads, red in tails
        p = h ⨟ group_by(:g; drop = false) ⨟ red
        e = p(CF.read_source(src))
        @test !("zz" in e.columns[1])                      # decoded: no unobserved level
        for th in (false, true)
            r, _ = rawrun(p(lazy(src)); threads = th)
            @test same(e, r)
            @test same(e, collect(p(lazy(src)); threads = th))
        end
    end
    # the rows the limit returns are unchanged
    for h in heads
        p = h ⨟ group_by(:g; drop = false)
        e = p(CF.read_source(src))
        for th in (false, true)
            r, _ = rawrun(p(lazy(src)); threads = th)
            @test same(e, r)
        end
    end
end

@testitem "row limit without a levels step still stops the scan early" tags = [:unit] setup = [LimDict] begin
    for red in (summarise(n = n_rows()), summarise(m = median(c.y)))
        p = head(2) ⨟ group_by(:g) ⨟ red
        e = p(CF.read_source(src))
        for th in (false, true)
            r, st = rawrun(p(lazy(src)); threads = th)
            @test st.read == 1                              # partition 2 never read
            @test same(e, r)
        end
    end
    # with drop = false, partition 2 is read for its column kinds only (its empty slice)
    r, st = rawrun((head(2) ⨟ group_by(:g; drop = false) ⨟ summarise(n = n_rows()))(lazy(src)); threads = false)
    @test st.read == 2 && st.planned == 2
    @test r.nrow == 2
end

@testitem "kinds-only reads conform the real rows, then slice (review MINOR-1)" tags = [:unit] setup = [LimDict] begin
    # `conform_types` narrows by the values it sees: a `missing` under a declared non-nullable
    # type keeps the column as read (nullable). A kinds-only read must see the same column types
    # as eager `read_source`, so it conforms the whole partition before taking its empty slice.
    struct DeclSource <: CF.Source
        parts::Vector{Frame}
        sch::Tables.Schema
    end
    CF.source_schema(s::DeclSource) = s.sch
    CF.source_label(::DeclSource) = "declared-schema source"
    CF.plan_partitions(s::DeclSource, scan::Tables.Scan; morsel::Int = 1) = (collect(eachindex(s.parts)), scan)
    CF.read_partition(s::DeclSource, p::Int) = s.parts[p]
    function CF.partition_stats(s::DeclSource, p::Int, col::Symbol)
        col === :y || return nothing
        y = collect(skipmissing(s.parts[p].columns[2]))
        return (; lo = minimum(y), hi = maximum(y), nnull = count(ismissing, s.parts[p].columns[2]), nnan = 0, ndistinct = nothing)
    end
    eltypes(f) = Type[eltype(col) for col in f.columns]
    function check(p, s)
        e = p(CF.read_source(s))
        for th in (false, true)
            r, _ = rawrun(p(lazy(s)); threads = th)
            @test eltypes(r) == eltypes(e)
            @test same(e, r)
            @test eltypes(collect(p(lazy(s)); threads = th)) == eltypes(e)
        end
        return e
    end
    # pruned path: every partition pruned; partition 1 holds a missing under declared Int
    sch = Tables.Schema((:g, :y), (String, Int))
    pr = DeclSource([mk(["a", "zz"], ["a", "zz"], Union{Missing, Int}[missing, 50]), mk(["c"], ["c", "c"], [20, 30])], sch)
    e = check(filter(c.y .< 10) ⨟ group_by(:g; drop = false), pr)
    @test eltype(e.columns[2]) == Union{Missing, Int}
    # limit path: the unreached partition's dictionary column is nullable under declared String
    nd = CF.DictColumn(UInt8[1, 0, 2], CF.column(["c", "a"]), BitVector([1, 0, 1]))
    lm = DeclSource([mk(["a", "b", "zz"], ["a", "b", "a"], [1, 2, 3]), Frame(g = nd, y = [10, 11, 12])], sch)
    for tail in (group_by(:g; drop = false), group_by(:g; drop = false) ⨟ summarise(n = n_rows()))
        el = check(head(2) ⨟ tail, lm)
        @test Missing <: eltype(el.columns[1])             # eager keeps the missing
    end
end
