# The eager group index on typed keys (phase-4 spec §2.1, plan task 3; ADR-0003 rules 3, 8):
# `build_gindex` gives the same index as the phase-3 `Dict`-coded construction (kept as
# `_build_gindex_dict`, the fallback for abstract key types), and allocates per group, not per row.

@testsnippet GI begin
    using Random: Xoshiro, rand
    const CF = ChuiFrames
    # same ids, perm, starts and key values (isequal, and identical bits for floats: the
    # first-seen ±0.0 and NaN payloads are kept)
    bitsame(a, b) = a === b || (ismissing(a) && ismissing(b)) || isequal(a, b) && typeof(a) == typeof(b) &&
        (!(a isa AbstractFloat) || reinterpret(Unsigned, a) == reinterpret(Unsigned, b))
    function same_index(g1, g2)
        g1.ids == g2.ids && g1.perm == g2.perm && g1.starts == g2.starts || return false
        length(g1.keys) == length(g2.keys) || return false
        for (a, b) in zip(g1.keys, g2.keys)
            typeof(a) == typeof(b) || return false
            all(i -> bitsame(a[i], b[i]), eachindex(a)) || return false
        end
        return true
    end
    const XS = Union{Missing, Float64}[0.0, -0.0, NaN, -NaN, 1.5, -2.0, Inf, missing]
    function randframe(rng, n)
        lv = ["a", "b", "c", "zz"]
        return Frame(
            i = rand(rng, -2:2, n),
            x = Union{Missing, Float64}[rand(rng, XS) for _ in 1:n],
            s = [rand(rng, ["p", "q", "r", ""]) for _ in 1:n],
            d = CF.DictColumn(UInt8[rand(rng, 1:3) for _ in 1:n], CF.column(lv)),
            dz = CF.DictColumn(UInt8[rand(rng, 1:2) for _ in 1:n], CF.column([0.0, -0.0]), BitVector(rand(rng, Bool, n))),
            b = rand(rng, Bool, n),
            a = Any[rand(rng, (1, 2.0, "s")) for _ in 1:n],
        )
    end
end

@testitem "build_gindex on typed keys equals the Dict-coded index" tags = [:unit] setup = [GI] begin
    rng = Xoshiro(20261026)
    keysets = [[:i], [:x], [:s], [:d], [:dz], [:b], [:a], [:i, :x], [:s, :d], [:x, :dz, :b], [:a, :i], Symbol[]]
    for n in (0, 1, 2, 7, 40, 300), ks in keysets
        f = randframe(rng, n)
        g = CF.build_gindex(f, ks)
        r = CF._build_gindex_dict(f, ks)
        @test same_index(g, r)
    end
    # ±0.0: one group, shown as the first seen in row order; NaN payloads one group
    f = Frame(x = [-0.0, 0.0, NaN, -NaN, 1.0])
    g = CF.build_gindex(f, [:x])
    @test g.starts == [1, 3, 4, 6] && g.keys[1][1] === -0.0 && isnan(g.keys[1][3])
    f = Frame(x = [0.0, -0.0], y = [1, 1])
    @test CF.build_gindex(f, [:x, :y]).keys[1][1] === 0.0
end

@testitem "build_gindex allocates per group, not per row" tags = [:unit] setup = [GI] begin
    n = 10_000
    f = Frame(k = [mod(i * 7, 10) for i in 1:n], s = [string("s", mod(i, 10)) for i in 1:n])
    CF.build_gindex(f, [:k]); CF.build_gindex(f, [:s]); CF.build_gindex(f, [:k, :s])   # compile
    @test (@allocations CF.build_gindex(f, [:k])) < 500
    @test (@allocations CF.build_gindex(f, [:s])) < 500
    @test (@allocations CF.build_gindex(f, [:k, :s])) < 500
end
