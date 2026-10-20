# The lazy engine over the built-in file sources (spec §4-6; ADR-0004 rules 1-4; ADR-0021
# rule 11): pushdown, row-group pruning on exact Parquet timestamp statistics, CSV chunks.

@testitem "lazy: Parquet row groups pruned by exact timestamp statistics (ADR-0021 rule 11)" tags = [:unit] begin
    using ChuiFrames, Tables, Dates, Parquet2
    const ⨟ = ChuiFrames.Upstream.:⨟
    eq(a, b) = isequal(Tables.columntable(a), Tables.columntable(b))
    # pyarrow-written fixture (test/io/data/README.md): 3 row groups of 4, ascending and disjoint
    p = joinpath(pkgdir(ChuiFrames), "test", "io", "data", "timestamps_stats.parquet")
    s = ChuiFrames.scan_file(p)
    hs, _ = ChuiFrames.plan_partitions(s, Tables.Scan(); morsel = 10)
    eager = read_file(p)
    for col in (:ms, :us, :ns, :ms_utc, :us_b), k in 1:3
        st = ChuiFrames.partition_stats(s, hs[k], col)
        for (pred, nkept) in ((x -> x .<= st.lo, k), (x -> x .>= st.hi, 4 - k))
            step = filter(pred(getproperty(c, col))) ⨟ select(:i, col)
            q = step(lazy(s))
            out = IOBuffer()
            explain(out, q)
            @test occursin("partitions: $nkept of 3 kept, $(3 - nkept) pruned by statistics", String(take!(out)))
            @test eq(collect(q), step(eager))
            @test eq(collect(q; threads = false), step(eager))
        end
    end
end

@testitem "lazy: CSV chunks (sequential source, partition types differ)" tags = [:unit] begin
    using ChuiFrames, Tables
    const ⨟ = ChuiFrames.Upstream.:⨟
    eq(a, b) = isequal(Tables.columntable(a), Tables.columntable(b))
    dir = mktempdir()
    path = joinpath(dir, "t.csv")
    # a missing value only in the last rows, so early chunks may type the column without Missing
    open(path, "w") do io
        println(io, "a,b,s")
        for i in 1:300
            println(io, i, ",", i == 300 ? "" : string(i / 2), ",", isodd(i) ? "o" : "e")
        end
    end
    s = ChuiFrames.CSVSource(path; chunkbytes = 512)
    hs, _ = ChuiFrames.plan_partitions(s, Tables.Scan(); morsel = 10)
    @test length(hs) > 1
    eager = ChuiFrames.read_source(s)
    for p in (filter(c.a .> 10) ⨟ mutate(z = c.b .* 2), select(:s, :a) ⨟ filter(c.s .== "o") ⨟ head(5), filter(c.b .> 100.0))
        @test eq(collect(p(lazy(s))), p(eager))
        @test eq(collect(p(lazy(s)); threads = false), p(eager))
    end
end
