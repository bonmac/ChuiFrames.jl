# The grouped-window sink (phase-4 spec §2.1, plan task 6): a grouped `mutate` after the gather
# runs `apply(::MutateStep)` on sub-frames of contiguous group ranges (in parallel when threads >
# 1) and scatters the results back in row order. Same names, grouping, column kinds, element types
# and values as eager.

@testsnippet WS begin
    using Tables, Statistics
    const ⨟ = ChuiFrames.Upstream.:⨟
    const CF = ChuiFrames
    function outcome(f)
        try
            return (:ok, f())
        catch err
            return (:err, typeof(err))
        end
    end
    function identical(a, b)
        a.names == b.names && a.nrow == b.nrow && a.groups == b.groups && a.drop == b.drop || return false
        for (ca, cb) in zip(a.columns, b.columns)
            typeof(ca) == typeof(cb) || return false
            all(i -> isequal(ca[i], cb[i]), eachindex(ca)) || return false
        end
        return true
    end
    lv = CF.column(["b", "a", "zz", "c"])
    fr = Frame(
        g = ["a", "b", "a", "c", "b", "a", "c", "a", "d"],
        k = [1, 2, 1, 2, 1, 2, 1, 2, 2],
        x = Union{Missing, Float64}[1.5, NaN, -0.0, missing, 0.0, 2.5, -1.0, 4.0, 3.0],
        y = [3, -1, 4, 1, -5, 9, 2, 6, 0],
        d = CF.DictColumn(UInt8[1, 2, 1, 4, 2, 1, 4, 2, 1], lv),
        s = ["p", "q", "r", "s", "t", "u", "v", "w", "x"],
    )
    MUTATES = Any[
        mutate(cs = cumsum(c.y), r = row_number()),
        mutate(w = c.y .- mean(c.y), n = n_rows()),
        mutate(l = lag(c.x), m = maximum(c.y)),
        mutate(rk = min_rank(c.y), z = c.y .* 2),             # a window and a row-wise output
        mutate(y = c.y .- minimum(c.y), t = c.y .+ 1),        # replaces a column, then reads it
        mutate(e = c.d, cm = cummean(c.y)),                   # a dictionary column passed through
        mutate(cs = cumsum(c.y); keep = :used),
        mutate(cs = cumsum(c.y); before = :g),
        mutate(q = c.y |> v -> v .- first(v)),
        mutate(mx = maximum(skipmissing(c.x))),                # raises on the all-missing group
        mutate(cs = cumsum(c.y), g2 = nothing, s = nothing),
    ]
end

@testitem "grouped-window sink: equals eager mutate over any split into group ranges" tags = [:unit] setup = [WS] begin
    inputs = Any[
        group_by(:g)(fr), group_by(:g, :k)(fr), group_by(:d)(fr), group_by(:d; drop = false)(fr),
        group_by(:k)(fr), group_by(:g)(CF.take(fr, Int[])),
    ]
    for f in inputs, s in MUTATES, nr in 1:5
        e = outcome(() -> CF.apply(s, f))
        w = outcome(() -> CF._window_apply(s, f, nr))
        @test e[1] === w[1]
        e[1] === :ok && w[1] === :ok && @test identical(e[2], w[2])
    end
    # mutate(...; by): grouped for the call, ungrouped result
    for s in (mutate(cs = cumsum(c.y); by = :g), mutate(w = c.y .- mean(c.y); by = [:g, :k])), nr in (2, 3)
        @test identical(CF.apply(s, fr), CF._window_apply(s, fr, nr))
    end
end

@testitem "grouped-window sink: lazy == eager, and explain says so" tags = [:unit] setup = [WS] begin
    for s in MUTATES, gb in (group_by(:g), group_by(:d; drop = false))
        p = gb ⨟ s
        e = outcome(() -> p(fr))
        for m in (1, 2, 4), th in (true, false)
            l = outcome(() -> collect(p(lazy(fr)); morsel = m, threads = th))
            @test e[1] === l[1]
            e[1] === :ok && l[1] === :ok && @test identical(e[2], l[2])
            e[1] === :err && l[1] === :err && @test e[2] === l[2]
        end
    end
    s = sprint(explain, (group_by(:g) ⨟ mutate(cs = cumsum(c.y)))(lazy(fr)))
    @test occursin("grouped-window sink", s)
    @test occursin("grouped-window sink", sprint(explain, mutate(cs = cumsum(c.y); by = :g)(lazy(fr))))
    @test !occursin("grouped-window sink", sprint(explain, mutate(cs = cumsum(c.y))(lazy(fr))))
end

@testitem "grouped-window sink behind a forced compiled stage kernel (spec §0.3, §3)" tags = [:unit] setup = [WS, Force, CompiledRan] begin
    # a streamed stage (mutates, a filter on a computed column) runs compiled on every morsel
    # before the gather; the grouped window then runs on the gathered frame
    pres = Any[
        mutate(z = c.y .* 2),
        mutate(z = c.y .+ 1) ⨟ filter(c.z .> 0),
        mutate(z = c.y .- 1, xx = c.x .* 2.0),
    ]
    d0 = CF._KERNEL_DISAGREE[]
    for pre in pres
        @test compiled_ran(pre(lazy(fr)))                  # a compiled program ran on the morsels
        for s in MUTATES, gb in (group_by(:g), group_by(:d; drop = false))
            p = pre ⨟ gb ⨟ s
            e = outcome(() -> p(fr))
            for m in (1, 4), th in (true, false)
                l = withforce(CF._FORCE_KERNEL => :compiled) do
                    outcome(() -> collect(p(lazy(fr)); morsel = m, threads = th))
                end
                @test e[1] === l[1]
                e[1] === :ok && l[1] === :ok && @test identical(e[2], l[2])
                e[1] === :err && l[1] === :err && @test e[2] === l[2]
            end
        end
    end
    @test CF._KERNEL_DISAGREE[] - d0 == 0                  # critic n7
end
