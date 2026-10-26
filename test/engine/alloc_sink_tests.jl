# Allocation tests (load-independent: counts and bytes, never time) of the String-key lazy
# group-by (docs/research/performance-phase4.md P4-05: one allocation per row). The per-row
# allocation is in the frame source's morsel slicing, `take(::StringColumn, idx)`: its row
# generator yields `Union{Nothing, view}` items, boxed once per row.

@testitem "take(::StringColumn): no allocation per row; same column" tags = [:unit] begin
    CF = ChuiFrames
    n = 100_000
    c = CF.column(string.("s", rand(1:10, n)))
    idx = collect(1:n)
    t() = CF.take(c, idx)
    t(); t()
    @test (@allocations t()) < 100
    @test (@allocated t()) < 4 * (n * 4 + sizeof(c.data))   # offsets and bytes, a few times over
    # values, offsets type and validity as before: nulls, the 0 index (a null slot), empty strings
    m = CF.column(Union{Missing, String}["a", missing, "", "ccc", missing, "dd"])
    for ix in ([1, 2, 3, 4, 5, 6], [6, 0, 1, 2], Int[], [3, 3, 0], [4])
        r = CF.take(m, ix)
        @test r isa CF.StringColumn
        @test isequal(collect(r), [i == 0 ? missing : m[i] for i in ix])
        @test CF.validity(r) == BitVector([i != 0 && !ismissing(m[i]) for i in ix])
        @test eltype(r.offsets) === Int32
    end
    p = CF.column(["x", "", "yz"])
    r = CF.take(p, [3, 1, 2])
    @test CF.validity(r) === nothing
    @test collect(r) == ["yz", "x", ""]
    r0 = CF.take(p, [0, 1])
    @test isequal(collect(r0), [missing, "x"])
    @test CF.validity(r0) == BitVector([false, true])
    # Int64 offsets in: Int32 offsets out (as before)
    w = CF.StringColumn(Int64[0, 1, 3], Vector{UInt8}("abc"))
    @test eltype(CF.take(w, [2, 1]).offsets) === Int32
    @test collect(CF.take(w, [2, 1])) == ["bc", "a"]
end

@testitem "lazy String-key group-by: allocations do not grow per row" tags = [:unit] begin
    n = 200_000
    f = Frame((x = rand(n), s = string.("s", rand(1:10, n))))
    q() = collect(lazy(f) |> group_by(:s) |> summarise(sx = sum(c.x), cnt = n_rows()); threads = false)
    q(); q()
    @test (@allocations q()) < n ÷ 50       # was ~1 per row (P4-05)
    e = f |> group_by(:s) |> summarise(sx = sum(c.x), cnt = n_rows())
    col(t, c) = collect(ChuiFrames.getcol(t, c))
    l = q()
    @test col(l, :s) == col(e, :s)
    @test col(l, :cnt) == col(e, :cnt)
    @test col(l, :sx) ≈ col(e, :sx)
end
