# Compiled stage kernels (spec docs/superpowers/specs/2026-10-26-phase4-joins-groupby-codegen-design.md
# §3; ADR-0003 rule 12): the decision, the whitelist, the typeof(col) probe check, column kinds,
# scalar-only subexpressions, no short-circuit, the interpreter re-run on exceptions, the cache
# and the explain line. Forcing goes through `withforce` (spec §0.3).

@testsnippet KernelHelp begin
    using Tables
    const ⨟ = ChuiFrames.Upstream.:⨟
    const CF = ChuiFrames
    # The physical plan of `q` as written (no optimizer, so no folding or pushdown).
    rawph(q) = CF.physical(q.plan)
    optph(q) = CF.physical(CF.optimize(q).plan)
    interp(ph, f) = CF.interpret_stage(ph)(f)
    # Run `g()`; return the exception type, or :ok.
    errtype(g) = try
        g()
        :ok
    catch err
        typeof(err)
    end
    coltypes(f) = map(typeof, f.columns)
    same(a, b) = a.names == b.names && a.nrow == b.nrow && coltypes(a) == coltypes(b) &&
        isequal(Tables.columntable(a), Tables.columntable(b))
    disagree() = CF._KERNEL_DISAGREE[]
end

@testitem "kernels: switches, counter, cache, threshold exist" tags = [:unit] begin
    @test ChuiFrames._FORCE_KERNEL isa Base.RefValue{Symbol}
    @test ChuiFrames._FORCE_KERNEL[] === :auto
    @test ChuiFrames._KERNEL_DISAGREE isa Threads.Atomic{Int}
    @test ChuiFrames._KERNEL_CACHE isa Dict{Any, Any}
    @test ChuiFrames._KERNEL_LOCK isa ReentrantLock
    @test ChuiFrames.INTERP_THRESHOLD isa Int && ChuiFrames.INTERP_THRESHOLD > 0
end

@testitem "kernels: kernel_decision" tags = [:unit] setup = [Force, KernelHelp] begin
    t = (x = [1.0, 2.0, 3.0], y = [1, 2, 3], s = ["a", "b", "c"])
    # a shape no other test uses, so it is not cached
    ph = rawph((filter(c.y .>= 2) ⨟ mutate(zdec = c.x .* 7.5 .+ c.y))(lazy(t)))
    T = CF.INTERP_THRESHOLD
    @test CF.kernel_decision(ph, T - 1)[1] === :interpreter
    @test occursin("INTERP_THRESHOLD", CF.kernel_decision(ph, T - 1)[2])
    @test CF.kernel_decision(ph, nothing)[1] === :interpreter
    @test occursin("unknown", CF.kernel_decision(ph, nothing)[2])
    @test CF.kernel_decision(ph, T) == (:compiled, "compiled at collect")
    withforce(CF._FORCE_KERNEL => :interpreter) do
        @test CF.kernel_decision(ph, T) == (:interpreter, "forced")
    end
    withforce(CF._FORCE_KERNEL => :compiled) do
        @test CF.kernel_decision(ph, 0)[1] === :compiled
        @test CF.kernel_decision(ph, nothing)[1] === :compiled
        # compiled once: cached for the session, so small inputs use it too
        CF.stage_kernel(ph, 0)(Frame(t))
    end
    @test CF.kernel_decision(ph, 0) == (:compiled, "cached")
    @test CF.kernel_decision(ph, nothing) == (:compiled, "cached")
    # a new literal value is the same shape (literals are runtime values)
    ph2 = rawph((filter(c.y .>= 3) ⨟ mutate(zdec = c.x .* -1.25 .+ c.y))(lazy(t)))
    @test CF.kernel_decision(ph2, 0) == (:compiled, "cached")
    # a different function is a different shape
    ph3 = rawph((filter(c.y .>= 3) ⨟ mutate(zdec = c.x .- -1.25 .+ c.y))(lazy(t)))
    @test CF.kernel_decision(ph3, 0)[1] === :interpreter
    # no stage
    @test CF.kernel_decision(rawph(arrange(c.x)(lazy(t))), T)[1] === :interpreter
