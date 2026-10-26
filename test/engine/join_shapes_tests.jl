# Unit tests of the hash join's cost stage and physical shapes (phase-4 spec
# docs/superpowers/specs/2026-10-26-phase4-joins-groupby-codegen-design.md §1.2): `join_decision`,
# the order-restoring sort, and the (x row, y row) order of each shape.

@testitem "join_decision: build side by estimated bytes, limits, forcing" tags = [:unit] setup = [Force] begin
    CF = ChuiFrames
    SE = CF.SideEstimate
    s = inner_join(Frame(k = [1]); by = :k)
    I = Type[Int]
    # the side with fewer estimated bytes builds; a tie builds on y
    @test CF.join_decision(s, SE(10, true, I), SE(100, true, I))[1:2] == (:broadcast, :x)
    @test CF.join_decision(s, SE(100, true, I), SE(10, true, I))[1:2] == (:broadcast, :y)
    @test CF.join_decision(s, SE(10, true, I), SE(10, true, I))[1:2] == (:broadcast, :y)
    # bytes, not rows: 10 rows of 4 Ints (320 bytes) against 30 rows of one Int8 (30 bytes)
    @test CF.join_decision(s, SE(10, true, Type[Int, Int, Int, Int]), SE(30, true, Type[Int8]))[2] === :y
    # unknown counts as larger; both unknown -> y
    @test CF.join_decision(s, SE(nothing, false, I), SE(100, true, I))[2] === :y
    @test CF.join_decision(s, SE(100, true, I), SE(nothing, false, I))[2] === :x
    @test CF.join_decision(s, SE(100, true, nothing), SE(1000, true, I))[2] === :y
    @test CF.join_decision(s, SE(nothing, false, nothing), SE(nothing, false, nothing))[2] === :y
    # a nested column (a nest_join output) has no width: unknown bytes
    @test CF.join_decision(s, SE(1, true, Type[Int, Frame]), SE(1000, true, I))[2] === :y
    @test CF.join_decision(s, SE(1, true, Type[Vector{Int}]), SE(1000, true, I))[2] === :y
    # the broadcast limits: rows, then bytes
    @test CF.join_decision(s, SE(10^7, true, I), SE(CF.BROADCAST_MAX_ROWS - 1, true, Type[Int8]))[1] === :broadcast
    @test CF.join_decision(s, SE(10^7, true, I), SE(CF.BROADCAST_MAX_ROWS, true, Type[Int8]))[1] === :partitioned
    @test CF.join_decision(s, SE(10^7, true, I), SE(100_000, true, Type[Int, Int, Int, Int, Int, Int]))[1] === :partitioned
    @test CF.join_decision(s, SE(nothing, false, nothing), SE(nothing, false, nothing))[1] === :partitioned
    # p from the larger side's rows, within 4-8
    @test CF.join_decision(s, SE(10^7, true, I), SE(10^6, true, I))[3] in 4:8
    @test CF.join_decision(s, SE(10, true, I), SE(10, true, I))[3] == 4
    # the forced values
    for (v, want) in ((:broadcast_x, (:broadcast, :x)), (:broadcast_y, (:broadcast, :y)), (:partitioned_x, (:partitioned, :x)), (:partitioned_y, (:partitioned, :y)))
        d = withforce(() -> CF.join_decision(s, SE(10, true, I), SE(10^7, true, I)), CF._FORCE_JOIN => v)
        @test d[1:2] == want
        @test d[4] == "forced by _FORCE_JOIN"
    end
    @test_throws ArgumentError withforce(() -> CF.join_decision(s, SE(1, true, I), SE(1, true, I)), CF._FORCE_JOIN => :nope)
end

