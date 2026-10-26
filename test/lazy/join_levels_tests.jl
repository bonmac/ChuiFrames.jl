# A join's collected side and the dictionary levels a `group_by(...; drop = false)` above the
# join shows (CF-008; final review of phase 4, blocker B1). Eager `read_source` reads every
# partition, so partitions with different dictionaries decode `g` and `drop = false` adds no
# level. A collected side (x when x is the build side; y when y is the build side or both
# sides are partitioned) must not keep one partition's dictionary, with its unobserved level
# "zz", after a row limit or a statistics-pruned partition.

@testsnippet JoinLevels begin
    using Tables
    const ⨟ = ChuiFrames.Upstream.:⨟
    const CF = ChuiFrames
    const LFORCES = (:auto, :broadcast_x, :broadcast_y, :partitioned_x, :partitioned_y)
    struct JoinLevelsSource <: CF.Source
        parts::Vector{Frame}
    end
    CF.source_schema(s::JoinLevelsSource) = Tables.Schema((:g, :y), (eltype(s.parts[1].columns[1]), Int))
    CF.source_label(::JoinLevelsSource) = "dictionary source (join levels)"
    CF.plan_partitions(s::JoinLevelsSource, scan::Tables.Scan; morsel::Int = 1) = (collect(eachindex(s.parts)), scan)
    CF.read_partition(s::JoinLevelsSource, p::Int) = s.parts[p]
    CF.row_count(s::JoinLevelsSource) = (sum(p -> p.nrow, s.parts), true)
    function CF.partition_stats(s::JoinLevelsSource, p::Int, col::Symbol)
        col === :y || return nothing
        y = s.parts[p].columns[2]
        return (; lo = minimum(y), hi = maximum(y), nnull = 0, nnan = 0, ndistinct = nothing)
    end
    mk(lv, g, y) = Frame(g = CF.DictColumn(UInt8[findfirst(==(v), lv) for v in g], CF.column(lv)), y = y)
    src = JoinLevelsSource([mk(["a", "b", "zz"], ["a", "b", "a"], [1, 2, 3]), mk(["c", "a"], ["c", "a"], [10, 11])])
    # larger than the source: at :auto the dictionary side is the build side
    big = Frame(g = repeat(["a", "c", "b"], 100), w = collect(1:300))
    same(a, b) = a.names == b.names && isequal(Tables.columntable(a), Tables.columntable(b))
    quiet(f) = Base.CoreLogging.with_logger(f, Base.CoreLogging.NullLogger())
    "The engine with no replay: the package's own lowering, then the morsel executor."
    rawrun(q; morsel = 1, threads) =
        CF.execute(CF.physical(CF._lower_joins(CF.optimize(q).plan; morsel, threads)); morsel, threads)
end

@testitem "join: a collected side keeps no partition's unobserved levels (CF-008, B1)" tags = [:unit] setup = [Force, JoinLevels] begin
    # x side: a row limit, then a filter that prunes partition 2 by its statistics
    for pre in Any[head(2), filter(c.y .< 10)]
        p = pre ⨟ left_join(big; by = :g) ⨟ group_by(:g; drop = false) ⨟ summarise(n = n_rows())
        e = quiet(() -> p(CF.read_source(src)))
        @test !("zz" in e.columns[1])
        for v in LFORCES, th in (false, true), m in (1, 2)
            withforce(CF._FORCE_JOIN => v) do
                l = quiet(() -> collect(p(lazy(src)); morsel = m, threads = th))
                r = quiet(() -> rawrun(p(lazy(src)); morsel = m, threads = th))
                @test same(e, l)
                @test same(e, r)
            end
        end
    end
    # y side: a limited dictionary y
    for pre in Any[head(1), filter(c.y .< 10)]
        pl = right_join(lazy(src) |> pre; by = :g, keep = true) ⨟ group_by(:g_y; drop = false) ⨟ summarise(n = n_rows())
        pe = right_join(pre(CF.read_source(src)); by = :g, keep = true) ⨟ group_by(:g_y; drop = false) ⨟ summarise(n = n_rows())
        e = quiet(() -> pe(big))
        @test !("zz" in e.columns[1])
        for v in LFORCES, th in (false, true), m in (1, 2)
            withforce(CF._FORCE_JOIN => v) do
                l = quiet(() -> collect(pl(lazy(big)); morsel = m, threads = th))
                r = quiet(() -> rawrun(pl(lazy(big)); morsel = m, threads = th))
                @test same(e, l)
                @test same(e, r)
            end
        end
    end
end

@testitem "explain: the hash-aggregate sink above a join probe is decided at collect (final review minor)" tags = [:unit] begin
    const ⨟ = ChuiFrames.Upstream.:⨟
    x = (k = [1, 2, 3], v = [1, 2, 3])
    y = Frame(k = [1.0, 2.0], w = [5, 6])
    for pre in Any[mutate(:k => c.k .* 1), filter(c.v .> 0)]
        s = sprint(explain, (pre ⨟ inner_join(y; by = :k) ⨟ group_by(:k) ⨟ summarise(n = n_rows()))(lazy(x)))
        @test occursin("hash-aggregate sink for the summary: decided at collect", s)
        @test !occursin("no hash-aggregate sink: the stage's output schema is not known", s)
        @test occursin("then eagerly: group_by(:k) ⨟ summarise(n = n_rows())", s)
    end
    # a reason found from the steps alone still stands
    s = sprint(explain, (inner_join(y; by = :k) ⨟ group_by(:h => c.v .% 2) ⨟ summarise(n = n_rows()))(lazy(x)))
    @test occursin("no hash-aggregate sink: a computed group key", s)
    @test !occursin("decided at collect", s)
    # no summary above the join: no note
    @test !occursin("hash-aggregate", sprint(explain, inner_join(y; by = :k)(lazy(x))))
end

@testitem "join: no drop = false above, the collected side still stops early (CF-008, B1 cost)" tags = [:unit] setup = [Force, JoinLevels] begin
    # Without a step that shows levels, lazy and eager still agree on the rows (the column kind
    # may differ; nothing observes it).
    p = head(2) ⨟ left_join(big; by = :g) ⨟ group_by(:g) ⨟ summarise(n = n_rows())
    e = quiet(() -> p(CF.read_source(src)))
    for v in LFORCES, th in (false, true)
        withforce(CF._FORCE_JOIN => v) do
            @test same(e, quiet(() -> collect(p(lazy(src)); threads = th)))
        end
    end
    @test CF._plan_shows_levels(group_by(:g; drop = false)(lazy(src)).plan)
    @test !CF._plan_shows_levels(p(lazy(src)).plan)
end