end

@testitem "kernels: the whitelist" tags = [:unit] setup = [Force, KernelHelp] begin
    using Statistics
    t = (x = [1.0, 2.0, 3.0], y = [1, 2, 3], s = ["a", "b", "c"])
    big = CF.INTERP_THRESHOLD
    why(q) = CF.kernel_decision(rawph(q(lazy(t))), big)
    # compilable: filter, elementwise mutate, select of names and pairs, rename(_with), relocate
    for q in Any[
            filter(c.y .> 1), filter_out(c.x .> 1.0, c.y .< 3), mutate(z = c.x .+ 1.0),
            mutate(z = case_when(c.y .> 1 => c.x; default = 0.0)), select(:x, w = c.y .* 2),
            rename(xx = :x), rename_with(uppercase), relocate(:s), mutate(k = lit(1) .+ lit(2)),
            mutate(b = c.x), mutate(s = nothing), filter(startswith.(c.s, "a")),
        ]
        @test why(q)[1] === :compiled
    end
    # not compilable: a Pipe, a vector literal, if_any, unknown static types, a nullable select
    # pair, case_when values that are not columns or scalar literals, a non-Bool filter
    for q in Any[
            mutate(z = c.y |> v -> v .+ 1), mutate(z = c.x .+ [1.0, 2.0, 3.0]),
            filter(if_any([:x], v -> v .> 1.0)), mutate(z = parse.(Int, c.s)),
            mutate(z = case_when(c.y .> 1 => c.x .+ 1.0; default = 0.0)),
            mutate(z = case_when(c.y .> 1 => "big"; default = "small")),
        ]
        k, w = why(q)
        @test k === :interpreter
        @test !isempty(w)
    end
    # deeper than 50 nodes
    deep = foldl((acc, _) -> acc .+ 1.0, 1:60; init = c.x)
    @test occursin("50", why(mutate(z = deep))[2])
end

@testitem "kernels: compiled == interpreter, column kinds kept (N3)" tags = [:unit] setup = [Force, KernelHelp] begin
    lv = ["a", "b", "c", "unused"]
    g = CF.DictColumn(UInt8[1, 2, 1, 3, 2], CF.column(lv))
    f = Frame(
        [:g, :x, :y, :s],
        CF.AbstractColumn[g, CF.column(Union{Missing, Float64}[1.0, missing, -0.0, NaN, 2.0]), CF.column([1, 2, 3, 4, 5]), CF.column(["p", "q", "r", "s", "t"])],
    )
    stages = Any[
        filter(c.y .> 1),
        filter(c.y .> 1) ⨟ mutate(z = c.x .* 2.0, w = c.z .+ c.y) ⨟ rename(gg = :g),
        mutate(z = c.y .* 2) ⨟ filter(c.z .> 4) ⨟ select(:g, :z, q = c.y .+ 1),
        mutate(x = c.x .+ 1.0, y = nothing) ⨟ relocate(:x),
        mutate(z = case_when(c.y .> 3 => c.x, c.y .> 1 => 0.5; default = missing)),
        filter_out(c.x .> 0.0) ⨟ mutate(b = c.g),
        mutate(n = c.y .+ 1; before = :g) ⨟ filter(isnan.(c.x) .| (c.y .== 1)),
    ]
    for st in stages
        ph = rawph(st(lazy(f)))
        withforce(CF._FORCE_KERNEL => :compiled) do
            k = CF.stage_kernel(ph, 0)
            @test !(k isa Function)                      # a compiled kernel, not the interpreter
            d0 = disagree()
            out = k(f)
            @test disagree() - d0 == 0
            @test same(out, interp(ph, f))
            # empty morsel: same column types
            e = CF.take(f, Int[])
            @test same(k(e), interp(ph, e))
        end
    end
    # the dictionary column keeps its object (no filter) or its dictionary (filtered)
    withforce(CF._FORCE_KERNEL => :compiled) do
        ph = rawph(mutate(z = c.y .* 2)(lazy(f)))
        @test CF.stage_kernel(ph, 0)(f).columns[1] === g
        ph = rawph(filter(c.y .> 2)(lazy(f)))
        out = CF.stage_kernel(ph, 0)(f)
        @test out.columns[1] isa CF.DictColumn
        @test out.columns[1].dict === g.dict
    end
    # downstream group_by(drop = false) still sees the unused levels
    q = (filter(c.y .> 2) ⨟ group_by(:g; drop = false) ⨟ summarise(n = n_rows()))(lazy(f))
    a = withforce(() -> collect(q; morsel = 2), CF._FORCE_KERNEL => :compiled)
    b = withforce(() -> collect(q; morsel = 2), CF._FORCE_KERNEL => :interpreter)
    @test same(a, b)
    @test length(Tables.getcolumn(a, :g)) == 4
