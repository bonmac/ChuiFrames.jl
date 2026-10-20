# Source/Sink interface, TablesSource, the eager source executor and the format registry
# (ADR-0004 rules 2, 3, 5, 7, 9; chui-frames.md CF-011, CF-012, CF-014 to CF-016).

@testmodule IOFixtures begin
    using ChuiFrames, Tables

    # CF-011's example source: only the four required methods.
    struct VecSource <: ChuiFrames.Source
        parts::Vector{NamedTuple{(:x, :y), Tuple{Vector{Int}, Vector{String}}}}
    end
    ChuiFrames.source_schema(::VecSource) = Tables.Schema((:x, :y), (Int, String))
    ChuiFrames.source_label(::VecSource) = "VecSource"
    ChuiFrames.plan_partitions(s::VecSource, scan::Tables.Scan; morsel) = (collect(eachindex(s.parts)), scan)
    ChuiFrames.read_partition(s::VecSource, p) = s.parts[p]

    vecsource() = VecSource(
        [
            (x = [1, 2, 3], y = ["a", "b", "c"]),
            (x = Int[], y = String[]),
            (x = [4, 5, 6, 7], y = ["d", "e", "f", "g"]),
        ]
    )
    concatenated() = (x = collect(1:7), y = ["a", "b", "c", "d", "e", "f", "g"])

    # A source that applies a pushed filter itself and records the Scans it was handed.
    struct FilteringSource <: ChuiFrames.Source
        inner::VecSource
        seen::Vector{Tables.Scan}
    end
    ChuiFrames.source_schema(s::FilteringSource) = ChuiFrames.source_schema(s.inner)
    ChuiFrames.source_label(::FilteringSource) = "FilteringSource"
    function ChuiFrames.plan_partitions(s::FilteringSource, scan::Tables.Scan; morsel)
        push!(s.seen, scan)
        hs = [(p, scan.filter) for p in eachindex(s.inner.parts)]
        return hs, Tables.Scan(scan; filter = nothing, limit = nothing, offset = 0)
    end
    function ChuiFrames.read_partition(s::FilteringSource, (p, filter))
        t = s.inner.parts[p]
        filter === nothing && return t
        sc = s.seen[end]
        return Tables.scan(t, Tables.Scan(; filter, limit = sc.limit))
    end

    # A recording sink (CF-014's example).
    mutable struct LogSink <: ChuiFrames.Sink
        log::Vector{Symbol}
        parts::Vector{Any}
    end
    LogSink() = LogSink(Symbol[], Any[])
    ChuiFrames.open_sink(k::LogSink, schema::Tables.Schema) = (push!(k.log, :open); k)
    ChuiFrames.write_partition!(k::LogSink, part) = (push!(k.log, :write); push!(k.parts, part); nothing)
    ChuiFrames.close_sink!(k::LogSink) = (push!(k.log, :close); nothing)
    ChuiFrames.abort_sink!(k::LogSink, err) = (push!(k.log, :abort); nothing)

    # A source with given statistics per partition (`nothing`: statistics throw).
    struct StatsSource <: ChuiFrames.Source
        parts::Vector{Any}
        stats::Any
    end
    ChuiFrames.source_schema(::StatsSource) = Tables.Schema((:f,), (Float64,))
    ChuiFrames.source_label(::StatsSource) = "StatsSource"
    ChuiFrames.plan_partitions(s::StatsSource, scan::Tables.Scan; morsel) = (collect(eachindex(s.parts)), scan)
    ChuiFrames.read_partition(s::StatsSource, p) = s.parts[p]
    ChuiFrames.partition_stats(s::StatsSource, p, col) = s.stats === nothing ? error("no statistics") : s.stats[p]

    # A source whose second partition throws when read.
    struct ThrowingSource <: ChuiFrames.Source end
    ChuiFrames.source_schema(::ThrowingSource) = Tables.Schema((:x,), (Int,))
    ChuiFrames.source_label(::ThrowingSource) = "ThrowingSource"
    ChuiFrames.plan_partitions(::ThrowingSource, scan::Tables.Scan; morsel) = ([1, 2, 3], scan)
    ChuiFrames.read_partition(::ThrowingSource, p) = p == 2 ? error("boom in partition 2") : (x = [p],)
end

