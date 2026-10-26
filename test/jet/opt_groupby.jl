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

@testset "opt: radix_partition" begin
    CF = ChuiFrames
    hs = rand(UInt64, 100)
    @test_opt target_modules = (CF,) CF.radix_partition(hs, 4)
    @test_opt target_modules = (CF,) CF._radix_histogram!(zeros(Int, 16, 1), 1, hs, 1:100, 60)
    @test_opt target_modules = (CF,) CF._radix_scatter!(zeros(Int, 100), ones(Int, 16, 1), 1, hs, 1:100, 60)
end
