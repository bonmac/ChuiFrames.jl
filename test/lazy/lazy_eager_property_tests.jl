# Property tests of the lazy engine against the eager one (spec
# docs/superpowers/specs/2026-10-20-phase3-lazy-design.md §1, §5, §6, §8; CF-008, CF-013;
# ADR-0003 rules 4, 6, 7; ADR-0004 rule 4): random tables with NaN, -NaN, ±0.0, Inf and
# `missing`, random pipelines over the streamed stage and the rest, random morsel sizes and
# threading. Supposition runs with `record=false db=false` and an explicit `@test` on the result;
# every item has a wall-clock bound and fails loudly. They must pass under `julia -t 1` and `-t 4`.
#
# Comparison (CF-008): same outcome kind; on error the same exception type; on success the same
# names, order, row count, grouping (and drop flag), and values `isequal`. When the pipeline has a
# reduction (summarise, or a windowed mutate/filter), floats may instead agree within
# `rtol = 1e-12` (CF-008's tolerance for floats from reductions); this tolerance is applied to
# every float column of such a pipeline, not only to the reduced ones.

@testsnippet LazyProp begin
    using Supposition, Supposition.Data
    using Tables, Statistics
    using DataAPI: nrow
    const ⨟ = ChuiFrames.Upstream.:⨟
    const NMAX = 12
    const XV = Union{Missing, Float64}[NaN, -NaN, 0.0, -0.0, 1.5, -2.0, 3.25, Inf, missing]
    const SV = ["1", "2", "-3", "0", "7", "x"]
    # tables: a string group key, a nullable float column, an Int column, a string column that
    # `parse.(Int, c.s)` fails on when it holds "x"
    tablegen = @composed function ltable(
            n = Data.Integers(0, NMAX),
            g = Data.Vectors(Data.SampledFrom(["a", "b", "c"]); min_size = NMAX, max_size = NMAX),
            x = Data.Vectors(Data.SampledFrom(XV); min_size = NMAX, max_size = NMAX),
            y = Data.Vectors(Data.Integers(-3, 3); min_size = NMAX, max_size = NMAX),
            s = Data.Vectors(Data.SampledFrom(SV); min_size = NMAX, max_size = NMAX),
        )
        (g = g[1:n], x = Union{Missing, Float64}[x[1:n]...], y = y[1:n], s = s[1:n])
    end
    # Steps the streamed stage can run (ungrouped per-row verbs), total or not.
    const STREAMED = Any[
        filter(c.y .> 0), filter(c.y .> -2), filter(c.x .<= 1.0), filter(.!(c.x .<= 2.0)),
        filter(c.x .!= 1.5), filter(c.x .== 0.0), filter(isnan.(c.x)), filter(.!(isnan.(c.x))),
        filter(ismissing.(c.x)), filter(.!(ismissing.(c.x))), filter((c.y .> 0) .& (c.x .>= -2.0)),
        filter((c.x .> 0.0) .| (c.y .< 0)), filter(c.y .>= 0, c.x .< 3.0),
        filter_out(c.y .> 0), filter_out(c.x .> 0.0),
        select(:g, :x, :y), select(:x, :g), select(:g, xx = c.x), select(:y, :s, w = c.y .+ 1), select(:g, :y),
        rename(yy = :y), rename(xx = :x), rename(x = :y), relocate(:s), relocate(:x, :y),
        mutate(z = c.y .* 2), mutate(x = c.x .+ 1), mutate(y = c.y .- 1), mutate(p = parse.(Int, c.s)),
        mutate(r = sqrt.(c.y)), mutate(xc = case_when(c.x .> 0.0 => "pos"; default = "other")), mutate(s = nothing),
    ]
    # Steps that run on the materialized frame (non-elementwise, grouping, reductions, order).
    const REST = Any[
        filter(c.y .> mean(c.y)), filter(c.s .|> v -> v .!= "x"),
        mutate(w = c.y .- mean(c.y)), mutate(xm = c.x .- mean(c.x)),
        group_by(:g), group_by(:g, :y), group_by(:g; drop = false), ungroup(),
        summarise(n = n_rows()), mutate(k = n_rows()), select(:k),
        summarise(n = n_rows(), sy = sum(c.y), mx = mean(c.x)), summarise(mx = maximum(c.y), v = var(c.y)),
        summarise(sx = sum(skipmissing(c.x))),
        arrange(c.x), arrange(desc(c.y), c.g),
        head(0), head(1), head(2), head(3), head(4),
        distinct(), distinct(:g), distinct(:g, :y),
    ]
    const VOCAB = Any[STREAMED; REST]
    stepsgen = Data.Vectors(Data.SampledFrom(VOCAB); max_size = 5)
    morselgen = Data.Integers(1, 7)
    threadgen = Data.Booleans()

    pipe(steps) = isempty(steps) ? nothing : foldl(⨟, steps)
    run_eager(p, t) = p === nothing ? Frame(t) : p(t)
    run_lazy(p, t; kw...) = collect(p === nothing ? lazy(t) : p(lazy(t)); kw...)
    pipestr(steps) = isempty(steps) ? "(no steps)" : sprint(show, pipe(steps))

    # A step whose floats come from a reduction (CF-008's tolerance applies).
    _reduces(x) = x isa ChuiFrames.Reduce || x isa ChuiFrames.Window ||
        (x isa ChuiFrames.Call && any(_reduces, x.args)) || (x isa ChuiFrames.Pipe && _reduces(x.arg))
    reduces(s) = s isa ChuiFrames.SummariseStep ||
        (s isa ChuiFrames.MutateStep && any(o -> o isa Pair && _reduces(o.second), s.outs)) ||
        (s isa ChuiFrames.FilterStep && any(_reduces, s.preds))

    function outcome(f)
        try
            return (:ok, f())
        catch err
            return (:err, typeof(err))
        end
    end
    valeq(a, b, approx::Bool) = isequal(a, b) ||
        (approx && a isa AbstractFloat && b isa AbstractFloat && isapprox(a, b; rtol = 1.0e-12))
    function frames_agree(a, b; approx::Bool = false)
        names = collect(Symbol, Tables.columnnames(a))
        names == collect(Symbol, Tables.columnnames(b)) || return false
        nrow(a) == nrow(b) || return false
        isequal(groupcols(a), groupcols(b)) || return false
        isgrouped(a) && (a.drop == b.drop || return false)
        for n in names
            va = collect(Tables.getcolumn(a, n))
            vb = collect(Tables.getcolumn(b, n))
            length(va) == length(vb) || return false
            all(i -> valeq(va[i], vb[i], approx), eachindex(va)) || return false
        end
        return true
    end
    function outcomes_agree(e, l; approx::Bool = false)
        e[1] === l[1] || return false
        e[1] === :err && return e[2] === l[2]
        return frames_agree(e[2], l[2]; approx)
    end
    # Make a failing example readable in Supposition's report (events of the shrunk example).
    function explain_failure(steps, e, l)
        event!("pipeline", pipestr(steps))
        event!("eager", e[1] === :err ? e : (:ok, Tables.columntable(e[2])))
        event!("lazy", l[1] === :err ? l : (:ok, Tables.columntable(l[2])))
        return false
    end
    lazyq(p, t) = p === nothing ? lazy(t) : p(lazy(t))
    # A time budget checked inside every property call: past it, each call throws, so a slow or
    # hanging run fails loudly in-process (an outer alarm does not reach Pkg.test's child).
    const DEADLINE = Ref(Inf)
    deadline!(secs) = (DEADLINE[] = time() + secs; nothing)
    checktime() = time() > DEADLINE[] && error("property time budget exceeded")
    # Partitions pruned by one run of `q` (0 when the run throws).
    function npruned(q; morsel, threads)
        st = ChuiFrames.ExecStats()
        try
            ChuiFrames.execute(ChuiFrames.physical(ChuiFrames.optimize(q).plan); morsel, threads, stats = st)
        catch
            return 0
        end
        return st.pruned
    end

    # Print the shrunk counterexample (with its events) when a check fails.
    show_failure(sr) = Supposition.results(sr).ispass ||
        @info "counterexample" report = sprint(show, MIME("text/plain"), sr)
