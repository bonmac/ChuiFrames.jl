# Property tests of the compiled stage kernels against the interpreter (spec
# docs/superpowers/specs/2026-10-26-phase4-joins-groupby-codegen-design.md §3.5; critic B2, N3,
# n2, n7): random streamed stages on random tables (NaN, -NaN, ±0.0, Inf, `missing`, a zero
# divisor, negative logs, a dictionary column with an unused level), run through the compiled
# kernel (forced) and through `interpret_stage`. Same outcome kind; on error the same exception
# type; on success the same names, row count, `typeof(col)` per column and bitwise-equal values
# (`===` on floats, so -0.0 and NaN payloads count), also on the empty morsel. The before/after
# difference of `_KERNEL_DISAGREE` must be 0 (n7). Must pass under `julia -t 1` and `-t 4`.

@testsnippet KernProp begin
    using Supposition, Supposition.Data
    using Tables
    const ⨟ = ChuiFrames.Upstream.:⨟
    const CF = ChuiFrames
    const NMAX = 12
    const XV = Union{Missing, Float64}[NaN, -NaN, 0.0, -0.0, 1.5, -2.0, 3.25, Inf, -Inf, missing]
    const LV = ["a", "b", "c", "unused"]
    const SV = ["p", "q", "pq", ""]
    tablegen = @composed function ktable(
            n = Data.Integers(0, NMAX),
            g = Data.Vectors(Data.Integers(1, 3); min_size = NMAX, max_size = NMAX),
            x = Data.Vectors(Data.SampledFrom(XV); min_size = NMAX, max_size = NMAX),
            y = Data.Vectors(Data.Integers(-3, 3); min_size = NMAX, max_size = NMAX),
            z = Data.Vectors(Data.Integers(-2, 2); min_size = NMAX, max_size = NMAX),
            s = Data.Vectors(Data.SampledFrom(SV); min_size = NMAX, max_size = NMAX),
        )
        Frame(
            [:g, :x, :y, :z, :s],
            CF.AbstractColumn[
                CF.DictColumn(UInt8.(g[1:n]), CF.column(LV)),
                CF.column(Union{Missing, Float64}[x[1:n]...]), CF.column(y[1:n]), CF.column(z[1:n]), CF.column(s[1:n]),
            ],
        )
    end
    # Streamed steps: compilable ones, ones that throw on some rows (log of negatives, a zero
    # divisor, a throwing scalar subexpression, case_when/filter branches that throw), ones the
    # kernel declines (`/` and `sqrt` on Int: the values are not the declared Int), and ones that
    # do not compile (a Pipe; a String case_when) so mixed stages run the interpreter.
    const STEPS = Any[
        filter(c.y .> 0), filter(c.x .<= 1.0), filter(.!(isnan.(c.x))), filter(ismissing.(c.x)),
        filter((c.y .> 0) .& (c.x .>= -2.0)), filter(c.y .>= 0, c.x .< 3.0), filter_out(c.y .> 0),
        filter(c.g .== "a"), filter(startswith.(c.s, "p")), filter(c.y .> 100),
        mutate(w = c.y .* 2), mutate(x = c.x .+ 1.0), mutate(y = c.y .- 1), mutate(v = c.x .* c.y),
        mutate(m = max.(c.y, c.z)), mutate(b = c.g), mutate(s = nothing), mutate(k = lit(2) .+ lit(3)),
        mutate(cw = case_when(c.y .> 1 => c.x, c.y .< -1 => 0.5; default = missing)),
        mutate(cb = case_when(c.x .> 0.0 => c.y; default = 0)),
        mutate(fl = (c.x .> 0.0) .| (c.y .== 1)), mutate(n = c.y .+ 1; before = :x),
        mutate(neg = 0.0 .- c.x, a = abs.(c.neg) .* 2.0),
        select(:g, :x, :y, :z, :s), select(:x, :g, :z, :y), select(:g, xx = c.x, :y, :z, :s),
        select(:y, :z, :s, :g, :x, w2 = c.y .+ 1), rename(yy = :y), relocate(:s), relocate(:x, :y),
        rename_with(uppercase, [:s]),
        # throwing
        mutate(l = log.(c.x)), mutate(d = div.(c.y, c.z)), filter(log.(c.x) .> -10.0),
        mutate(c2 = case_when(c.y .> 1 => c.x, log.(c.x) .> 0.0 => c.x; default = 0.0)),
        mutate(q = c.x .+ sqrt.(lit(-1.0))),
        # declined (values of another type than the static type)
        mutate(h = c.y ./ 2), mutate(r = sqrt.(c.y)),
        # not compilable
        mutate(p = c.y |> v -> v .+ 1), mutate(cs = case_when(c.y .> 0 => "pos"; default = "neg")),
    ]
    stepsgen = Data.Vectors(Data.SampledFrom(STEPS); min_size = 1, max_size = 5)
    pipe(steps) = foldl(⨟, steps)
    pipestr(steps) = sprint(show, pipe(steps))

    function outcome(g)
        try
            return (:ok, g())
        catch err
            err isa InterruptException && rethrow()
            return (:err, typeof(err))
        end
    end
    bitsame(a, b) = isequal(a, b) && (!(a isa AbstractFloat) || a === b)
    function framesame(a::Frame, b::Frame)
        a.names == b.names && a.nrow == b.nrow && a.groups == b.groups || return false
        for i in eachindex(a.columns)
            ca, cb = a.columns[i], b.columns[i]
            typeof(ca) === typeof(cb) || return false
            all(j -> bitsame(ca[j], cb[j]), eachindex(ca)) || return false
            ca isa CF.DictColumn && (isequal(collect(ca.dict), collect(cb.dict)) || return false)
        end
        return true
    end
    agree(e, k) = e[1] === k[1] && (e[1] === :err ? e[2] === k[2] : framesame(e[2], k[2]))
    function report(steps, e, k)
        event!("stage", pipestr(steps))
        event!("interpreter", e[1] === :err ? e : (:ok, Tables.columntable(e[2])))
        event!("compiled", k[1] === :err ? k : (:ok, Tables.columntable(k[2])))
        return false
    end
    const DEADLINE = Ref(Inf)
    deadline!(secs) = (DEADLINE[] = time() + secs; nothing)
    checktime() = time() > DEADLINE[] && error("property time budget exceeded")
    show_failure(sr) = Supposition.results(sr).ispass ||
        @info "counterexample" report = sprint(show, MIME("text/plain"), sr)
