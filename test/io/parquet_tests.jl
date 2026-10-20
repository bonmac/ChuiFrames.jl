# The Parquet2 package extension (ADR-0020): source, sink, statistics, registration.

@testitem "Parquet: no reader without Parquet2 (generic error)" tags = [:unit] begin
    # In a fresh process, so Parquet2 (loaded by other items) is not loaded yet.
    code = """
    using ChuiFrames
    @assert Base.get_extension(ChuiFrames, :ChuiFramesParquet2Ext) === nothing
    p = joinpath(mktempdir(), "x.parquet")
    msg = try; read_file(p); "no error"; catch e; sprint(showerror, e); end
    w = try; write_file((a = [1],), p); "no error"; catch e; sprint(showerror, e); end
    print(msg, "|", w, "|", isfile(p))
    """
    out = read(`$(Base.julia_cmd()) --startup-file=no --project=$(Base.active_project()) -e $code`, String)
    msg = "ArgumentError: no reader/writer registered for `.parquet`; load the package that provides it"
    @test out == "$msg|$msg|false"
end

@testitem "Parquet: round trip through Parquet2, one row group per partition" tags = [:unit] begin
    using ChuiFrames, Tables, Dates, Parquet2
    using ChuiFrames: frame_equal, column, DictColumn
    @test ChuiFrames.format_for("x.parquet") === :parquet
    dir = mktempdir()
    p1 = Frame(
        i = [1, 2, 3], f = [1.5, -0.0, 3.0], s = ["a", "", "c"], b = [true, false, true],
        d = [Date(2024, 1, 1), Date(1970, 1, 1), Date(2030, 6, 1)],
        t = [DateTime(2024, 1, 2, 3, 4, 5, 6), DateTime(1970), DateTime(2000)],
        k = DictColumn(UInt8[1, 2, 1], column(["x", "y"])), by = [codeunits("ab"), codeunits(""), codeunits("\xff")],
    )
    p2 = Frame(
        i = Union{Missing, Int}[missing, 5], f = [NaN, 4.0], s = Union{Missing, String}[missing, "e"],
        b = [false, false], d = [Date(2024), Date(2025)], t = [DateTime(2024), DateTime(2025)],
        k = DictColumn(UInt8[1, 1], column(["z"])), by = [codeunits("c"), codeunits("d")],
    )
    path = joinpath(dir, "t.parquet")
    @test write_file(Tables.partitioner([p1, p2]), path) == path
    @test readdir(dir) == ["t.parquet"]
    s = ChuiFrames.scan_file(path)
    @test ChuiFrames.source_label(s) == "Parquet t.parquet"
    hs, residual = ChuiFrames.plan_partitions(s, Tables.Scan(); morsel = 10)
    @test length(hs) == 2                                    # one row group per partition
    @test ChuiFrames.row_count(s) == (5, true)
    @test ChuiFrames.partition_row_count(s, hs[2]) == (2, true)
    got = read_file(path)
    @test frame_equal(got, ChuiFrames.vcat_frames([p1, p2]))
    @test eltype(getfield(got, :columns)[3]) == Union{Missing, ChuiFrames.StrView}
    # Projection pushdown: only the needed column chunks are read.
    hq, rq = ChuiFrames.plan_partitions(s, Tables.Scan(; select = [:s]); morsel = 10)
    @test ChuiFrames.read_partition(s, hq[1]).names == [:s]
    @test ChuiFrames.read_source(s; scan = Tables.Scan(; select = [:i], filter = Tables.colcmp(>, Tables.col(:i), 1))).nrow == 3
    # Through the readr-style names too, and from bytes.
    @test frame_equal(ChuiFrames.read_source(ChuiFrames.scan_file(path; format = :parquet)), got)
    # Object and nested columns raise, leaving no file.
    sub = mktempdir()
    @test_throws ArgumentError write_file((o = [:a],), joinpath(sub, "o.parquet"))
    @test_throws ArgumentError write_file((l = [[1]],), joinpath(sub, "l.parquet"))
    @test readdir(sub) == String[]
    # Empty input: the schema is still written.
    write_file((a = Int[], b = String[]), joinpath(sub, "e.parquet"))
    e = read_file(joinpath(sub, "e.parquet"))
    @test e.names == [:a, :b] && e.nrow == 0
    # A failed write keeps an existing file.
    keep = joinpath(sub, "e.parquet")
    before = read(keep)
    @test_throws ArgumentError write_file(Tables.partitioner([(a = [1], b = ["x"]), (a = ["bad"], b = ["y"])]), keep)
    @test read(keep) == before
    @test readdir(sub) == ["e.parquet"]
    # Registering :parquet again raises (the extension did it from __init__).
    @test_throws ArgumentError ChuiFrames.register_format!(:parquet; source = identity, sink = identity)
end

