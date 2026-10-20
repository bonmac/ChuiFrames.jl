# Unit tests of the lazy engine (spec docs/superpowers/specs/2026-10-20-phase3-lazy-design.md):
# the R6 scheme stand-ins over plan nodes, the API, each optimizer rule (fires, does not fire),
# R-total, the executor (morsels, parallel order, limits, exceptions, replay, partition types).

@testsnippet LZ begin
    using Tables, Statistics
    using DataAPI: nrow
    const ⨟ = ChuiFrames.Upstream.:⨟
    const UP = ChuiFrames.Upstream
    col(x, n) = collect(Tables.getcolumn(x, n))
    eq(a, b) = isequal(Tables.columntable(a), Tables.columntable(b)) && isequal(groupcols(a), groupcols(b))
    t = (g = ["a", "b", "a", "c", "b", "a"], x = [1.0, NaN, -0.0, missing, 5.0, 0.0], y = [1, 2, 3, 4, 5, 6], s = ["p", "q", "r", "s", "t", "u"])
    fired(q) = ChuiFrames.optimize_plan(q.plan)[2].fired
    function outcome(f)
        try
            return (:ok, f())
        catch err
            return (:err, typeof(err))
        end
    end
    # lazy and eager agree (values and grouping), or raise the same exception type, for every morsel size
    function agrees(p, t; morsels = 1:7, threads = (true, false))
        e = outcome(() -> p(t))
        for m in morsels, th in threads
            l = outcome(() -> collect(p(lazy(t)); morsel = m, threads = th))
            e[1] == l[1] || return false
            e[1] === :err && (e[2] == l[2] || return false)
            e[1] === :ok && (eq(e[2], l[2]) || return false)
        end
        return true
    end
end

@testitem "lazy: R6 scheme stand-ins over plan nodes (cata, para, ana; identity law)" tags = [:unit] setup = [LZ] begin
    q = (filter(c.y .> 1) ⨟ select(:g, :y) ⨟ head(2))(lazy(t))
    depth(n) = n isa ChuiFrames.ScanNode ? 0 : n.child + 1           # cata: holes hold results
    @test UP.cata(depth, q.plan) == 3
    # identity law: cata with a rebuild algebra gives back an equal plan
    @test UP.cata(identity, q.plan) == q.plan
    # para sees the original children: count steps whose child is a step
    nested(n) = n isa ChuiFrames.ScanNode ? 0 : ((orig, r) = n.child; r + (orig isa ChuiFrames.StepNode))
    @test UP.para(nested, q.plan) == 2
    # ana with embed = identity unfolds a plan from a seed
    scan = ChuiFrames.ScanNode(ChuiFrames.FrameSource(Frame(t)))
    plan = UP.ana(k -> k == 0 ? scan : ChuiFrames.StepNode(head(k), k - 1), 3; embed = identity)
    @test UP.cata(depth, plan) == 3
    @test_throws ArgumentError UP.fmap(identity, :not_a_functor)
end

@testitem "lazy: API (lazy, verbs append, collect, Sources, show)" tags = [:unit] setup = [LZ] begin
    q = lazy(t)
    @test q isa LazyFrame && lazy(q) === q
    @test eq(collect(q), Frame(t))
    p = filter(c.y .> 1) ⨟ mutate(z = c.y .* 2)
    @test p(q) isa LazyFrame && (q |> p) isa LazyFrame
    @test eq(collect(p(q)), p(t))
    # a step on a Source starts a lazy query; collect(source) reads it (CF-016)
    src = ChuiFrames.TablesSource(Tables.partitioner([(y = [1, 2],), (y = [3],)]))
    @test filter(c.y .> 1)(src) isa LazyFrame
    @test col(collect(filter(c.y .> 1)(src)), :y) == [2, 3]
    @test col(collect(src), :y) == [1, 2, 3]
    # a grouped frame stays grouped (drop flag too)
    gd = group_by(:g; drop = false)(Frame(t))
    @test eq(collect(lazy(gd)), gd) && !collect(lazy(gd)).drop
    @test eq(collect(summarise(n = n_rows())(lazy(gd))), summarise(n = n_rows())(gd))
    @test occursin("filter", sprint(show, p(q))) && occursin("LazyFrame", sprint(show, MIME("text/plain"), p(q)))
    @test_throws ArgumentError collect(q; morsel = 0)
