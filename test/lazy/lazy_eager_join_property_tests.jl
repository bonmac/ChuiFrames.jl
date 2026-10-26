# Property tests of lazy joins against eager joins and the oracle (phase-4 spec
# docs/superpowers/specs/2026-10-26-phase4-joins-groupby-codegen-design.md §4; CF-008). Random x
# and y tables with NaN, ±0.0, `missing` and duplicate keys, empty tables, every join kind with
# random options, steps before and after the join, morsel sizes 1-7, threading on and off, and
# every `_FORCE_JOIN` value. They must pass under `julia -t 1` and `-t 4`.
#
# `LazyProp` (test/lazy/lazy_eager_property_tests.jl) is used read-only. This file has its own
# raw runner (critic n8, pass 3 m6): it calls the package's `_lower_joins`, never a copy, then
# `execute(physical(...))` with no eager replay, unwrapping `MorselError` as `collect` does
# (critic pass-3 p2). The raw runner's exceptions are compared by type only (MAJOR-2); `collect`'s
# replay gives eager's exception, message included. Its comparator also checks each column's
# element type, and each nested frame's names and column types (MAJOR-4b).

@testsnippet JoinProp begin
    const JFORCES = (:auto, :broadcast_x, :broadcast_y, :partitioned_x, :partitioned_y)
    const KV = Union{Missing, Float64}[NaN, -NaN, 0.0, -0.0, 1.0, 2.0, missing]
    const JMAX = 7
    xgen = @composed function jxtable(
            n = Data.Integers(0, JMAX),
            k = Data.Vectors(Data.SampledFrom(KV); min_size = JMAX, max_size = JMAX),
            i = Data.Vectors(Data.Integers(1, 3); min_size = JMAX, max_size = JMAX),
            v = Data.Vectors(Data.Integers(-3, 3); min_size = JMAX, max_size = JMAX),
            s = Data.Vectors(Data.SampledFrom(["a", "b", "c"]); min_size = JMAX, max_size = JMAX),
        )
        (k = Union{Missing, Float64}[k[1:n]...], i = i[1:n], v = v[1:n], s = s[1:n])
    end
    ygen = @composed function jytable(
            n = Data.Integers(0, JMAX),
            k = Data.Vectors(Data.SampledFrom(KV); min_size = JMAX, max_size = JMAX),
            i = Data.Vectors(Data.Integers(1, 4); min_size = JMAX, max_size = JMAX),
            w = Data.Vectors(Data.Integers(-3, 3); min_size = JMAX, max_size = JMAX),
            s = Data.Vectors(Data.SampledFrom(["a", "b", "d"]); min_size = JMAX, max_size = JMAX),
        )
        (k = Union{Missing, Float64}[k[1:n]...], i = i[1:n], w = w[1:n], s = s[1:n])
    end
    const KINDS = (:inner, :left, :right, :full, :semi, :anti, :nest, :cross)
    const BYS = Any[:k, :i, [:k, :i], :s, :i => :i, [:s, :k], nothing]
    "A join step from generated options (only the keywords each verb accepts)."
    function mkjoin(kind, by, keep, multiple, unmatched, na, y)
        kind === :inner && return inner_join(y; by, keep, multiple, unmatched, na_matches = na)
        kind === :left && return left_join(y; by, keep, multiple, unmatched, na_matches = na)
        kind === :right && return right_join(y; by, keep, multiple, unmatched, na_matches = na)
        kind === :full && return full_join(y; by, keep, multiple, na_matches = na)
        kind === :semi && return semi_join(y; by, na_matches = na)
        kind === :anti && return anti_join(y; by, na_matches = na)
        kind === :nest && return nest_join(y; by, keep, unmatched, na_matches = na)
        return cross_join(y)
    end
    # Steps before the join (on x) and after it: total ones, plus a select that may name a
    # column the join renamed (an ArgumentError in both paths).
    const PRE = Any[filter(c.v .> -2), filter(isnan.(c.k)), filter(.!(ismissing.(c.k))), mutate(z = c.v .* 2), select(:k, :i, :v, :s), rename(vv = :v), arrange(desc(c.v))]
    const POST = Any[filter(c.i .> 1), filter(c.v .>= 0), head(2), head(0), select(:k), select(:s), arrange(c.v), mutate(q = c.i .+ 1)]
    pregen = Data.Vectors(Data.SampledFrom(PRE); max_size = 2)
    postgen = Data.Vectors(Data.SampledFrom(POST); max_size = 2)

    unwrap(e) = e isa ChuiFrames.MorselError ? unwrap(e.err) :
        (e isa Union{TaskFailedException, CompositeException} ? unwrap(ChuiFrames._taskerror(e)) : e)
    "The engine with no replay: the package's own lowering, then the morsel executor."
    run_raw_join(q; morsel, threads) = ChuiFrames.execute(
        ChuiFrames.physical(ChuiFrames._lower_joins(ChuiFrames.optimize(q).plan; morsel, threads)); morsel, threads
    )
    function outcome_raw(f)
        try
            return (:ok, f())
        catch err
            return (:err, typeof(unwrap(err)))
        end
    end
    "frames_agree plus element types per column, and nested frames' names and column types."
    function jagree(a, b)
        frames_agree(a, b) || return false
        for (ca, cb) in zip(a.columns, b.columns)
            eltype(ca) == eltype(cb) || return false
            if eltype(ca) === Frame
                for i in eachindex(ca)
                    fa, fb = ca[i], cb[i]
                    (fa.names == fb.names && [eltype(c) for c in fa.columns] == [eltype(c) for c in fb.columns]) || return false
                end
            end
        end
        return true
    end
    joutcomes_agree(e, l) = e[1] === l[1] && (e[1] === :err ? e[2] === l[2] : jagree(e[2], l[2]))
    "Every forcing pair for a run: the join strategy, and the group-by lane's radix switch when present."
    forcepairs(v) = isdefined(ChuiFrames, :_FORCE_RADIX_SWITCH) ?
        (ChuiFrames._FORCE_JOIN => v, getfield(ChuiFrames, :_FORCE_RADIX_SWITCH) => 4) : (ChuiFrames._FORCE_JOIN => v,)
    quiet(f) = Base.CoreLogging.with_logger(f, Base.CoreLogging.NullLogger())
