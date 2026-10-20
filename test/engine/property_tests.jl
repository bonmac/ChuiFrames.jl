# Random pipelines (filter, mutate, group_by, summarise, arrange) over data with NaN, -NaN, ±0.0,
# missing and empty groups, compared with the independent oracle (ADR-0003 "Testing").
# Supposition: `@check record=false db=false` plus an explicit `@test` on the result.

@testsnippet PropGen begin
    using Supposition, Supposition.Data
    using Statistics
    const KV = Union{Missing, Float64}[NaN, -NaN, 0.0, -0.0, 1.0, missing]
    const XV = Union{Missing, Float64}[1.5, -2.0, 0.0, -0.0, NaN, -NaN, 3.25, missing]
    const N = 7
    tablegen = @composed function table(
            n = Data.Integers(0, N),
            g = Data.Vectors(Data.SampledFrom(["a", "b", "c"]); min_size = N, max_size = N),
            k = Data.Vectors(Data.SampledFrom(KV); min_size = N, max_size = N),
            x = Data.Vectors(Data.SampledFrom(XV); min_size = N, max_size = N),
            y = Data.Vectors(Data.Integers(-3, 3); min_size = N, max_size = N),
        )
        (g = g[1:n], k = Union{Missing, Float64}[k[1:n]...], x = Union{Missing, Float64}[x[1:n]...], y = y[1:n])
    end
    # row-preserving steps (the specs drive both the engine and the oracle)
    const STEPS = [
        (:filter, c.x .> 0.5),
        (:filter, .!(c.x .> 0.5)),
        (:filter, c.y .>= 0),
        (:filter, c.y .> mean(c.y)),
        (:mutate, :z, c.x .* 2),
        (:mutate, :w, c.y .- mean(c.y)),
        (:mutate, :x, c.x .+ 1),
        (:group, [:k]),
        (:group, [:g, :k]),
        (:ungroup,),
        (:arrange, [c.x]),
        (:arrange, [desc(c.x), c.y]),
        (:arrange, [desc(c.k), c.g]),
    ]
    const FINAL = [
        nothing,
        (:summarise, Pair{Symbol, Any}[:n => n_rows(), :s => sum(c.y), :m => mean(c.y)]),
        (:summarise, Pair{Symbol, Any}[:mx => maximum(c.y), :sx => sum(skipmissing(c.x))]),
    ]
    const PRE = [nothing, (:group, [:k]), (:group, [:g, :k]), (:group, [:g])]
    stepsgen = Data.Vectors(Data.Integers(1, length(STEPS)); max_size = 4)
    finalgen = Data.Integers(1, length(FINAL))
    pregen = Data.Integers(1, length(PRE))
    function specs_of(pre, idx, fin)
        specs = Any[]
        PRE[pre] === nothing || push!(specs, PRE[pre])
        append!(specs, [STEPS[i] for i in idx])
        FINAL[fin] === nothing || push!(specs, FINAL[fin])
        return specs
    end
    function outcome(f)
        try
            return (:ok, f())
        catch err
            return (:err, typeof(err))
        end
    end
end

@testitem "property: eager engine == row-loop oracle on random pipelines" tags = [:property] setup = [PropGen, Oracle] begin
    using ChuiFrames: Upstream
    function agrees(t, pre, idx, fin)
        specs = specs_of(pre, idx, fin)
        pipe = isempty(specs) ? nothing : foldl(Upstream.:⨟, [Oracle.step(s) for s in specs])
        e = outcome(() -> pipe === nothing ? ChuiFrames.Frame(t) : pipe(t))
        o = outcome(() -> Oracle.run(Oracle.OTable(t), specs))
        e[1] === o[1] || return false
        e[1] === :err && return e[2] === o[2]           # same exception type
        return Oracle.agree(e[2], o[2])
    end
    r = @check record = false db = false max_examples = 500 agrees(tablegen, pregen, stepsgen, finalgen)
    @test Supposition.results(r).ispass
end

@testitem "property: group index invariants" tags = [:property] setup = [PropGen, Oracle] begin
    function inv(t)
        f = group_by(:g, :k)(t)
        gi = ChuiFrames.gindex(f)
        n = length(t.g)
        ng = ChuiFrames.ngroups(gi)
        sort(gi.perm) == 1:n || return false
        all(1 <= gi.ids[r] <= ng for r in 1:n) || return false
        # rows of a group are in row order and share a key under rule 8's equality
        for g in 1:ng
            rows = ChuiFrames.group_rows(gi, g)
            issorted(rows) || return false
            all(Oracle.keyeq(t.k[r], t.k[rows[1]]) && t.g[r] == t.g[rows[1]] for r in rows) || return false
        end
        # same number of groups as the oracle
        return ng == length(filter(!isempty, Oracle.groups(Oracle.OTable((g = t.g, k = t.k)) |> o -> Oracle.OTable(o.cols, [:g, :k]))))
    end
    r = @check record = false db = false max_examples = 300 inv(tablegen)
    @test Supposition.results(r).ispass
end