@testitem "CF-011 Source interface" tags = [:unit] setup = [IOFixtures] begin
    using ChuiFrames, Tables
    using ChuiFrames: frame_equal, read_source
    s = IOFixtures.vecsource()
    # The optional methods take their documented defaults.
    @test ChuiFrames.isthreadsafe(s) === false
    @test ChuiFrames.source_boundedness(s) === :bounded
    @test ChuiFrames.partition_stats(s, 1, :x) === nothing
    @test ChuiFrames.row_count(s) === nothing
    @test ChuiFrames.partition_row_count(s, 1) === nothing
    @test ChuiFrames.source_ordering(s) === nothing
    @test ChuiFrames.source_groups(s) == Symbol[]
    # Reading the whole source equals the concatenated table (three partitions, one empty).
    eager = Frame(IOFixtures.concatenated())
    @test frame_equal(read_source(s), eager)
    # A filter and a projection, through the source executor, equal Tables.scan on the whole table.
    q = Tables.Scan(; select = [:y], filter = Tables.colcmp(>, Tables.col(:x), 2))
    @test frame_equal(read_source(s; scan = q), Frame(Tables.scan(IOFixtures.concatenated(), q)))
    # The lazy entry point and grouped summaries belong to sub-lane p2-engine.
    if isdefined(ChuiFrames, :lazy)
        @test_broken false   # p2-engine: replace with the lazy filter/select/summarise checks
    else
        @test_skip "needs p2-engine: lazy filter, select and grouped summary over a Source"
    end
    # A partitioned Tables.jl input is a Source, and plans the same partitions twice.
    parts = Tables.partitioner([(x = [1, 2],), (x = [3],), (x = Int[],)])
    ts = ChuiFrames.TablesSource(parts)
    h1, r1 = ChuiFrames.plan_partitions(ts, Tables.Scan(); morsel = 2)
    h2, r2 = ChuiFrames.plan_partitions(ts, Tables.Scan(); morsel = 2)
    @test h1 == h2
    @test length(h1) == 3
    @test [collect(Tables.getcolumn(ChuiFrames.read_partition(ts, p), :x)) for p in h1] == [[1, 2], [3], Int[]]
    @test frame_equal(read_source(ts), Frame(x = [1, 2, 3]))
end

@testitem "TablesSource snapshots a single-pass partition iterator" tags = [:unit] begin
    using ChuiFrames, Tables
    # A single-pass partition iterator: the snapshot taken at construction is what every plan
    # sees, although the iterator itself is exhausted afterwards.
    once = Iterators.Stateful([(x = [1],), (x = [2],), (x = [3],)])
    ts = ChuiFrames.TablesSource(Tables.partitioner(once))
    @test isempty(once)
    @test ChuiFrames.read_source(ts).nrow == 3
    @test ChuiFrames.read_source(ts).nrow == 3
    @test first(ChuiFrames.plan_partitions(ts, Tables.Scan(); morsel = 1)) == [1, 2, 3]
    # Schema: merged over the partitions (the first has no missing, a later one does).
    ts2 = ChuiFrames.TablesSource(Tables.partitioner([(a = [1, 2],), (a = Union{Missing, Int}[missing],)]))
    @test ChuiFrames.source_schema(ts2) == Tables.Schema((:a,), (Union{Missing, Int},))
    @test ChuiFrames.source_label(ts2) isa String
    @test ChuiFrames.partition_row_count(ts2, 1) == (2, true)
    @test ChuiFrames.row_count(ts2) == (3, true)
    @test_throws ArgumentError ChuiFrames.TablesSource(42)
end

