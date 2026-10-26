# gen_data.jl: db-benchmark-like inputs (h2oai/db-benchmark, groupby-datagen.R and
# join-datagen.R, re-created from their published column definitions, not their code) written
# as Arrow IPC files that every tool in benchmark/compare/ reads.
#
#   julia --project=<env with ChuiFrames> benchmark/compare/gen_data.jl OUTDIR N
#
# Group-by table G1 (N rows, K = 100):
#   id1, id2  String, K levels "id001".."id100"     id3  String, N ÷ K levels "id0000000001".."
#   id4, id5  Int in 1:K                           id6  Int in 1:N ÷ K
#   v1 Int in 1:5, v2 Int in 1:15, v3 Float64 uniform [0, 100) rounded to 6 digits
# Join tables: x (N rows): id1 Int in 1:⌈1.1·N/10^6⌉, id2 Int in 1:⌈1.1·N/10^3⌉, id4 String
# ("id" * id1), v1 Float64; small (N ÷ 10^6 rows, id1 = 1:N÷10^6 distinct, id4, v2); medium
# (N ÷ 10^3 rows, id1, id2 = 1:N÷10^3 distinct, id4, v2). About 90 % of x's rows match.
using ChuiFrames
using Random: Xoshiro, rand, randperm

function main(outdir, N)
    mkpath(outdir)
    rng = Xoshiro(20261026)
    K = 100
    nk = max(N ÷ K, 1)
    lv = [string("id", lpad(i, 3, '0')) for i in 1:K]
    lv3 = [string("id", lpad(i, 10, '0')) for i in 1:nk]
    g1 = Frame(
        (
            id1 = lv[rand(rng, 1:K, N)], id2 = lv[rand(rng, 1:K, N)], id3 = lv3[rand(rng, 1:nk, N)],
            id4 = rand(rng, 1:K, N), id5 = rand(rng, 1:K, N), id6 = rand(rng, 1:nk, N),
            v1 = rand(rng, 1:5, N), v2 = rand(rng, 1:15, N), v3 = round.(100 .* rand(rng, N); digits = 6),
        )
    )
    write_arrow(g1, joinpath(outdir, "G1.arrow"))
    ns, nm = max(N ÷ 10^6, 1), max(N ÷ 10^3, 1)
    id1 = rand(rng, 1:ceil(Int, 1.1 * ns), N)
    x = Frame((id1 = id1, id2 = rand(rng, 1:ceil(Int, 1.1 * nm), N), id4 = string.("id", id1), v1 = 100 .* rand(rng, N)))
    s1 = randperm(rng, ns)
    small = Frame((id1 = s1, id4 = string.("id", s1), v2 = 100 .* rand(rng, ns)))
    m2 = randperm(rng, nm)
    medium = Frame((id1 = rand(rng, 1:ns, nm), id2 = m2, id4 = string.("id", m2), v2 = 100 .* rand(rng, nm)))
    write_arrow(x, joinpath(outdir, "X.arrow"))
    write_arrow(small, joinpath(outdir, "SMALL.arrow"))
    write_arrow(medium, joinpath(outdir, "MEDIUM.arrow"))
    println("gen_data.jl: N = ", N, " → ", outdir)
    return nothing
end

main(ARGS[1], parse(Int, ARGS[2]))
