# Allocation tests (load-independent: bytes, never time) of the concatenations of per-partition,
# per-frame and per-group pieces (docs/research/performance-phase4.md P4-02): `reduce(vcat, xs;
# init = ...)` folds left (the `init` keyword disables Base's preallocating method), copying the
# growing prefix once per piece; these must allocate linearly in the payload.

@testitem "partitioned join: concatenating the partitions' pairs is linear" tags = [:unit] begin
    CF = ChuiFrames
    bytes(f) = (f(); f(); @allocated f())
    n = 20_000
    x = Frame((k = collect(1:n), a = rand(n)))
    y = Frame((k = collect(n:-1:1), b = rand(n)))
    s = inner_join(y; by = :k)
    nm = CF._resolve_names(s, x.names, y.names; log = false)
    T = CF._join_compare_types(nm, x, y)
    pj(p) = CF._partitioned_join(s, nm, x, y, T, :y, p, false)
    # 2^10 partitions: the fold copied ~512 x the pairs (~1150 x n Ints); 2^4 costs ~48 x n Ints
    @test bytes(() -> pj(10)) < 120 * n * 8
    @test bytes(() -> pj(10)) < 2 * bytes(() -> pj(4))
    col(t, c) = collect(CF.getcol(t, c))
    out = pj(10)
    @test col(out, :k) == collect(1:n)
    @test col(out, :b) == reverse(col(y, :b))
    @test out.names == CF._join_frames(s, nm, x, y).names
end

@testitem "bind_rows(...; id): the id column concatenates linearly" tags = [:unit] begin
    bytes(f) = (f(); f(); @allocated f())
    nf, len = 1000, 64
    fs = [Frame((a = rand(len),)) for _ in 1:nf]
    b() = fs[1] |> bind_rows(fs[2:end]...; id = :src)
    payload = nf * len * 8
    @test bytes(b) < 30 * payload           # was ~1000x (both the id and the a column folds)
    col(t, c) = collect(ChuiFrames.getcol(t, c))
    out = b()
    @test out.names == [:src, :a]
    @test col(out, :src) == repeat(1:nf; inner = len)
    @test col(out, :a) == reduce(vcat, [col(f, :a) for f in fs])
    # named tables give String ids
    nb = Frame((a = [1],)) |> bind_rows("p" => Frame((a = [2, 3],)), "q" => Frame((a = Int[],)); id = :src)
    @test col(nb, :src) == ["1", "p", "p"]
end

@testitem "reframe: the key rows concatenate linearly" tags = [:unit] begin
    bytes(f) = (f(); f(); @allocated f())
    G, len = 1000, 64
    g = Frame((k = repeat(1:G; inner = len), v = rand(G * len)))
    r() = g |> group_by(:k) |> reframe(w = c.v)
    payload = G * len * 8
    @test bytes(r) < 60 * payload           # the key-row fold alone was ~500x
    col(t, c) = collect(ChuiFrames.getcol(t, c))
    out = r()
    @test col(out, :k) == repeat(1:G; inner = len)
    @test col(out, :w) == col(g, :v)
    # groups of different lengths, in key order
    h = Frame((k = [3, 1, 1, 2, 3, 3], v = [1, 2, 3, 4, 5, 6]))
    o = h |> group_by(:k) |> reframe(w = c.v)
    @test col(o, :k) == [1, 1, 2, 3, 3, 3]
    @test col(o, :w) == [2, 3, 4, 1, 5, 6]
end