@testitem "CF-012 Scan residual" tags = [:unit] setup = [IOFixtures] begin
    using ChuiFrames, Tables
    using ChuiFrames: frame_equal, read_source
    eager = IOFixtures.concatenated()
    q = Tables.Scan(; select = [:x, :y], filter = Tables.colcmp(>, Tables.col(:x), 2))
    expected = Frame(Tables.scan(eager, q))
    plain = IOFixtures.vecsource()                                          # residual = request
    filt = IOFixtures.FilteringSource(IOFixtures.vecsource(), Tables.Scan[])  # applies the filter
    @test frame_equal(read_source(plain; scan = q), expected)
    @test frame_equal(read_source(filt; scan = q), expected)
    # offset k, limit n: the source sees offset 0 and a per-partition limit k + n.
    k, n = 2, 3
    ql = Tables.Scan(; offset = k, limit = n)
    rec = IOFixtures.FilteringSource(IOFixtures.vecsource(), Tables.Scan[])
    got = read_source(rec; scan = ql)
    @test only(rec.seen).offset == 0
    @test only(rec.seen).limit == k + n
    @test frame_equal(got, Frame(Tables.scan(eager, ql)))
    @test collect(got.columns[1]) == eager.x[(k + 1):(k + n)]
    # Filter plus limit through a source that consumes nothing: still the eager rows.
    qf = Tables.Scan(; filter = Tables.colcmp(>=, Tables.col(:x), 3), offset = 1, limit = 2)
    @test frame_equal(read_source(plain; scan = qf), Frame(Tables.scan(eager, qf)))
    @test frame_equal(read_source(filt; scan = qf), Frame(Tables.scan(eager, qf)))
    # missing excludes a row (SQL-style).
    m = ChuiFrames.TablesSource((a = [1, missing, 3],))
    qm = Tables.Scan(; filter = Tables.colcmp(>, Tables.col(:a), 0))
    @test isequal(collect(read_source(m; scan = qm).columns[1]), [1, 3])
    # Renames, type overrides and a zero-column selection.
    qr = Tables.Scan(; select = [:x => Float64 => :z])
    r = read_source(plain; scan = qr)
    @test r.names == [:z] && eltype(r.columns[1]) == Float64
    z = read_source(plain; scan = Tables.Scan(; select = ()))
    @test isempty(z.names) && z.nrow == 7
end

@testitem "CF-013 conservative pruning" tags = [:unit] setup = [IOFixtures] begin
    using ChuiFrames, Tables
    using ChuiFrames: frame_equal, read_source
    # A source whose statistics leave NaN out (as pyarrow's do) and count no NaN.
    parts = [(f = [1.0, NaN, 2.0],), (f = [1.0, NaN],), (f = [5.0],)]
    stats = [
        (; lo = 1.0, hi = 2.0, nnull = 0, nnan = nothing, ndistinct = nothing),
        (; lo = 1.0, hi = 1.0, nnull = 0, nnan = nothing, ndistinct = nothing),
        (; lo = missing, hi = 5.0, nnull = nothing, nnan = nothing, ndistinct = nothing),
    ]
    s = IOFixtures.StatsSource(parts, stats)
    @test ChuiFrames.partition_stats(s, 1, :f) == stats[1]
    @test all(st -> keys(st) == (:lo, :hi, :nnull, :nnan, :ndistinct), stats)
    whole = (f = [1.0, NaN, 2.0, 1.0, NaN, 5.0],)
    # The eager executor never prunes; the NaN rows survive `!(f <= 2.0)` and `f != 1.0`.
    for q in (
            Tables.Scan(; filter = !Tables.colcmp(<=, Tables.col(:f), 2.0)),
            Tables.Scan(; filter = Tables.colcmp(!=, Tables.col(:f), 1.0)),
        )
        got = read_source(s; scan = q)
        @test frame_equal(got, Frame(Tables.scan(whole, q)))
        @test count(isnan, collect(got.columns[1])) == 2
    end
    # A source whose statistics throw is still read completely.
    t = IOFixtures.StatsSource(parts, nothing)
    @test_throws ErrorException ChuiFrames.partition_stats(t, 1, :f)
    @test read_source(t).nrow == 6
    # Statistics-based pruning in the lazy engine belongs to sub-lane p2-engine.
    if isdefined(ChuiFrames, :lazy)
        @test_broken false   # p2-engine: filter(.!(c.f .<= 2.0)) / filter(c.f .!= 1.0) lazily, frame-equal to eager
    else
        @test_skip "needs p2-engine: lazy pruning with these statistics"
    end
end

@testitem "CF-014 transactional sinks" tags = [:unit] setup = [IOFixtures] begin
    using ChuiFrames, Tables, Arrow
    using ChuiFrames: write_source
    s = IOFixtures.vecsource()
    k = IOFixtures.LogSink()
    write_source(k, s)
    @test k.log == [:open, :write, :write, :write, :close]
    @test [length(Tables.getcolumn(p, :x)) for p in k.parts] == [3, 0, 4]
    k2 = IOFixtures.LogSink()
    @test_throws ErrorException write_source(k2, IOFixtures.ThrowingSource())
    @test k2.log == [:open, :write, :abort]
    # Through the built-in Arrow sink, a failing pipeline leaves no file (and no temp file).
    dir = mktempdir()
    path = joinpath(dir, "t.arrow")
    @test_throws ErrorException write_file(IOFixtures.ThrowingSource(), path)
    @test readdir(dir) == String[]
    # A partition that cannot be converted to the declared schema raises ArgumentError;
    # a convertible one is written converted.
    st = ChuiFrames.open_sink(ChuiFrames.ArrowSink(path), Tables.Schema((:a,), (Int,)))
    @test_throws ArgumentError ChuiFrames.write_partition!(st, (a = ["x"],))
    ChuiFrames.abort_sink!(st, nothing)
    @test readdir(dir) == String[]
    st = ChuiFrames.open_sink(ChuiFrames.ArrowSink(path), Tables.Schema((:a,), (Float64,)))
    ChuiFrames.write_partition!(st, (a = [1, 2],))
    ChuiFrames.close_sink!(st)
    t = Arrow.Table(path)
    @test eltype(t.a) == Float64 && collect(t.a) == [1.0, 2.0]
    @test readdir(dir) == ["t.arrow"]