end

@testitem "lazy property: lazy == eager on random pipelines (CF-008)" tags = [:property] setup = [LazyProp] begin
    nerr = Ref(0)
    nok = Ref(0)
    # input kinds: 0 the table; 1 grouped by g; 2 g as a dictionary column (one unused level);
    # 3 that, grouped with drop = false (review pass 1, M3)
    function input_of(t, kind)
        kind == 0 && return t
        kind == 1 && return group_by(:g)(Frame(t))
        lv = ["a", "b", "c", "zz"]
        g = ChuiFrames.DictColumn(UInt8[findfirst(==(v), lv) for v in t.g], ChuiFrames.column(lv))
        f = Frame(g = g, x = t.x, y = t.y, s = t.s)
        return kind == 2 ? f : group_by(:g; drop = false)(f)
    end
    function lazy_eq(t, kind, steps, m, th)
        checktime()
        input = input_of(t, kind)
        p = pipe(steps)
        e = outcome(() -> run_eager(p, input))
        l = outcome(() -> run_lazy(p, input; morsel = m, threads = th))
        e[1] === :err ? (nerr[] += 1) : (nok[] += 1)
        outcomes_agree(e, l; approx = any(reduces, steps)) && return true
        return explain_failure(steps, e, l)
    end
    deadline!(300)
    t0 = time()
    sr = @check record = false db = false max_examples = 3000 lazy_eq(tablegen, Data.Integers(0, 3), stepsgen, morselgen, threadgen)
    elapsed = time() - t0
    show_failure(sr)
    @test Supposition.results(sr).ispass
    @info "lazy == eager" examples_ok = nok[] examples_err = nerr[] seconds = round(elapsed; digits = 1) nthreads = Threads.nthreads()
    @test nok[] > 0 && nerr[] > 0           # both outcomes are exercised
    @test elapsed < 600
