# lazy == eager for the grouped sinks (phase-4 spec §2, §4; plan task 7; CF-008): random tables
# (NaN, -NaN, ±0.0, Inf, `missing`), a random streamed prefix, a grouped step (the hash-aggregate
# sink, a summary it does not take, or a grouped window) and a random tail, at morsel sizes 1–7,
# with and without threads, with the radix switch forced at 4 groups or not. Inputs: the table; a
# `DictColumn` key with an unused level (so `group_by(drop = false)` shows it, N3); and a Source
# whose partitions carry permuted dictionaries of their own (per-batch dictionaries, M6). Results
# agree with approximate frame equality for floats (LazyProp's rtol = 1e-12 on Float64 data,
# stricter than CF-008's CC-004 tolerance) and in element types; exception
# types agree. Must pass under `julia -t 1` and `-t 4`.

@testitem "lazy property: grouped sinks == eager (hash aggregate, grouped windows; CF-008)" tags = [:property] setup = [LazyProp, Force] begin
    const CF = ChuiFrames
    # A source whose partitions are frames with a dictionary-encoded `g`, each with its own
    # (permuted, partly unused) dictionary. Not thread-safe (the default): reads take the lock.
    struct PermDictSource <: CF.Source
        parts::Vector{Frame}
    end
    CF.source_schema(s::PermDictSource) = Tables.Schema(Tuple(s.parts[1].names), Tuple(eltype(c) for c in s.parts[1].columns))
    CF.source_label(::PermDictSource) = "permuted-dictionary test source"
    CF.plan_partitions(s::PermDictSource, scan::Tables.Scan; morsel::Int = 1) = (collect(eachindex(s.parts)), scan)
    CF.read_partition(s::PermDictSource, p::Int) = s.parts[p]

    const LV = ["a", "b", "c", "zz"]
    const PERMS = ([1, 2, 3, 4], [3, 1, 4, 2], [4, 3, 2, 1], [2, 4, 1, 3])
    dictg(g, lv) = CF.DictColumn(UInt8[findfirst(==(v), lv) for v in g], CF.column(lv))
    framed(t, g) = Frame(g = g, x = t.x, y = t.y, s = t.s)
    # input kinds: 0 the table; 1 g as a dictionary column (unused level "zz"); 2 the permuted-
    # dictionary source, cut into partitions at `cuts`
    function input_of(t, kind, cuts)
        kind == 0 && return t
        kind == 1 && return framed(t, dictg(t.g, LV))
        n = length(t.g)
        bounds = unique!(sort!([0; [c for c in cuts if c < n]; n]))
        parts = Frame[]
        for k in 1:(length(bounds) - 1)
            rows = (bounds[k] + 1):bounds[k + 1]
            lv = LV[PERMS[mod1(k, length(PERMS))]]
            tk = (g = t.g[rows], x = t.x[rows], y = t.y[rows], s = t.s[rows])
            push!(parts, framed(tk, dictg(tk.g, lv)))
        end
        isempty(parts) && push!(parts, framed(t, dictg(t.g, LV)))
        return PermDictSource(parts)
    end
    eager_input(x) = x isa CF.Source ? CF.read_source(x) : x
    lazy_of(p, x) = p(lazy(x))

    nsink = Ref(0)
    nerr = Ref(0)
    nok = Ref(0)
    prefixgen = Data.Vectors(Data.SampledFrom(STREAMED); max_size = 2)
    tailgen = Data.Vectors(Data.SampledFrom(REST); max_size = 1)
    cutsgen = Data.Vectors(Data.Integers(1, NMAX); max_size = 3)
    function grouped_eq(t, kind, cuts, pre, gs, tail, m, th, force)
        checktime()
        input = input_of(t, kind, cuts)
        steps = Any[pre; gs; tail]
        p = foldl(⨟, steps)
        e = outcome(() -> p(eager_input(input)))
        l, r, st = withforce(CF._FORCE_RADIX_SWITCH => (force ? 4 : 0)) do
            l = outcome(() -> collect(lazy_of(p, input); morsel = m, threads = th))
            st = CF.ExecStats()
            r = outcome(() -> CF.execute(CF.physical(CF.optimize(lazy_of(p, input)).plan); morsel = m, threads = th, stats = st))
            l, r, st
        end
        st.sink === :hashagg && (nsink[] += 1)
        e[1] === :err ? (nerr[] += 1) : (nok[] += 1)
        ok = outcomes_agree(e, l; approx = true) && raw_ok(e, r; approx = true)
        ok && e[1] === :ok && (ok = eltypes_agree(e[2], l[2]) && (r[1] === :err || eltypes_agree(e[2], r[2])))
        ok && return true
        event!("input kind", kind)
        event!("radix forced", force)
        event!("raw engine", r[1] === :err ? r : (:ok, Tables.columntable(r[2])))
        e[1] === :ok && l[1] === :ok && event!("element types", (eager = map(eltype, e[2].columns), lazy = map(eltype, l[2].columns)))
        return explain_failure(steps, e, l)
    end
    deadline!(400)
    t0 = time()
    sr = @check record = false db = false max_examples = 2500 grouped_eq(
        tablegen, Data.Integers(0, 2), cutsgen, prefixgen, gsinkgen, tailgen, morselgen, threadgen, Data.Booleans(),
    )
    elapsed = time() - t0
    show_failure(sr)
    @test Supposition.results(sr).ispass
    @info "grouped sinks lazy == eager" examples_ok = nok[] examples_err = nerr[] hashagg = nsink[] seconds = round(elapsed; digits = 1) nthreads = Threads.nthreads()
    @test nok[] > 0 && nerr[] > 0 && nsink[] > 0     # both outcomes, and the sink, are exercised
    @test elapsed < 600
end

@testitem "lazy property: grouped sinks on larger tables (many groups, radix switch, all morsel sizes)" tags = [:property, :unit] setup = [LazyProp, Force] begin
    const CF = ChuiFrames
    deadline!(300)
    n = 1_500
    big = (
        g = [string("k", mod(i * 7919, 97)) for i in 1:n],
        x = Union{Missing, Float64}[XV[mod1(i * 7, length(XV))] for i in 1:n],
        y = [mod(i, 13) - 6 for i in 1:n],
        s = [string(Char('a' + mod(i, 26))) for i in 1:n],
    )
    for gs in GSINKS, force in (false, true), m in (1, 7, 64, 2_000)
        checktime()
        e = outcome(() -> gs(big))
        l = withforce(CF._FORCE_RADIX_SWITCH => (force ? 4 : 0)) do
            outcome(() -> collect(gs(lazy(big)); morsel = m, threads = true))
        end
        @test outcomes_agree(e, l; approx = true)
        e[1] === :ok && l[1] === :ok && @test eltypes_agree(e[2], l[2])
    end
end
