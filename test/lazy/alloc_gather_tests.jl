# Allocation tests (load-independent: bytes, never time) of the lazy gather's concatenation
# (docs/research/performance-phase4.md P4-02): `vcat_columns` over many morsels must allocate
# linearly in the payload. A left fold over a generator (`reduce(vcat, <generator>)`) copies the
# growing prefix once per morsel, about (morsels / 2) x the payload.

@testitem "vcat_columns: many chunks allocate linearly (primitive, nullable, dictionary)" tags = [:unit] begin
    CF = ChuiFrames
    bytes(f) = (f(); f(); @allocated f())
    nch, len = 1000, 64
    payload = nch * len * 8                 # 512 KiB of Float64; the quadratic fold ~ 500x
    P = [CF.column(rand(len)) for _ in 1:nch]
    N = [CF.column(Union{Missing, Float64}[isodd(i) ? missing : 1.0 for i in 1:len]) for _ in 1:nch]
    dict = CF.column(["a", "b", "c"])
    D = [CF.DictColumn(UInt32.(rand(1:3, len)), dict) for _ in 1:nch]
    @test bytes(() -> CF.vcat_columns(P)) < 20 * payload
    @test bytes(() -> CF.vcat_columns(N)) < 20 * payload
    @test bytes(() -> CF.vcat_columns(D)) < 20 * payload
    # doubling the chunks about doubles the bytes (quadratic would quadruple them)
    P2 = [P; P]
    @test bytes(() -> CF.vcat_columns(P2)) < 3 * bytes(() -> CF.vcat_columns(P))
    # same values, kinds and validity as before
    v = CF.vcat_columns(N)
    @test isequal(collect(v), reduce(vcat, [collect(c) for c in N]))
    @test CF.validity(v) == reduce(vcat, [CF.validity(c) for c in N])
    @test collect(CF.vcat_columns(P)) == reduce(vcat, [collect(c) for c in P])
    d = CF.vcat_columns(D)
    @test d isa CF.DictColumn && d.dict === dict
    @test collect(d) == reduce(vcat, [collect(c) for c in D])
end

@testitem "lazy gather of many morsels allocates linearly" tags = [:unit] begin
    bytes(f) = (f(); f(); @allocated f())
    nm, len = 1000, 64
    n = nm * len
    payload = n * 8
    f = Frame((x = rand(n), y = collect(1:n)))
    g() = collect(lazy(f); morsel = len, threads = false)
    @test bytes(g) < 30 * payload           # was ~550x (P4-02)
    col(t, n) = collect(ChuiFrames.getcol(t, n))
    @test col(g(), :x) == col(f, :x)
    @test col(g(), :y) == col(f, :y)
end