end

@testitem "lazy: optimizer rules fire on total filters" tags = [:unit] setup = [LZ] begin
    # predicate pushdown below select/rename into the scan, projection, limit
    q = (rename(yy = :y) ⨟ select(:g, :yy) ⨟ filter(c.yy .> 2) ⨟ head(2))(lazy(t))
    fs = fired(q)
    @test any(startswith("predicate pushdown: filter((c.yy .> 2)) below select"), fs)
    @test any(startswith("predicate pushdown: filter((c.yy .> 2)) below rename"), fs)
    @test any(startswith("predicate pushdown: filter((c.y .> 2)) into the scan"), fs)
    @test any(startswith("projection pushdown: the scan reads 2 of 4 columns (g, y)"), fs)   # through the rename
    @test agrees(rename(yy = :y) ⨟ select(:g, :yy) ⨟ filter(c.yy .> 2) ⨟ head(2), t)
    # splitting a conjunction of total predicates, each pushed
    q = filter((c.y .> 1) .& (c.y .< 6), c.x .> 0)(lazy(t))
    fs = fired(q)
    @test any(startswith("filter splitting"), fs)
    @test count(startswith("predicate pushdown"), fs) == 3
    @test agrees(filter((c.y .> 1) .& (c.y .< 6), c.x .> 0), t)
    # projection pushdown below a closing select / summarise
    q = (filter(c.y .> 1) ⨟ select(:g, :y))(lazy(t))
    @test any(startswith("projection pushdown: the scan reads 2 of 4 columns (g, y)"), fired(q))
    q = (group_by(:g) ⨟ summarise(m = mean(c.y)))(lazy(t))
    @test any(startswith("projection pushdown: the scan reads 2 of 4 columns"), fired(q))
    @test agrees(group_by(:g) ⨟ summarise(m = mean(c.y)), t)
    # limit pushdown with every predicate translated and handed to the source (a FrameSource is
    # handed no filter, so there only a bare head is pushed)
    src = ChuiFrames.TablesSource(Tables.partitioner([(y = [1, 2, 3],), (y = [4, 5],)]))
    q = (filter(c.y .> 1) ⨟ head(2))(lazy(src))
    @test any(startswith("limit pushdown"), fired(q))
    @test col(collect(q; morsel = 1), :y) == [2, 3]
    @test !any(startswith("limit pushdown"), fired((filter(c.y .> 1) ⨟ head(2))(lazy(t))))
    @test any(startswith("limit pushdown"), fired(head(2)(lazy(t))))
    @test col(collect((filter(c.y .> 1) ⨟ head(2))(lazy(t)); morsel = 1), :y) == [2, 3]
    # projection through a rename above a non-pushed step (found by the p3-prop properties:
    # the rename branch built a Set{Any})
    for p in (filter_out(c.y .> 2) ⨟ rename(yy = :y) ⨟ select(:yy), mutate(z = c.y .* 2) ⨟ rename(yy = :y) ⨟ select(:yy))
        @test any(startswith("projection pushdown: the scan reads 1 of 4 columns (y)"), fired(p(lazy(t))))
        @test agrees(p, t)
    end
    # constant folding of literal-only calls with an exact declared type
    q = filter(c.y .> (lit(1) .+ 1))(lazy(t))
    @test any(startswith("constant folding"), fired(q))
    @test agrees(filter(c.y .> (lit(1) .+ 1)), t)
end