end

@testitem "kernels: exceptions re-run the interpreter (B2, n1, n2)" tags = [:unit] setup = [Force, KernelHelp] begin
    withforce(CF._FORCE_KERNEL => :compiled) do
        # the critic's cross-step case: fused, div would raise first; the interpreter raises DomainError
        t = (x = [1.0, -1.0], y = [1, 1], z = [0, 1])
        ph = rawph((mutate(a = log.(c.x)) ⨟ mutate(b = div.(c.y, c.z)))(lazy(t)))
        k = CF.stage_kernel(ph, 0)
        @test !(k isa Function)
        d0 = disagree()
        @test errtype(() -> k(Frame(t))) === DomainError
        @test errtype(() -> interp(ph, Frame(t))) === DomainError
        # case_when evaluates every branch on every row (no short-circuit)
        t2 = (x = [1.0, -1.0], y = [1, 2])
        ph = rawph(mutate(r = case_when(c.y .> 1 => c.x, log.(c.x) .> 0.0 => c.x; default = 0.0))(lazy(t2)))
        @test errtype(() -> CF.stage_kernel(ph, 0)(Frame(t2))) === DomainError
        @test errtype(() -> interp(ph, Frame(t2))) === DomainError
        # every filter conjunct on every row
        ph = rawph(filter(c.y .> 1, log.(c.x) .> -10.0)(lazy(t2)))
        @test errtype(() -> CF.stage_kernel(ph, 0)(Frame(t2))) === DomainError
        # division by zero
        ph = rawph(mutate(q = div.(c.y, 0))(lazy(t2)))
        @test errtype(() -> CF.stage_kernel(ph, 0)(Frame(t2))) === DivideError
        # a scalar-only subexpression raises once per morsel, also when no rows are left (n2)
        ph = rawph((filter(c.y .> 100) ⨟ mutate(q = c.x .+ sqrt.(lit(-1.0))))(lazy(t2)))
        k = CF.stage_kernel(ph, 0)
        @test !(k isa Function)
        @test errtype(() -> k(Frame(t2))) === DomainError
        @test errtype(() -> k(CF.take(Frame(t2), Int[]))) === DomainError
        @test errtype(() -> interp(ph, CF.take(Frame(t2), Int[]))) === DomainError
        # the compiled program itself (the probe check sends this stage to the interpreter, so
        # run the built program directly): it raises on a morsel with rows and on an empty one
        prog = CF._build(ph.stage, CF.take(Frame(t2), Int[]))
        @test prog isa CF.StageProgram
        @test errtype(() -> prog(CF.take(Frame(t2), Int[]))) === DomainError
        @test errtype(() -> prog(Frame(t2))) === DomainError
        @test disagree() - d0 == 0
    end
    # InterruptException is rethrown at once, without the interpreter re-run (n1)
    t = (x = [1.0, 2.0],)
    ph = rawph(mutate(y = c.x .+ 1.0)(lazy(t)))
    boom = f -> throw(InterruptException())
    @test errtype(() -> CF._run_guarded(boom, ph, Frame(t))) === InterruptException
    # any other kernel exception: the interpreter's result is used and the counter counts it
    d0 = disagree()
    out = CF._run_guarded(f -> error("kernel bug"), ph, Frame(t))
    @test same(out, interp(ph, Frame(t)))
    @test disagree() - d0 == 1
    # ... and when the interpreter fails too, its exception is raised
    ph = rawph(mutate(y = log.(c.x))(lazy((x = [-1.0],))))
    @test errtype(() -> CF._run_guarded(f -> error("kernel bug"), ph, Frame((x = [-1.0],)))) === DomainError