@testitem "join: the order-restoring sort and the shapes' pair order" tags = [:unit] begin
    CF = ChuiFrames
    # the counting sort is stable
    px = [3, 1, 2, 1, 3, 3]
    perm = CF._sort_by_x(px, 3)
    @test px[perm] == [1, 1, 2, 3, 3, 3]
    @test perm == [2, 4, 3, 1, 5, 6]
    @test CF._sort_by_x(Int[], 0) == Int[]
    # shape (a): probing x against y's table gives pairs already in (x row, y row) order
    x = Frame(k = [2, 1, 2, 3, 1])
    y = Frame(k = [1, 2, 1, 2, 2])
    names = CF._resolve_names(inner_join(y; by = :k), x.names, y.names)
    b = CF.JoinBuild(y, [:k], Type[Int], false)
    xconv = CF._convkeys(x, [:k], Type[Int])
    pk = CF._join_typed_keys(xconv, x.nrow, [:k])
    pxa, pya = CF._probe_pairs(b, pk, nothing)
    @test issorted(collect(zip(pxa, pya)))
    @test length(pxa) == 2 * 3 + 2 * 2 + 0
    # shape (b): probing y against x's table gives y order; the sort restores (x row, y row)
    bx = CF.JoinBuild(x, [:k], Type[Int], false)
    yk = CF._join_typed_keys(CF._convkeys(y, [:k], Type[Int]), y.nrow, [:k])
    pyb, pxb = CF._probe_pairs(bx, yk, nothing)
    @test !issorted(collect(zip(pxb, pyb)))
    perm = CF._sort_by_x(pxb, x.nrow)
    @test collect(zip(pxb[perm], pyb[perm])) == collect(zip(pxa, pya))
    # every shape gives the same rows; unmatched y rows come last, in y order
    yy = Frame(k = [9, 1, 2, 8, 1], w = 1:5)
    want = full_join(yy; by = :k)(x)
    @test ChuiFrames.getcol(want, :w)[(end - 1):end] == [1, 4]
end

@testitem "join: the multi-task partitioned path on large inputs (slow)" tags = [:slow] setup = [Force] begin
    # 90k x rows against 70k y rows: nx + ny >= 65_536, so with threads the partitioned shape
    # splits the partitions over several tasks. Every shape must give the same rows and types.
    # Run with `julia -t 4 scripts/ci.jl test -- slow`.
    Threads.nthreads() > 1 || @info "single thread: the partitioned join runs one task here"
    nx, ny = 90_000, 70_000
    x = Frame(k = [mod(i * 7919, 50_000) for i in 1:nx], a = collect(1:nx))
    y = Frame(k = Union{Missing, Int}[i % 13 == 0 ? missing : mod(i * 104_729, 60_000) for i in 1:ny], b = collect(1:ny))
    for verb in (inner_join, left_join, full_join, semi_join, anti_join)
        j = verb(y; by = :k)
        want = withforce(() -> j(x), ChuiFrames._FORCE_JOIN => :broadcast_y)
        for v in (:partitioned_x, :partitioned_y, :broadcast_x)
            got = withforce(() -> j(x), ChuiFrames._FORCE_JOIN => v)
            @test isequal(got, want)
            @test [eltype(c) for c in got.columns] == [eltype(c) for c in want.columns]
        end
        lazygot = withforce(() -> collect(j(lazy(x)); morsel = 4096), ChuiFrames._FORCE_JOIN => :partitioned_y)
        @test isequal(lazygot, want)
    end
end

@testitem "join: x-side pass and multiple on sorted pairs" tags = [:unit] begin
    CF = ChuiFrames
    px = [1, 1, 3, 3, 3]
    py = [10, 20, 30, 40, 50]
    @test CF._xpass(px, py, 3, false, true, :all) == ([1, 1, 2, 3, 3, 3], [10, 20, 0, 30, 40, 50])
    @test CF._xpass(px, py, 3, false, false, :first) == ([1, 3], [10, 30])
    @test CF._xpass(px, py, 3, false, false, :last) == ([1, 3], [20, 50])
    @test CF._xpass(px, py, 3, false, true, :any) == ([1, 2, 3], [10, 0, 30])
    err = try
        CF._xpass(px, py, 3, true, false, :all)
    catch e
        e
    end
    @test err isa ArgumentError && occursin("Row 2 of `x` does not have a match", err.msg)
    err = try
        CF._xpass(px, py, 3, true, false, :error)
    catch e
        e
    end
    @test err isa ArgumentError && occursin("Row 1 of `x` matches multiple rows", err.msg)
end