@testitem "lazy: barriers (R-total): non-total steps stop every rule below them" tags = [:unit] setup = [LZ] begin
    # a filter above a mutate stays above it (the mutate might throw on the rows it would drop)
    q = (mutate(z = c.y .* 2) ⨟ filter(c.y .> 2))(lazy(t))
    @test !any(startswith("predicate pushdown"), fired(q))
    # a non-total predicate (abstract-typed, ADR-0003 rule 4 barrier) is never split or pushed
    q = filter((c.y .> 1) .& (c.s .|> v -> v .!= "q"))(lazy(t))
    @test isempty(fired(q))
    # a total filter does not move below a non-total one
    q = (filter(c.y .|> v -> v .> 1) ⨟ filter(c.y .> 2))(lazy(t))
    @test !any(startswith("predicate pushdown"), fired(q))
    # regression 8: never below a select that drops the filter's column (eager raises)
    q = (select(:g) ⨟ filter(c.y .> 1))(lazy(t))
    @test !any(startswith("predicate pushdown"), fired(q))
    @test agrees(select(:g) ⨟ filter(c.y .> 1), t)
    # the scan does not stop early below a non-total step: eager raises on row 6, so lazy must
    bad = (y = [1, 2, 3, 4, 5, 6], s = ["1", "2", "3", "4", "5", "x"])
    p = mutate(v = parse.(Int, c.s)) ⨟ head(2)
    @test outcome(() -> p(bad)) == (:err, ArgumentError)
    @test agrees(p, bad)
    @test !ChuiFrames.physical(ChuiFrames.optimize(p(lazy(bad))).plan).stop_early
    @test ChuiFrames.physical(ChuiFrames.optimize((filter(c.y .> 1) ⨟ head(2))(lazy(bad))).plan).stop_early
    # a grouped filter is not pushed; filter_out is not pushed
    @test !any(startswith("predicate pushdown"), fired((group_by(:g) ⨟ filter(c.y .> 1))(lazy(t))))
    @test !any(startswith("predicate pushdown: filter_out"), fired(filter_out(c.y .> 1)(lazy(t))))
    @test agrees(filter_out(c.y .> 1) ⨟ filter(c.y .< 5), t)
end

@testitem "lazy: regression halves (prototype regressions 2, 7, 8)" tags = [:unit] setup = [LZ] begin
    # 2: Take is stateful; a limit never runs per partition (sequential foldxl)
    ph = ChuiFrames.physical(ChuiFrames.optimize((filter(c.y .> 1) ⨟ head(3))(lazy(t))).plan)
    @test ph.limit == 3
    @test col(collect((filter(c.y .> 1) ⨟ head(3))(lazy(t)); morsel = 1), :y) == [2, 3, 4]
    # 7: NaN never hides matching rows (lazy, with pruning statistics from the FrameSource)
    f = (x = [1.0, NaN, 2.0, NaN, 3.0],)
    for p in (filter(.!(c.x .<= 2.0)), filter(c.x .!= 1.0), filter(isnan.(c.x)))
        @test agrees(p, f)
    end
    # 8: a filter never runs ahead of a select that drops its column
    @test outcome(() -> collect((select(:g) ⨟ filter(c.y .> 1))(lazy(t)))) == (:err, ArgumentError)
end

