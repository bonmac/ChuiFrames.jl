# `radix_partition` (phase-4 spec §2.4, frozen API; ADR-0003 rules 6 and 10).

@testitem "radix_partition: top bits, offsets, stable order" tags = [:unit] begin
    using ChuiFrames: radix_partition
    hs = UInt64[
        0xf000000000000001, 0x0000000000000002, 0x8000000000000003, 0x0fffffffffffffff,
        0xf000000000000000, 0x7000000000000000, 0x0000000000000001,
    ]
    offsets, perm = radix_partition(hs, 1)
    @test offsets == [1, 5, 8]                      # 2^1 + 1 entries; partition 1 = top bit 0
    @test perm == [2, 4, 6, 7, 1, 3, 5]             # ascending index order within each partition
    offsets, perm = radix_partition(hs, 4)
    @test length(offsets) == 17 && offsets[1] == 1 && offsets[end] == 8
    for j in 1:16, i in perm[offsets[j]:(offsets[j + 1] - 1)]
        @test Int(hs[i] >> 60) + 1 == j
    end
    @test perm[offsets[16]:(offsets[17] - 1)] == [1, 5]
    # p = 0: one partition, the identity
    @test radix_partition(hs, 0) == ([1, 8], collect(1:7))
    # empty input
    @test radix_partition(UInt64[], 3) == (ones(Int, 9), Int[])
    # several tasks give the same answer, also with more tasks than elements
    for nt in (2, 3, 7, 20)
        @test radix_partition(hs, 4; ntasks = nt) == radix_partition(hs, 4)
    end
    @test_throws ArgumentError radix_partition(hs, -1)
    @test_throws ArgumentError radix_partition(hs, 64)
    @test_throws ArgumentError radix_partition(hs, 2; ntasks = 0)
    # any AbstractVector{UInt64}
    @test radix_partition(view(hs, 2:5), 1) == ([1, 3, 5], [1, 3, 2, 4])
end

@testitem "radix_partition: permutation and stability property" tags = [:property] begin
    using ChuiFrames: radix_partition
    using Supposition, Supposition.Data
    function ok(hs, p, nt)
        offsets, perm = radix_partition(hs, p; ntasks = nt)
        n = length(hs)
        length(offsets) == 2^p + 1 || return false
        offsets[1] == 1 && offsets[end] == n + 1 && issorted(offsets) || return false
        sort(perm) == 1:n || return false                       # a permutation
        for j in 1:(2^p)
            part = perm[offsets[j]:(offsets[j + 1] - 1)]
            issorted(part; lt = <) || return false              # stable: ascending index order
            all(i -> Int(hs[i] >> (64 - p)) + 1 == j, part) || return false
        end
        return true
    end
    # random hashes, and hashes squeezed into few top-bit values (many equal partitions)
    hgen = Data.Vectors(Data.Integers{UInt64}(); max_size = 60)
    lowgen = map(v -> UInt64.(v) .<< 61, Data.Vectors(Data.Integers(0, 7); max_size = 60))
    sr = @check record = false db = false max_examples = 300 ok(hgen, Data.Integers(0, 6), Data.Integers(1, 5))
    @test Supposition.results(sr).ispass
    sr = @check record = false db = false max_examples = 300 ok(lowgen, Data.Integers(0, 4), Data.Integers(1, 9))
    @test Supposition.results(sr).ispass
end