end

@testitem "kernels: a raw value of another type declines the kernel" tags = [:unit] setup = [Force, KernelHelp] begin
    # `/` on Int columns: the static type says Int, the values are Float64. The interpreter's
    # `typed_column` narrows integral values back to Int; the kernel must not guess, so it
    # declines (no disagreement counted) and the shape is rejected for these column types.
    t = (y = [2, 4, 6], w = [1, 3, 5])
    for tt in (t, (y = [1, 2, 3], w = [1, 3, 5]))
        ph = rawph(mutate(h = c.y ./ 2)(lazy(tt)))
        withforce(CF._FORCE_KERNEL => :compiled) do
            d0 = disagree()
            out = CF.stage_kernel(ph, 0)(Frame(tt))
            @test same(out, interp(ph, Frame(tt)))
            @test disagree() - d0 == 0
        end
        # the decline happened: the shape is rejected for these column types
        @test CF.kernel_decision(ph, 0) == (:interpreter, "the compiled kernel was rejected for this shape")
        @test CF.kernel_decision(ph, CF.INTERP_THRESHOLD) == (:interpreter, "the compiled kernel was rejected for this shape")
    end
end

@testitem "kernels: shape keys do not collide on odd column names (m1)" tags = [:unit] setup = [KernelHelp] begin
    s1 = CF._stageshape(Any[mutate(z = c.a .+ c.b)])
    s2 = CF._stageshape(Any[mutate(z = .+(c.var"a;c:b"))])
    @test s1 != s2
    # output names too
    @test CF._stageshape(Any[mutate(var"z=c:a;" = c.b)]) != CF._stageshape(Any[mutate(z = c.a, b = c.b)])
end

@testitem "kernels: small inputs with an empty cache decide without building (n=10 budget)" tags = [:unit] setup = [Force, KernelHelp] begin
    # With nothing compiled in the session, a stage below INTERP_THRESHOLD (or of unknown size)
    # runs the interpreter without the probe, shape key or build, so the per-query overhead of
    # small lazy queries does not grow (ADR-0022 rule 3, the lazy n=10 row).
    CF._kernel_cache_clear!()
    @test !CF._KERNEL_ANY_COMPILED[]
    t = (x = [1.0, 2.0], y = [1, 2])
    ph = rawph((filter(c.y .> 1) ⨟ mutate(z = c.x .* 2.0))(lazy(t)))
    T = CF.INTERP_THRESHOLD
    @test CF.kernel_decision(ph, 10) == (:interpreter, "estimated 10 rows < INTERP_THRESHOLD = $(T) and shape not compiled yet")
    @test CF.kernel_decision(ph, nothing) == (:interpreter, "row count unknown and shape not compiled yet")
    CF._decide(ph, 10)
    @test (@allocated CF._decide(ph, 10)) < 200
    # with another shape compiled in the session: a hashed lookup, still no probe or build
    other = rawph(mutate(w = c.x .- 3.0)(lazy(t)))
    withforce(() -> CF.stage_kernel(other, 0)(Frame(t)), CF._FORCE_KERNEL => :compiled)
    @test CF._KERNEL_ANY_COMPILED[]
    @test CF.kernel_decision(other, 10) == (:compiled, "cached")
    @test CF.kernel_decision(ph, 10)[1] === :interpreter
    CF._decide(ph, 10)
    @test (@allocated CF._decide(ph, 10)) < 200
    # large inputs still check compilability
    @test CF.kernel_decision(ph, T) == (:compiled, "compiled at collect")