end

@testitem "lazy property: the optimizer never hits the fixpoint cap and is idempotent" tags = [:property] setup = [LazyProp] begin
    function healthy(t, grouped, steps)
        checktime()
        input = grouped ? group_by(:g)(Frame(t)) : t
        p = pipe(steps)
        q = lazyq(p, input)
        plan, log = ChuiFrames.optimize_plan(q.plan)
        isempty(log.capped) || (event!("capped", log.capped); return false)
        plan2, log2 = ChuiFrames.optimize_plan(plan)
        # idempotence: a second run fires no rule and gives back an equal plan
        (isempty(log2.fired) && plan2 == plan) || (event!("pipeline", pipestr(steps)); event!("refired", log2.fired); return false)
        return true
    end
    deadline!(300)
    t0 = time()
    sr = @check record = false db = false max_examples = 2000 healthy(tablegen, Data.Booleans(), stepsgen)
    elapsed = time() - t0
    show_failure(sr)
    @test Supposition.results(sr).ispass
    @test elapsed < 600
end

@testitem "lazy property: pruning is sound through the engine (FrameSource and a NaN-free-statistics Source)" tags = [:property] setup = [LazyProp] begin
    # total filters on the float column: the optimizer pushes them into the scan and partitions
    # are pruned per morsel from FrameSource's exact statistics
    const TOTALX = Any[
        filter(c.x .> 0.0), filter(c.x .<= 1.5), filter(c.x .>= -2.0), filter(c.x .== 0.0), filter(c.x .== -0.0),
        filter(c.x .!= 1.5), filter(c.x .!= 0.0), filter(.!(c.x .<= 1.5)), filter(.!(c.x .> 0.0)),
        filter(.!(c.x .== 3.25)), filter(isnan.(c.x)), filter(.!(isnan.(c.x))), filter(ismissing.(c.x)),
        filter(.!(ismissing.(c.x))), filter((c.x .> 1.0) .| isnan.(c.x)), filter((c.x .> -1.0) .& (c.x .< 2.0)),
        filter(c.x .< Inf), filter(c.x .> -Inf), filter(.!(c.x .< Inf)),
    ]
    prefix = Data.Vectors(Data.SampledFrom(TOTALX); min_size = 1, max_size = 3)
    tail = Data.Vectors(Data.SampledFrom(VOCAB); max_size = 3)
    pruned = Ref(0)
    function sound(t, pre, rest, m, th)
        checktime()
        steps = Any[pre; rest]
        p = pipe(steps)
        e = outcome(() -> run_eager(p, t))
        l = outcome(() -> run_lazy(p, t; morsel = m, threads = th))
        pruned[] += npruned(lazyq(p, t); morsel = m, threads = th)
        outcomes_agree(e, l; approx = any(reduces, steps)) && return true
        return explain_failure(steps, e, l)
    end
    deadline!(300)
    t0 = time()
    sr = @check record = false db = false max_examples = 2000 sound(tablegen, prefix, tail, Data.Integers(1, 4), threadgen)
    show_failure(sr)
    @test Supposition.results(sr).ispass
    @test pruned[] > 0                      # pruning really ran on some examples

    # A Source whose statistics leave NaN out of lo/hi and do not count NaN (`nnan = nothing`),
    # as pyarrow's do (ADR-0004 rule 4, CF-013). Not thread-safe (the default): reads take the lock.
    struct NaNBlindSource <: ChuiFrames.Source
        parts::Vector{Vector{Union{Missing, Float64}}}
    end
    ChuiFrames.source_schema(::NaNBlindSource) = Tables.Schema((:x, :i), (Union{Missing, Float64}, Int))
    ChuiFrames.source_label(::NaNBlindSource) = "NaN-blind test source"
    ChuiFrames.plan_partitions(s::NaNBlindSource, scan::Tables.Scan; morsel::Int = 1) = (collect(eachindex(s.parts)), scan)
    function ChuiFrames.read_partition(s::NaNBlindSource, p::Int)
        start = sum(length, s.parts[1:(p - 1)]; init = 0)
        return (x = s.parts[p], i = collect(start .+ (1:length(s.parts[p]))))
    end
    function ChuiFrames.partition_stats(s::NaNBlindSource, p::Int, col::Symbol)
        col === :x || return nothing
        v = s.parts[p]
        vals = Float64[z for z in v if !ismissing(z) && !isnan(z)]
        lo, hi = isempty(vals) ? (nothing, nothing) : (minimum(vals), maximum(vals))
        return (; lo, hi, nnull = count(ismissing, v), nnan = nothing, ndistinct = nothing)
    end
    const BLIND = Any[
        c.x .!= 1.5, c.x .!= 0.0, .!(c.x .<= 1.5), .!(c.x .> 0.0), .!(c.x .== 3.25), .!(c.x .< Inf),
        isnan.(c.x), .!(isnan.(c.x)), .!(ismissing.(c.x)), ismissing.(c.x), (c.x .> 1.0) .| isnan.(c.x),
        c.x .> 0.0, c.x .<= -2.0, c.x .== 3.25, .!((c.x .> -1.0) .& (c.x .< 2.0)),
    ]
    partsgen = Data.Vectors(Data.Vectors(Data.SampledFrom(XV); max_size = 4); max_size = 5)
    blind_pruned = Ref(0)
    function blind(parts, preds, out, m, th)
        checktime()
        src = NaNBlindSource(Vector{Union{Missing, Float64}}[Union{Missing, Float64}[v...] for v in parts])
        s = out ? filter_out(preds...) : filter(preds...)
        e = outcome(() -> s(ChuiFrames.read_source(src)))
        l = outcome(() -> collect(s(lazy(src)); morsel = m, threads = th))
        blind_pruned[] += npruned(s(lazy(src)); morsel = m, threads = th)
        outcomes_agree(e, l) && return true
        return explain_failure(Any[s], e, l)
    end
    predsgen = Data.Vectors(Data.SampledFrom(BLIND); min_size = 1, max_size = 2)
    sr = @check record = false db = false max_examples = 2000 blind(partsgen, predsgen, Data.Booleans(), Data.Integers(1, 4), threadgen)
    elapsed = time() - t0
    show_failure(sr)
    @test Supposition.results(sr).ispass
    @test blind_pruned[] > 0                # the NaN-free range tests did prune some partitions
    @test elapsed < 600
