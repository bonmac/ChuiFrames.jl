# `@test_opt` on the join's hot loops (phase-4 spec §4; p4-join). Included by runjet.jl, which
# has loaded Test, JET and ChuiFrames. The loops are function barriers over concrete inputs.

@testset "opt: join build and probe loops" begin
    CF = ChuiFrames
    keys = [2, 1, 2, 3, 1]
    t = CF.KeyTable{Int}(5)
    @test_opt target_modules = (CF,) CF._build_table(
        CF.Frame(k = keys), CF.AbstractVector[keys], Type[Int], keys, nothing
    )
    b = CF._build_table(CF.Frame(k = keys), CF.AbstractVector[keys], Type[Int], keys, nothing)
    pk = [1, 2, 9]
    @test_opt target_modules = (CF,) CF._probe_loop!(Int[], Int[], b.table, b.first, b.next, pk, nothing)
    @test_opt target_modules = (CF,) CF._probe_loop!(Int[], Int[], b.table, b.first, b.next, Union{Missing, Int}[1, missing], falses(2))
    @test_opt target_modules = (CF,) CF._probe_ids!(zeros(Int, 3), b.table, pk, nothing)
    @test_opt target_modules = (CF,) CF._sort_by_x([3, 1, 2, 1], 3)
    @test_opt target_modules = (CF,) CF._xpass([1, 1, 3], [10, 20, 30], 3, false, true, :all)
    @test_opt target_modules = (CF,) CF._emit_rows([1, 1, 3], [2, 4, 1], 3, true)
    @test_opt target_modules = (CF,) CF._convfill!(Vector{Union{Missing, Float64}}(undef, 2), Union{Missing, Int}[1, missing])
    @test_opt target_modules = (CF,) CF._marknull!(falses(3), [1.0, NaN, 2.0])
    h = CF.keyhashes(keys)
    @test_opt target_modules = (CF,) CF._partition_pairs!(Int[], Int[], keys, h, [1, 2, 3, 4, 5], nothing, pk, CF.keyhashes(pk), [1, 2, 3], nothing, false)
    @test_opt target_modules = (CF,) CF._fillkeys!(Vector{Int}(undef, 2), [1, 2], [3, 4], [1, 0], [0, 2])
end