end

@testitem "join property: lazy == eager on random joins, every shape (CF-008)" tags = [:property] setup = [LazyProp, Force, JoinProp] begin
    nok = Ref(0)
    nerr = Ref(0)
    function join_eq(xt, yt, pre, ki, bi, keep, mi, ui, na, ylazy, post, m, th)
        checktime()
        kind = KINDS[ki]
        y = ylazy ? (lazy(yt) |> filter(c.w .> -3)) : Frame(yt)
        js = mkjoin(kind, BYS[bi], keep, (:all, :first, :last, :any, :error)[mi], (:drop, :error)[ui], na ? :na : :never, y)
        steps = Any[pre; js; post]
        p = pipe(steps)
        e = quiet(() -> outcome(() -> run_eager(p, xt)))
        e[1] === :err ? (nerr[] += 1) : (nok[] += 1)
        for v in JFORCES
            l = quiet(() -> withforce(() -> outcome(() -> run_lazy(p, xt; morsel = m, threads = th)), forcepairs(v)...))
            r = quiet(() -> withforce(() -> outcome_raw(() -> run_raw_join(p(lazy(xt)); morsel = m, threads = th)), forcepairs(v)...))
            ok = joutcomes_agree(e, l) && joutcomes_agree(e, r)
            if !ok
                event!("force", v)
                event!("raw engine", r[1] === :err ? r : (:ok, Tables.columntable(r[2])))
                return explain_failure(steps, e, l)
            end
        end
        return true
    end
    deadline!(500)
    t0 = time()
    sr = @check record = false db = false max_examples = 600 join_eq(
        xgen, ygen, pregen, Data.Integers(1, length(KINDS)), Data.Integers(1, length(BYS)), Data.Booleans(),
        Data.Integers(1, 5), Data.Integers(1, 2), Data.Booleans(), Data.Booleans(), postgen, morselgen, threadgen,
    )
    elapsed = time() - t0
    show_failure(sr)
    @test Supposition.results(sr).ispass
    @info "join lazy == eager" examples_ok = nok[] examples_err = nerr[] seconds = round(elapsed; digits = 1) nthreads = Threads.nthreads()
    @test nok[] > 0 && nerr[] > 0
    @test elapsed < 900