@testitem "Parquet: statistics follow ADR-0004 rule 4" tags = [:unit] begin
    using ChuiFrames, Tables, Parquet2
    dir = mktempdir()
    path = joinpath(dir, "s.parquet")
    parts = [
        (f = [1.0, 2.0], i = [3, 1], s = ["b", "a"], m = Union{Missing, Int}[1, 2]),
        (f = [1.0, NaN], i = [5, 6], s = ["c", "d"], m = Union{Missing, Int}[missing, 2]),
    ]
    write_file(Tables.partitioner(parts), path)
    s = ChuiFrames.scan_file(path)
    hs, _ = ChuiFrames.plan_partitions(s, Tables.Scan(); morsel = 10)
    st1 = ChuiFrames.partition_stats(s, hs[1], :f)
    @test keys(st1) == (:lo, :hi, :nnull, :nnan, :ndistinct)
    @test st1.lo == 1.0 && st1.hi == 2.0 && st1.nnull == 0 && st1.nnan === nothing
    # Parquet2 writes NaN bounds for a chunk holding NaN: reported as unknown.
    st2 = ChuiFrames.partition_stats(s, hs[2], :f)
    @test st2.lo === nothing && st2.hi === nothing && st2.nnan === nothing
    @test ChuiFrames.partition_stats(s, hs[1], :i) == (lo = 1, hi = 3, nnull = 0, nnan = nothing, ndistinct = 2)
    @test ChuiFrames.partition_stats(s, hs[1], :s).lo == "a"
    # A chunk with a missing: Parquet2 drops min/max (ADR-0020 rule 3), the null count stays.
    st4 = ChuiFrames.partition_stats(s, hs[2], :m)
    @test st4.lo === nothing && st4.hi === nothing && st4.nnull == 1
    @test ChuiFrames.partition_stats(s, hs[1], :m).lo == 1          # a nullable chunk without missing keeps them
    @test ChuiFrames.partition_stats(s, hs[1], :nope) === nothing
end

@testitem "Parquet: a pyarrow-written file (NaN left out of min/max)" tags = [:differential] begin
    using ChuiFrames, Tables, Dates, Parquet2
    uv = Sys.which("uv")
    if uv === nothing
        @test_skip "uv not found: pyarrow Parquet differential not run"
    else
        dir = mktempdir()
        write(
            joinpath(dir, "mk.py"), raw"""
            import pyarrow as pa, pyarrow.parquet as pq, datetime as dt
            t = pa.table({
                "i": pa.array([1, None, 3, 4, 5, 6], pa.int64()),
                "f": pa.array([1.0, float("nan"), 2.0, float("nan"), float("nan"), None], pa.float64()),
                "s": pa.array(["a", None, "ccc", "d", "e", "f"]),
                "d": pa.array(["x", "y", "x", "y", "x", "y"]).dictionary_encode(),
                "dt": pa.array([dt.date(2024, 1, i) for i in range(1, 7)], pa.date32()),
                "ts": pa.array([dt.datetime(2024, 1, 1, 0, 0, i) for i in range(6)], pa.timestamp("ms")),
            })
            pq.write_table(t, "py.parquet", row_group_size=3, compression="zstd", write_statistics=True)
            md = pq.ParquetFile("py.parquet").metadata
            print(md.num_row_groups, md.row_group(0).column(1).statistics.min, md.row_group(0).column(1).statistics.max)
            """
        )
        out = read(Cmd(`$uv run --no-project --python 3.13 --with pyarrow==26.0.0 python -I mk.py`; dir), String)
        @info "pyarrow wrote" out
        path = joinpath(dir, "py.parquet")
        f = read_file(path)
        @test f.names == [:i, :f, :s, :d, :dt, :ts]
        @test isequal(collect(getfield(f, :columns)[1]), [1, missing, 3, 4, 5, 6])
        @test isequal(collect(getfield(f, :columns)[2]), [1.0, NaN, 2.0, NaN, NaN, missing])
        @test isequal(collect(getfield(f, :columns)[3]), ["a", missing, "ccc", "d", "e", "f"])
        @test collect(getfield(f, :columns)[4]) == ["x", "y", "x", "y", "x", "y"]
        @test collect(getfield(f, :columns)[5]) == [Date(2024, 1, i) for i in 1:6]
        @test collect(getfield(f, :columns)[6]) == [DateTime(2024, 1, 1, 0, 0, i) for i in 0:5]
        s = ChuiFrames.scan_file(path)
        hs, _ = ChuiFrames.plan_partitions(s, Tables.Scan(); morsel = 10)
        @test length(hs) == 2
        # pyarrow leaves NaN out of min/max: the bounds are 1.0 and 2.0 although the row group
        # holds a NaN. nnan is unknown (nothing), so a NaN-true predicate cannot prune (CF-013).
        st = ChuiFrames.partition_stats(s, hs[1], :f)
        @test st.lo == 1.0 && st.hi == 2.0 && st.nnan === nothing
        st2 = ChuiFrames.partition_stats(s, hs[2], :f)
        @test st2.nnull == 1 && st2.nnan === nothing
        @test ChuiFrames.partition_stats(s, hs[1], :i).nnull == 1
        # Our own Parquet output is read back by pyarrow.
        write_file(f, joinpath(dir, "ours.parquet"))
        write(
            joinpath(dir, "rd.py"), raw"""
            import pyarrow.parquet as pq
            t = pq.read_table("ours.parquet")
            print(t.num_rows, t.schema.types, t.column("s").to_pylist(), t.column("i").to_pylist())
            """
        )
        back = read(Cmd(`$uv run --no-project --python 3.13 --with pyarrow==26.0.0 python -I rd.py`; dir), String)
        @info "pyarrow read ours" back
        @test startswith(back, "6 ")
        @test occursin("['a', None, 'ccc', 'd', 'e', 'f'] [1, None, 3, 4, 5, 6]", back)
    end
end
