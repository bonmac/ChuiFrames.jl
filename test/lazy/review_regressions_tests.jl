# Regressions from review pass 1 of the phase-3 lane (2026-10-20): each item is the reviewer's
# reproducer, lazy against eager.

@testsnippet RR begin
    using Tables, Dates
    const ⨟ = ChuiFrames.Upstream.:⨟
    col(x, n) = collect(Tables.getcolumn(x, n))
    function outcome(f)
        try
            return (:ok, f())
        catch err
            return (:err, typeof(err))
        end
    end
    function agrees(p, t; morsels = (1, 2, 7, 65_536), source = lazy)
        e = outcome(() -> p(t isa ChuiFrames.Source ? ChuiFrames.read_source(t) : t))
        for m in morsels, th in (true, false)
            l = outcome(() -> collect(p(source(t)); morsel = m, threads = th))
            e[1] == l[1] || return false
            if e[1] === :err
                e[2] == l[2] || return false
            else
                (isequal(Tables.columntable(e[2]), Tables.columntable(l[2])) && groupcols(e[2]) == groupcols(l[2])) || return false
            end
        end
        return true
    end
end

@testitem "review B1: a projection to no columns keeps the row count" tags = [:unit] setup = [RR] begin
    t = Frame((a = collect(1:100_000),))
    @test col(collect(summarise(n = n_rows())(lazy(t))), :n) == [100_000]
    @test agrees(summarise(n = n_rows()), (a = collect(1:10),))
    @test agrees(mutate(k = n_rows()) ⨟ select(:k), (a = collect(1:5),))
end

@testitem "review B2: projection keeps a rename's new name when it collides" tags = [:unit] setup = [RR] begin
    f = Frame((a = [1, 2], b = [3, 4]))
    @test outcome(() -> (rename(:a => :b) ⨟ select(:a))(f)) == (:err, ArgumentError)
    @test agrees(rename(:a => :b) ⨟ select(:a), f)
end

@testitem "review B3: partitions of different types read with the declared types" tags = [:unit] setup = [RR] begin
    s = ChuiFrames.TablesSource(Tables.partitioner([(x = [4, 6],), (x = [1.5, 3.0],)]))
    for p in (head(1) ⨟ mutate(y = string.(c.x)), mutate(y = c.x .÷ 0), filter(c.x .> 5) ⨟ mutate(y = string.(c.x)))
        @test agrees(p, s; source = lazy)
    end
    @test col(collect((head(1) ⨟ mutate(y = string.(c.x)))(lazy(s))), :y) == ["4.0"]
    # review pass 2, N1: kinds conform_column cannot reach are read as before, on both paths
    for parts in ([(x = [1, 2],), (x = ["a"],)], [(x = [Dates.Date(2020)],), (x = [Dates.DateTime(2021)],)])
        u = ChuiFrames.TablesSource(Tables.partitioner(parts))
        @test ChuiFrames.read_source(u).nrow == sum(p -> length(p.x), parts)
        @test agrees(filter(.!ismissing.(c.x)), u)
    end
end

@testitem "review B4: dictionary columns keep their levels (drop = false)" tags = [:unit] setup = [RR] begin
    g = ChuiFrames.DictColumn(UInt8[1, 2, 1, 2], ChuiFrames.column(["a", "b", "c"]))
    t = Frame(g = g, n = [1, 2, 3, 4])
    p = group_by(:g; drop = false) ⨟ summarise(k = n_rows())
    @test col(p(t), :k) == [2, 2, 0]
    @test agrees(p, t)
    @test agrees(filter(c.n .> 10) ⨟ group_by(:g; drop = false) ⨟ summarise(k = n_rows()), t)
    @test Tables.getcolumn(collect(lazy(t); morsel = 2), :g) isa ChuiFrames.DictColumn
end

@testitem "review M1: planning errors are replayed eagerly" tags = [:unit] setup = [RR] begin
    struct UntypedSource <: ChuiFrames.Source end
    ChuiFrames.source_schema(::UntypedSource) = Tables.Schema((:x,), nothing)
    ChuiFrames.source_label(::UntypedSource) = "UntypedSource"
    ChuiFrames.plan_partitions(::UntypedSource, scan::Tables.Scan; morsel) = ([1], scan)
    ChuiFrames.read_partition(::UntypedSource, p) = (x = [1, 2, 3],)
    s = UntypedSource()
    @test agrees(filter(c.x .> 1), s; morsels = (1, 2))
end

@testitem "review M2: string predicates on a frame are total" tags = [:unit] setup = [RR] begin
    t = (g = ["a", "b", "a"], y = [1, 2, 3])
    q = (filter(c.g .== "a") ⨟ head(1))(lazy(t))
    @test ChuiFrames.physical(ChuiFrames.optimize(q).plan).stop_early
    @test agrees(filter(c.g .== "a") ⨟ head(1), t)
end