end

@testitem "kernel property: compiled == interpreter on random stages" tags = [:property] setup = [Force, KernProp] begin
    counts = Dict(:ok => 0, :err => 0, :compiled => 0)
    function same_as_interpreter(f, steps)
        checktime()
        ph = CF.physical(pipe(steps)(lazy(f)).plan)
        isempty(ph.rest) || return true          # every vocabulary step streams
        k = withforce(() -> CF.stage_kernel(ph, 0), CF._FORCE_KERNEL => :compiled)
        k isa CF.CompiledStage && (counts[:compiled] += 1)
        for input in (f, CF.take(f, Int[]))      # the morsel, and the empty morsel's types
            e = outcome(() -> CF.interpret_stage(ph)(input))
            r = outcome(() -> k(input))
            counts[e[1]] += 1
            agree(e, r) || return report(steps, e, r)
        end
        return true
    end
    deadline!(300)
    d0 = CF._KERNEL_DISAGREE[]
    t0 = time()
    sr = @check record = false db = false max_examples = 800 same_as_interpreter(tablegen, stepsgen)
    elapsed = time() - t0
    show_failure(sr)
    @test Supposition.results(sr).ispass
    @test CF._KERNEL_DISAGREE[] - d0 == 0                 # critic n7
    @info "compiled == interpreter" ok = counts[:ok] err = counts[:err] compiled_stages = counts[:compiled] seconds = round(elapsed; digits = 1) nthreads = Threads.nthreads()
    @test counts[:ok] > 0 && counts[:err] > 0 && counts[:compiled] > 0
    @test elapsed < 600
end

@testitem "kernel property: collect agrees forced compiled vs interpreter, then group_by(drop = false)" tags = [:property] setup = [Force, KernProp] begin
    # whole runs: random morsel sizes and threading; a dictionary column with an unused level is
    # grouped with drop = false after the stage, so its empty levels must survive (critic N3)
    tail = group_by(:g; drop = false) ⨟ summarise(n = n_rows())
    function runs_agree(f, steps, m, th, grouped)
        checktime()
        p = grouped ? pipe(steps) ⨟ tail : pipe(steps)
        q = p(lazy(f))
        a = outcome(() -> withforce(() -> collect(q; morsel = m, threads = th), CF._FORCE_KERNEL => :compiled))
        b = outcome(() -> withforce(() -> collect(q; morsel = m, threads = th), CF._FORCE_KERNEL => :interpreter))
        agree(b, a) && return true
        return report(steps, b, a)
    end
    deadline!(300)
    d0 = CF._KERNEL_DISAGREE[]
    t0 = time()
    sr = @check record = false db = false max_examples = 400 runs_agree(tablegen, stepsgen, Data.Integers(1, 7), Data.Booleans(), Data.Booleans())
    elapsed = time() - t0
    show_failure(sr)
    @test Supposition.results(sr).ispass
    @test CF._KERNEL_DISAGREE[] - d0 == 0
    @test elapsed < 600
end

@testitem "kernel property: the rendered kernel gives the compiled kernel's values (ADR-0003 rule 13)" tags = [:property] setup = [Force, KernProp] begin
    # The rendered expression (what `code_lowered` shows) evaluated in the test process against
    # the closure kernel: the same outcome kind and `isequal` values per column name. (The
    # rendered kernel builds plain vectors, so column kinds and element types are not compared;
    # it does not apply `mutate(...; before/after)`, so column order is not compared either.)
    function rendered_agrees(f, steps)
        checktime()
        ph = CF.physical(pipe(steps)(lazy(f)).plan)
        ex = CF.render_kernel(ph)
        ex === nothing && return true            # a step does not resolve on the schema
        k = withforce(() -> CF.stage_kernel(ph, 0), CF._FORCE_KERNEL => :compiled)
        a = outcome(() -> k(f))
        r = outcome(() -> Base.invokelatest(Core.eval(@__MODULE__, ex), Tables.columntable(f)))
        a[1] === r[1] || return report(steps, a, r)
        a[1] === :err && return true
        want = Tables.columntable(a[2])
        got = r[2]
        ok = sort(collect(keys(got))) == sort(collect(keys(want))) &&
            all(n -> isequal(collect(got[n]), collect(want[n])), keys(want))
        ok || (event!("stage", pipestr(steps)); event!("compiled", want); event!("rendered", got))
        return ok
    end
    deadline!(300)
    t0 = time()
    sr = @check record = false db = false max_examples = 300 rendered_agrees(tablegen, stepsgen)
    elapsed = time() - t0
    show_failure(sr)
    @test Supposition.results(sr).ispass
    @test elapsed < 600
end