end

@testitem "lazy property: the rendered kernel equals the interpreter on streamed stages" tags = [:property] setup = [LazyProp] begin
    const STREAMABLE = Any[s for s in STREAMED if ChuiFrames.isstreamable(s)]
    @test length(STREAMABLE) == length(STREAMED)
    function kernel_eq(t, steps)
        checktime()
        p = pipe(steps)
        e = outcome(() -> run_eager(p, t))
        ph = ChuiFrames.physical(ChuiFrames.optimize(p(lazy(t))).plan)
        isempty(ph.rest) && ph.limit === nothing || (event!("not streamed", pipestr(steps)); return false)
        ex = ChuiFrames.render_kernel(ph)
        if ex === nothing                   # only when a step cannot resolve on the schema
            e[1] === :err && return true
            event!("no kernel", pipestr(steps))
            return false
        end
        k = Core.eval(@__MODULE__, ex)
        f = Frame(t)
        ph.scan.select === nothing || (f = ChuiFrames.apply_scan(f, Tables.Scan(; select = ph.scan.select)))
        got = outcome(() -> Base.invokelatest(k, Tables.columntable(f)))
        if e[1] === :err || got[1] === :err
            e[1] === got[1] && return true
            event!("pipeline", pipestr(steps)); event!("eager", e); event!("kernel", got)
            return false
        end
        want = Tables.columntable(e[2])
        cols = got[2]
        ok = keys(cols) == keys(want) &&
            all(n -> isequal(collect(getfield(cols, n)), collect(getfield(want, n))), keys(want))
        ok || (event!("pipeline", pipestr(steps)); event!("eager", want); event!("kernel", cols))
        return ok
    end
    deadline!(300)
    t0 = time()
    sg = Data.Vectors(Data.SampledFrom(STREAMABLE); min_size = 1, max_size = 4)
    sr = @check record = false db = false max_examples = 400 kernel_eq(tablegen, sg)
    elapsed = time() - t0
    show_failure(sr)
    @test Supposition.results(sr).ispass
    @test elapsed < 600