end

@testitem "join property: eager joins agree with the nested-loop oracle" tags = [:property] setup = [LazyProp, Force, JoinProp, Oracle] begin
    function oracle_eq(xt, yt, ki, bi, keep, mi, ui, na, fi)
        checktime()
        kind = KINDS[ki]
        by = BYS[bi]
        by === nothing && (by = [n for n in keys(xt) if n in keys(yt)])
        pairs = by isa Pair ? [by] : by isa Symbol ? [by => by] : [b => b for b in by]
        multiple, unmatched = (:all, :first, :last, :any, :error)[mi], (:drop, :error)[ui]
        unmatched = kind in (:full, :semi, :anti, :cross) ? :drop : unmatched
        multiple = kind in (:semi, :anti, :nest, :cross) ? :all : multiple
        e = quiet(() -> withforce(() -> outcome(() -> mkjoin(kind, by, keep, multiple, unmatched, na ? :na : :never, Frame(yt))(xt)), forcepairs(JFORCES[fi])...))
        o = try
            (:ok, Oracle.ojoin(kind, Oracle.OTable(xt), Oracle.OTable(yt); by = kind === :cross ? Pair{Symbol, Symbol}[] : pairs, na_matches = na ? :na : :never, keep, multiple, unmatched))
        catch err
            (:err, typeof(err), sprint(showerror, err))
        end
        if e[1] === :err || o[1] === :err
            ok = e[1] === o[1] === :err && e[2] === o[2]
            ok || (event!("eager", e); event!("oracle", o))
            return ok
        end
        ok = Oracle.agree(e[2], o[2])
        ok || (event!("eager", Tables.columntable(e[2])); event!("oracle", o[2]))
        return ok
    end
    deadline!(300)
    t0 = time()
    sr = @check record = false db = false max_examples = 1500 oracle_eq(
        xgen, ygen, Data.Integers(1, length(KINDS)), Data.Integers(1, length(BYS)), Data.Booleans(),
        Data.Integers(1, 5), Data.Integers(1, 2), Data.Booleans(), Data.Integers(1, length(JFORCES)),
    )
    show_failure(sr)
    @test Supposition.results(sr).ispass
    @test time() - t0 < 600
end

@testitem "join property: a mutated key whose type differs per morsel (MAJOR-1)" tags = [:property, :unit] setup = [LazyProp, Force, JoinProp] begin
    f(a) = a > 1 ? 1.5 : 1
    b = mutate(:k => f.(c.a)) ⨟ inner_join(Frame(k = [1.5]); by = :k)
    x = (a = [1, 2],)
    e = outcome(() -> b(x))
    @info "MAJOR-1: eager outcome" e
    for v in JFORCES, m in 1:7, th in (false, true)
        l = withforce(() -> outcome(() -> run_lazy(b, x; morsel = m, threads = th)), forcepairs(v)...)
        r = withforce(() -> outcome_raw(() -> run_raw_join(b(lazy(x)); morsel = m, threads = th)), forcepairs(v)...)
        @test joutcomes_agree(e, l)
        @test joutcomes_agree(e, r)
    end
end