end

@testitem "kernels: _FORCE_KERNEL fails closed (m5)" tags = [:unit] setup = [Force, KernelHelp] begin
    ph = rawph(mutate(z = c.x .+ 1.0)(lazy((x = [1.0],))))
    withforce(CF._FORCE_KERNEL => :bogus) do
        @test_throws ArgumentError CF.kernel_decision(ph, 0)
        @test_throws ArgumentError CF.stage_kernel(ph, 0)
    end
    # also with no streamed stage
    withforce(CF._FORCE_KERNEL => :compile) do
        @test_throws ArgumentError CF.kernel_decision(rawph(arrange(c.x)(lazy((x = [1.0],)))), 0)
    end
end

@testitem "kernels: reentrant under threads" tags = [:unit] setup = [Force, KernelHelp] begin
    n = 1000
    t = (x = collect(1.0:n), y = collect(1:n))
    ph = rawph((filter(c.y .% 3 .!= 0) ⨟ mutate(z = c.x .* 2.0 .+ c.y))(lazy(t)))
    withforce(CF._FORCE_KERNEL => :compiled) do
        k = CF.stage_kernel(ph, 0)
        parts = [CF.take(Frame(t), collect(r)) for r in Iterators.partition(1:n, 50)]
        outs = Vector{Any}(undef, length(parts))
        Threads.@threads for i in eachindex(parts)
            outs[i] = k(parts[i])
        end
        @test all(i -> same(outs[i], interp(ph, parts[i])), eachindex(parts))
    end
end

@testitem "kernels: collect uses the kernel and agrees with eager" tags = [:unit] setup = [Force, KernelHelp] begin
    t = (x = [1.5, -2.0, NaN, 0.0, -0.0, 3.0], y = [1, 2, 3, 4, 5, 6], s = ["a", "b", "c", "d", "e", "f"])
    q = (filter(c.y .> 1) ⨟ mutate(z = c.x .* c.y) ⨟ select(:s, :z) ⨟ arrange(c.s))(lazy(t))
    d0 = disagree()
    a = withforce(() -> collect(q; morsel = 2), CF._FORCE_KERNEL => :compiled)
    @test disagree() - d0 == 0
    @test same(a, collect(q))
    p = filter(c.y .> 1) ⨟ mutate(z = c.x .* c.y) ⨟ select(:s, :z) ⨟ arrange(c.s)
    @test same(a, p(t))
end

@testitem "kernels: explain(; kernel = true) line" tags = [:unit] setup = [Force, KernelHelp] begin
    t = (x = [1.0, 2.0], y = [1, 2])
    q = mutate(zexp = c.x .* 3.5 .- c.y)(lazy(t))
    plain = sprint(io -> explain(io, q))
    @test !occursin("kernel:", plain)
    @test sprint(io -> explain(io, q; kernel = false)) == plain
    withforce(CF._FORCE_KERNEL => :interpreter) do
        @test occursin("kernel: interpreter (forced)", sprint(io -> explain(io, q; kernel = true)))
    end
    withforce(CF._FORCE_KERNEL => :compiled) do
        s = sprint(io -> explain(io, q; kernel = true))
        @test occursin("kernel: compiled (", s)
        collect(q)
    end
    @test occursin("kernel: compiled (cached)", sprint(io -> explain(io, q; kernel = true)))
    q2 = mutate(z = c.x |> v -> v .+ 1)(lazy(t))
    @test occursin("kernel: interpreter (", sprint(io -> explain(io, q2; kernel = true)))
    # the rendered kernel section and code_lowered do not depend on the kernel (rule 13)
    withforce(CF._FORCE_KERNEL => :compiled) do
        @test sprint(io -> code_lowered(io, q)) == withforce(() -> sprint(io -> code_lowered(io, q)), CF._FORCE_KERNEL => :interpreter)
    end
end