end

@testitem "lazy: parallel morsels on large tables (results, ExecStats, exception order)" tags = [:property, :unit] setup = [LazyProp] begin
    deadline!(300)
    t0 = time()
    n = 2_000
    big = (
        g = [("a", "b", "c")[mod1(i, 3)] for i in 1:n],
        x = Union{Missing, Float64}[XV[mod1(i * 7, length(XV))] for i in 1:n],
        y = [mod(i, 7) - 3 for i in 1:n],
        s = [string(mod(i, 11)) for i in 1:n],
    )
    pipes = [
        filter(c.y .> -2) ⨟ mutate(z = c.y .* 2) ⨟ select(:g, :x, :z),
        filter(.!(c.x .<= 1.0)) ⨟ mutate(p = parse.(Int, c.s)) ⨟ rename(xx = :x),
        filter_out(isnan.(c.x)) ⨟ mutate(xc = case_when(c.x .> 0.0 => "pos"; default = "other")),
        filter((c.y .> 0) .| ismissing.(c.x)) ⨟ group_by(:g) ⨟ summarise(n = n_rows(), m = mean(c.y)),
        mutate(w = c.y .- mean(c.y)) ⨟ filter(c.w .> 0) ⨟ arrange(desc(c.w), c.s),
    ]
    for p in pipes
        e = p(big)
        ph = ChuiFrames.physical(ChuiFrames.optimize(p(lazy(big))).plan)
        st = ChuiFrames.ExecStats()
        r = ChuiFrames.execute(ph; morsel = 7, threads = true, stats = st)
        @test frames_agree(e, r; approx = true)
        @test frames_agree(e, collect(p(lazy(big)); morsel = 7, threads = true); approx = true)
        @test st.planned == cld(n, 7)
        # no limit: the morsels run in parallel exactly when there are threads
        @test ph.limit === nothing && st.parallel == (Threads.nthreads() > 1)
    end

    # Exception order: three morsels fail in three steps with three exception types. Morsel 1
    # fails in step 3 (InexactError), a middle morsel in step 2 (DomainError), a late morsel in
    # step 1 (ArgumentError). Eager raises step 1's ArgumentError; the executor reports the first
    # failing morsel in morsel order (InexactError), and collect's replay raises ArgumentError.
    a = fill(4.0, n)
    f = fill(2.0, n)
    s = fill("1", n)
    f[3] = 1.5                              # morsel 1, step 3
    a[1000] = -1.0                          # morsel 143, step 2
    s[1900] = "x"                           # morsel 272, step 1
    bad = (a = a, f = f, s = s)
    p3 = mutate(v = parse.(Int, c.s)) ⨟ mutate(w = sqrt.(c.a)) ⨟ mutate(k = Int.(c.f))
    @test outcome(() -> p3(bad)) == (:err, ArgumentError)
    unwrap(err) = err isa ChuiFrames.MorselError ? err.err : ChuiFrames._taskerror(err)
    for th in (true, false), m in (7, 64)
        ph = ChuiFrames.physical(ChuiFrames.optimize(p3(lazy(bad))).plan)
        raw = try
            ChuiFrames.execute(ph; morsel = m, threads = th)
            nothing
        catch err
            unwrap(err)
        end
        @test raw isa InexactError          # the first failing morsel, in morsel order
        @test outcome(() -> collect(p3(lazy(bad)); morsel = m, threads = th)) == (:err, ArgumentError)
    end
    # the reverse order: eager raises step 1's DomainError, morsel 1 fails in step 2
    s2 = fill("1", n)
    s2[2] = "x"
    a2 = fill(4.0, n)
    a2[1950] = -1.0
    bad2 = (a = a2, s = s2)
    p2 = mutate(w = sqrt.(c.a)) ⨟ mutate(v = parse.(Int, c.s))
    @test outcome(() -> p2(bad2)) == (:err, DomainError)
    for th in (true, false)
        @test outcome(() -> collect(p2(lazy(bad2)); morsel = 7, threads = th)) == (:err, DomainError)
    end
    @test time() - t0 < 600
end

@testitem "lazy: regression: projection pushdown through a rename above another step" tags = [:unit] setup = [LazyProp] begin
    # Found by the lazy == eager property (lane p3-prop): the rename's `_need_in` built a
    # Set{Any}, and `optimize` raised a MethodError. Fixed in 5d108a2.
    t = (y = [1, 2, 3],)
    for p in (filter_out(c.y .> 2) ⨟ rename(yy = :y) ⨟ select(:yy), mutate(z = c.y .* 2) ⨟ rename(yy = :y) ⨟ select(:yy))
        @test outcome(() -> p(t))[1] === :ok
        @test outcomes_agree(outcome(() -> p(t)), outcome(() -> collect(p(lazy(t)))))
    end
end