@testitem "lazy: executor (parallel order, exceptions, replay, partition types)" tags = [:unit] setup = [LZ] begin
    big = (k = collect(1:1000), v = [isodd(i) ? Float64(i) : NaN for i in 1:1000])
    p = filter(c.k .% 3 .!= 0) ⨟ mutate(w = c.v .* 2) ⨟ select(:k, :w)
    st = ChuiFrames.ExecStats()
    ph = ChuiFrames.physical(ChuiFrames.optimize(p(lazy(big))).plan)
    r = ChuiFrames.execute(ph; morsel = 7, threads = true, stats = st)
    @test eq(r, p(big))
    @test st.planned == 143 && st.read == 143
    @test st.parallel == (Threads.nthreads() > 1)
    # the first failing morsel in morsel order is reported; replay gives the eager exception type
    bad = (s = [string(i) for i in 1:100],)
    bad.s[90] = "x"           # ArgumentError at row 90
    @test agrees(mutate(v = parse.(Int, c.s)), bad; morsels = (1, 3, 7))
    two = (a = [1, 2, 3, 4], s = ["1", "2", "3", "x"])
    # morsel 1 fails in step 2 (DomainError), morsel 4 in step 1 (ArgumentError): eager raises
    # step 1's ArgumentError first; the replay makes lazy raise it too
    p2 = mutate(v = parse.(Int, c.s)) ⨟ mutate(w = sqrt.(c.a .- 2))
    @test outcome(() -> p2(two)) == (:err, ArgumentError)
    @test agrees(p2, two; morsels = (1, 2))
    # _parallel_map reports the first failure in index order, even from a later task
    if Threads.nthreads() > 1
        err = try
            ChuiFrames._parallel_map(i -> i in (3, 9) ? error("bad $i") : Frame(x = [i]), 10, 4)
            nothing
        catch e
            e
        end
        @test err isa ChuiFrames.MorselError && err.index == 3
    end
    # partitions whose column types differ are read with the declared types on both paths
    src = ChuiFrames.TablesSource(Tables.partitioner([(x = [1, 2],), (x = Union{Missing, Int}[3, missing],)]))
    ph = ChuiFrames.physical(ChuiFrames.optimize(mutate(y = c.x .+ 1)(lazy(src))).plan)
    r = ChuiFrames.execute(ph; morsel = 2)
    @test isequal(col(r, :y), [2, 3, 4, missing])
    @test eq(r, mutate(y = c.x .+ 1)(ChuiFrames.read_source(src)))
    # an empty source, and every partition filtered away
    @test eq(collect(filter(c.y .> 100)(lazy(t)); morsel = 2), filter(c.y .> 100)(t))
    e = (g = String[], y = Int[])
    @test agrees(filter(c.y .> 1) ⨟ mutate(z = c.y .* 2), e)
end

@testitem "lazy: explain and code_lowered (sections)" tags = [:unit] setup = [LZ] begin
    q = (filter(c.y .> 1) ⨟ select(:g, :y) ⨟ mutate(z = c.y .* 2) ⨟ group_by(:g) ⨟ summarise(n = n_rows()))(lazy(t))
    s = sprint(explain, q)
    for h in ("== logical plan ==", "== optimized plan ==", "== rules fired ==", "== physical plan ==", "== pruning ==", "== rendered kernel ==")
        @test occursin(h, s)
    end
    @test occursin("then eagerly: group_by(:g)", s)
    l = sprint(code_lowered, q)
    @test occursin("CodeInfo(", l) && occursin("_alltrue", l)
    @test occursin("no streamed stage", sprint(code_lowered, (group_by(:g) ⨟ summarise(n = n_rows()))(lazy(t))))
    @test occursin("rules fired ==\n  none", sprint(explain, lazy(t)))
end

@testitem "lazy: the rendered kernel equals the interpreter" tags = [:unit] setup = [LZ] begin
    stages = [
        filter(c.y .> 1) ⨟ mutate(z = c.y .* 2),
        filter_out(c.x .> 0) ⨟ select(:s, :x, w = c.y .+ 1),
        rename(yy = :y) ⨟ relocate(:s) ⨟ mutate(k = 1, g = nothing),
        mutate(c2 = case_when(c.y .> 3 => "big"; default = "small")),
    ]
    for p in stages
        ph = ChuiFrames.physical(ChuiFrames.optimize(p(lazy(t))).plan)
        ex = ChuiFrames.render_kernel(ph)
        @test ex !== nothing
        k = Core.eval(@__MODULE__, ex)
        part = Tables.columntable(Frame(t))
        got = Base.invokelatest(k, part)
        want = Tables.columntable(p(t))
        @test keys(got) == keys(want)
        @test all(n -> isequal(collect(getfield(got, n)), collect(getfield(want, n))), keys(want))
    end
end
