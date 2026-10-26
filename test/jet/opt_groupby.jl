# `@test_opt` on the group-by key and radix hot loops (phase-4 spec §4; p4-groupby, then
# p4-groupby2). Included by runjet.jl, which has loaded Test, JET and ChuiFrames.

@testset "opt: typed keys" begin
    CF = ChuiFrames
    f = [0.0, -0.0, NaN, 1.0]
    m = Union{Missing, Float64}[missing, -0.0, 1.0, NaN]
    s = CF.column(["a", "b", "a", "c"])
    @test_opt target_modules = (CF,) CF._canonkeys(f)
    @test_opt target_modules = (CF,) CF._canonkeys(m)
    @test_opt target_modules = (CF,) CF._canonkeys(s)
    dc = CF.DictColumn(UInt8[1, 2, 0, 1], CF.column([0.0, -0.0]), BitVector([1, 1, 0, 1]))
    @test_opt target_modules = (CF,) CF._dictcodes!(Vector{UInt32}(undef, 4), dc.codes, dc.validity, [1, 1])
    @test_opt target_modules = (CF,) CF._dictvalues!(Vector{Union{Missing, Float64}}(undef, 4), dc.codes, dc.validity, [0.0, 0.0])
    ks = (CF._canonkeys(m), CF._canonkeys(s))
    @test_opt target_modules = (CF,) CF._filltuples!(Vector{Tuple{Union{Missing, Float64}, eltype(s)}}(undef, 4), ks)
end

@testset "opt: keyhash and KeyTable" begin
    CF = ChuiFrames
    @test_opt target_modules = (CF,) CF.keyhash(-0.0)
    @test_opt target_modules = (CF,) CF.keyhash((1.0, missing))
    @test_opt target_modules = (CF,) CF.keyhashes([0.0, 1.0])
    @test_opt target_modules = (CF,) CF.keyhashes([(1.0, "a"), (2.0, "b")])
    t = CF.KeyTable{Float64}(4)
    @test_opt target_modules = (CF,) CF.getorinsert!(t, 1.0, CF.keyhash(1.0))
    @test_opt target_modules = (CF,) CF.lookup(t, 1.0, CF.keyhash(1.0))
    @test_opt target_modules = (CF,) CF.lookup(t, Int32(1), CF.keyhash(Int32(1)))
    @test_opt target_modules = (CF,) CF._grow!(t)
    tm = CF.KeyTable{Union{Missing, Float64}}(4)
    @test_opt target_modules = (CF,) CF.getorinsert!(tm, missing, CF.keyhash(missing))
    tt = CF.KeyTable{Tuple{Union{Missing, Float64}, String}}(4)
    @test_opt target_modules = (CF,) CF.getorinsert!(tt, (1.0, "a"), CF.keyhash((1.0, "a")))
    @test_opt target_modules = (CF,) CF.lookup(tt, (Int32(1), "a"), CF.keyhash((Int32(1), "a")))
    tu = CF.KeyTable{UInt32}(4)
    keys = UInt32[1, 2, 1, 0]
    @test_opt target_modules = (CF,) CF.keyids!(zeros(Int, 4), tu, keys, CF.keyhashes(keys), Int[])
end

@testset "opt: group index on typed keys (p4-groupby2)" begin
    CF = ChuiFrames
    ks = [3, 1, 3, 2, 1]
    @test_opt target_modules = (CF,) CF._groupids(ks)
    @test_opt target_modules = (CF,) CF._groupids([(1, 2.0), (1, 2.0)])
    @test_opt target_modules = (CF,) CF._countsort([1, 2, 1, 3], [2, 1, 3], 3)
    col = CF.column([0.5, -0.0, NaN, 0.5])
    @test_opt target_modules = (CF,) CF._canonvals(col, [1, 2, 3])
    @test_opt target_modules = (CF,) CF._ranks_from_perm([1.0, 2.0, 1.0], [1, 3, 2])
end

@testset "opt: typed accumulators (p4-groupby2)" begin
    CF = ChuiFrames
    UP = CF.Upstream
    ids = [1, 2, 1, 2]
    i8 = CF.column(Int8[1, 2, 3, 4])
    fm = CF.column(Union{Missing, Float64}[1.0, missing, 2.0, 3.0])
    f32 = Float32[1, 2, 3, 4]
    b = CF.column([true, false, true, true])
    s = CF.column(["a", "b", "c", "d"])
    for (agg, col) in (
            (UP.Sum(), i8), (UP.Sum(), fm), (UP.Sum(), f32), (UP.Prod(), i8), (UP.Max(), fm), (UP.Min(), s),
            (UP.Extrema(), f32), (UP.Mean(), i8), (UP.Mean(), fm), (CF.Spread(UP.Moments(false, true)), f32),
            (UP.First(), s), (UP.Last(), fm), (UP.Count(), s), (UP.CountTrue(), b), (UP.AnyM(), b),
            (UP.AllM(), b), (CF.SkipMissingAgg(UP.Sum()), fm), (CF.SkipMissingAgg(UP.Mean()), fm),
        )
        a = CF._newacc(agg, eltype(col))
        CF._grow!(a, 2)
        @test_opt target_modules = (CF,) CF._fold!(a, ids, col)
        d = CF._newacc(agg, eltype(col))
        CF._grow!(d, 2)
        @test_opt target_modules = (CF,) CF._mergeinto!(d, [2, 1], a, [1, 2])
    end
    n = CF._newacc(CF._NRowsAgg(), Any)
    CF._grow!(n, 2)
    @test_opt target_modules = (CF,) CF._fold!(n, ids, nothing)
end

@testset "opt: hash-aggregate sink keys and merge (p4-groupby2)" begin
    CF = ChuiFrames
    t = CF.KeyTable{String}(4)
    sv = CF.column(["a", "b", "a"])
    for i in 1:3
        CF.getorinsert!(t, sv[i], CF.keyhash(sv[i]))
    end
    t2 = CF.KeyTable{String}(4)
    @test_opt target_modules = (CF,) CF._mergekeys!(t2, t, [1, 2], Int[], [1, 2], 0)
    @test_opt target_modules = (CF,) CF._rekey(t, Union{Missing, String})
    dc = CF.DictColumn(UInt8[1, 2, 0, 1], CF.column(["x", "y"]), BitVector([1, 1, 0, 1]))
    @test_opt target_modules = (CF,) CF._presentcodes(zeros(Bool, 2), dc.codes, dc.validity)
    @test_opt target_modules = (CF,) CF._applygmap!(Vector{UInt32}(undef, 4), dc.codes, dc.validity, UInt32[7, 9])
    @test_opt target_modules = (CF,) CF._mapdict!(zeros(UInt32, 2), t, dc.dict, [true, true])
end

@testset "opt: radix_partition" begin
    CF = ChuiFrames
    hs = rand(UInt64, 100)
    @test_opt target_modules = (CF,) CF.radix_partition(hs, 4)
    @test_opt target_modules = (CF,) CF._radix_histogram!(zeros(Int, 16, 1), 1, hs, 1:100, 60)
    @test_opt target_modules = (CF,) CF._radix_scatter!(zeros(Int, 100), ones(Int, 16, 1), 1, hs, 1:100, 60)
end