end

@testitem "CF-015 bounded sources" tags = [:unit] setup = [IOFixtures] begin
    using ChuiFrames, Tables
    dir = mktempdir()
    write_file((x = [1, 2],), joinpath(dir, "a.csv"))
    write_file((x = [1, 2],), joinpath(dir, "a.arrow"))
    srcs = Any[IOFixtures.vecsource(), ChuiFrames.TablesSource((x = [1],)), ChuiFrames.scan_file(joinpath(dir, "a.csv")), ChuiFrames.scan_file(joinpath(dir, "a.arrow"))]
    for s in srcs
        @test ChuiFrames.source_boundedness(s) === :bounded
        @test first(ChuiFrames.plan_partitions(s, Tables.Scan(); morsel = 65_536)) isa Vector
    end
end

@testitem "CF-016 format registry" tags = [:unit] setup = [IOFixtures] begin
    using ChuiFrames, Tables
    using ChuiFrames: frame_equal
    dir = mktempdir()
    x = Frame(a = [1, 2, 3], b = ["x", "y", missing])
    write_file(x, joinpath(dir, "t.csv"))
    @test frame_equal(read_file(joinpath(dir, "t.csv")), x)
    @test frame_equal(ChuiFrames.read_source(ChuiFrames.scan_file(joinpath(dir, "t.csv"))), x)
    write_file(x, joinpath(dir, "t.arrow"))
    @test isfile(joinpath(dir, "t.arrow"))
    @test frame_equal(read_file(joinpath(dir, "t.arrow")), x)
    # Registering a key twice raises; a fresh key is read and written by `format =`.
    key = Symbol("cf016_", rand(UInt32))
    ChuiFrames.register_format!(key; source = (path; kw...) -> ChuiFrames.scan_file(path; format = :csv, kw...), sink = (path; kw...) -> ChuiFrames.CSVSink(path; kw...))
    @test_throws ArgumentError ChuiFrames.register_format!(key; source = identity, sink = identity)
    p = joinpath(dir, "t.data")
    write_file(x, p; format = key)
    @test frame_equal(read_file(p; format = key), x)
    # An unregistered extension or key raises the one generic error.
    err = try
        read_file(joinpath(dir, "t.xyz"))
    catch e
        e
    end
    @test err isa ArgumentError && occursin("no reader/writer registered for `.xyz`", sprint(showerror, err))
    err = try
        write_file(x, joinpath(dir, "t.xyz"))
    catch e
        e
    end
    @test err isa ArgumentError && occursin("no reader/writer registered", sprint(showerror, err))
    @test_throws ArgumentError read_file(p; format = :nonexistent_format)
    # A file with no extension and no explicit format.
    @test_throws ArgumentError read_file(joinpath(dir, "noext"))
end

@testitem "format registry: extensions and keys" tags = [:unit] begin
    using ChuiFrames
    @test ChuiFrames.format_for("x.ARROW") === :arrow
    @test ChuiFrames.format_for("x.feather") === :arrow
    @test ChuiFrames.format_for("x.ipc") === :arrow
    @test ChuiFrames.format_for("x.arrows") === :arrow
    @test ChuiFrames.format_for("x.csv") === :csv
    @test ChuiFrames.format_for("x.tsv") === :csv
    @test ChuiFrames.format_for("x.parquet") === (Base.get_extension(ChuiFrames, :ChuiFramesParquet2Ext) === nothing ? nothing : :parquet)
    # An extension already claimed by another key cannot be claimed again.
    key = Symbol("ext_", rand(UInt32))
    @test_throws ArgumentError ChuiFrames.register_format!(key; source = identity, sink = identity, extensions = [".csv"])
    @test !haskey(ChuiFrames.registered_formats(), key)
end
