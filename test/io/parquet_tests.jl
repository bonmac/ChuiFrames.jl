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

@testitem "Parquet: timestamps read exactly, every unit (ADR-0021 rule 11; review M1)" tags = [:unit] begin
    using ChuiFrames, Tables, Dates, Parquet2
    # pyarrow-written fixture, see test/io/data/README.md
    p = joinpath(@__DIR__, "data", "timestamps_units.parquet")
    s = ChuiFrames.scan_file(p)
    f = read_file(p)
    @test eltype(Tables.getcolumn(f, :us)) <: Union{Missing, ArrowTimestamp{Dates.Microsecond, nothing}}
    @test Dates.value(Tables.getcolumn(f, :us)[1]) == 1_704_067_200_123_456
    @test eltype(Tables.getcolumn(f, :ns)) <: Union{Missing, ArrowTimestamp{Dates.Nanosecond, nothing}}
    @test Dates.value(Tables.getcolumn(f, :ns)[1]) == 1_704_067_200_123_456_789
    @test collect(Tables.getcolumn(f, :ms)) == [DateTime(2024, 1, 1, 0, 0, 0, 123)]
    @test collect(Tables.getcolumn(f, :d)) == [Date(2024, 1, 2)]
    # bounds decoded from the raw statistics bytes, exactly, as the values read (one row each)
    h, _ = ChuiFrames.plan_partitions(s, Tables.Scan(); morsel = 10)
    for col in (:us, :ns, :ms)
        st = ChuiFrames.partition_stats(s, h[1], col)
        x = only(collect(Tables.getcolumn(f, col)))
        @test st.lo === x && st.hi === x && st.nnull == 0
    end
end

@testsnippet PqStats begin
    using ChuiFrames, Tables, Dates, Parquet2
    # Row-group pruning as ADR-0004 rule 4 states it, for `c <= t` and `c >= t`: neither can be
    # true on NaN or `missing`, so only the bounds matter; a `nothing` bound keeps the group.
    function kept(s, hs, c, op, t)
        return [
            k for (k, h) in enumerate(hs) if begin
                    st = ChuiFrames.partition_stats(s, h, c)
                    b = st === nothing ? nothing : op === (<=) ? st.lo : st.hi
                    b === nothing || (op === (<=) ? b <= t : b >= t)
                end
        ]
    end
    # the row ids (column :i) where `c op t`, from the given row groups only
    function rows(s, hs, ks, c, op, t)
        out = Int[]
        for k in ks
            p = ChuiFrames.read_partition(s, hs[k])
            for (i, x) in zip(Tables.getcolumn(p, :i), Tables.getcolumn(p, c))
                ismissing(x) || op(x, t) && push!(out, i)
            end
        end
        return out
    end
end

@testitem "Parquet: exact timestamp statistics prune row groups (pyarrow, several row groups)" tags = [:unit] setup = [PqStats] begin
    # pyarrow-written fixture (test/io/data/README.md): 3 row groups of 4, ascending and disjoint,
    # whose bounds Parquet2's Float64 path decodes 1 ms late (min) or truncates (µs/ns)
    p = joinpath(@__DIR__, "data", "timestamps_stats.parquet")
    s = ChuiFrames.scan_file(p)
    hs, _ = ChuiFrames.plan_partitions(s, Tables.Scan(); morsel = 10)
    @test length(hs) == 3
    tscols = (:ms, :us, :ns, :ms_utc, :ns_utc, :us_b, :ms_null)
    for c in tscols, (k, h) in enumerate(hs)
        v = collect(skipmissing(Tables.getcolumn(ChuiFrames.read_partition(s, h), c)))
        st = ChuiFrames.partition_stats(s, h, c)
        @test keys(st) == (:lo, :hi, :nnull, :nnan, :ndistinct)
        @test st.lo === minimum(v) && st.hi === maximum(v)        # exact, and the type read
        @test st.nnull == (c === :ms_null && k == 2 ? 1 : 0) && st.nnan === nothing
    end
    @test ChuiFrames.partition_stats(s, hs[1], :ms).lo === DateTime(1900, 9, 21, 1, 37, 28, 300)
    @test typeof(ChuiFrames.partition_stats(s, hs[3], :us_b).hi) == ArrowTimestamp{Dates.Microsecond, Symbol("Europe/Berlin")}
    # Parquet2's own statistics are off by 1 ms for this bound: pruning on them would drop a row
    @test Parquet2.ColumnStatistics(s.ds[1]["ms"]).min == DateTime(1900, 9, 21, 1, 37, 28, 301)
    # other columns keep their statistics
    @test ChuiFrames.partition_stats(s, hs[2], :i) == (lo = 4, hi = 7, nnull = 0, nnan = nothing, ndistinct = nothing)
    # Pruning: `c <= (min of group k)` keeps groups 1:k, `c >= (max of group k)` keeps k:3, and
    # the kept groups give exactly the rows of the unpruned read.
    for c in tscols, k in 1:3
        lo, hi = ChuiFrames.partition_stats(s, hs[k], c)[(:lo, :hi)]
        @test kept(s, hs, c, <=, lo) == 1:k
        @test kept(s, hs, c, >=, hi) == k:3
        for (op, t) in ((<=, lo), (>=, hi))
            ks = kept(s, hs, c, op, t)
            @test rows(s, hs, ks, c, op, t) == rows(s, hs, 1:3, c, op, t)
            @test !isempty(rows(s, hs, ks, c, op, t)) || (c === :ms_null && k == 2)
        end
    end
    # the same filter through the source's own read gives the same rows
    t = ChuiFrames.partition_stats(s, hs[2], :ms).lo
    got = ChuiFrames.read_source(s; scan = Tables.Scan(; filter = Tables.colcmp(<=, Tables.col(:ms), t)))
    @test collect(Tables.getcolumn(got, :i)) == rows(s, hs, 1:3, :ms, <=, t)
end

@testitem "Parquet: no timestamp statistics in the file, none reported" tags = [:unit] setup = [PqStats] begin
    # the same table written with write_statistics=False (test/io/data/README.md)
    s = ChuiFrames.scan_file(joinpath(@__DIR__, "data", "timestamps_stats_none.parquet"))
    hs, _ = ChuiFrames.plan_partitions(s, Tables.Scan(); morsel = 10)
    for c in (:ms, :us, :ns, :ms_utc, :ns_utc, :us_b, :ms_null), h in hs
        @test ChuiFrames.partition_stats(s, h, c) === nothing
    end
    @test kept(s, hs, :ms, <=, DateTime(1800)) == 1:3                  # nothing prunes
    full = read_file(joinpath(@__DIR__, "data", "timestamps_stats.parquet"))
    @test isequal(collect(Tables.getcolumn(read_file(joinpath(@__DIR__, "data", "timestamps_stats_none.parquet")), :ns)), collect(Tables.getcolumn(full, :ns)))
end

@testitem "Parquet: exact timestamp statistics on ChuiFrames-written files" tags = [:unit] setup = [PqStats] begin
    using Random
    rng = Random.MersenneTwister(11)
    xs = sort!(rand(rng, (-3 * 10^12):(10^13), 300))
    dt(x) = DateTime(Dates.UTM(x + Dates.UNIXEPOCH))
    parts = [
        (i = collect(1:100), t = dt.(xs[1:100]), m = Union{Missing, DateTime}[dt.(xs[1:99]); missing], s = ArrowTimestamp{Dates.Second}.(fld.(xs[1:100], 1000))),
        (i = collect(101:200), t = dt.(xs[101:200]), m = Union{Missing, DateTime}[dt.(xs[101:200])...], s = ArrowTimestamp{Dates.Second}.(fld.(xs[101:200], 1000))),
        (i = collect(201:300), t = dt.(xs[201:300]), m = Union{Missing, DateTime}[dt.(xs[201:300])...], s = ArrowTimestamp{Dates.Second}.(fld.(xs[201:300], 1000))),
    ]
    p = joinpath(mktempdir(), "w.parquet")
    write_file(Tables.partitioner(parts), p)
    s = ChuiFrames.scan_file(p)
    hs, _ = ChuiFrames.plan_partitions(s, Tables.Scan(); morsel = 10)
    @test length(hs) == 3
    for (k, h) in enumerate(hs), c in (:t, :m, :s)
        st = ChuiFrames.partition_stats(s, h, c)
        v = collect(skipmissing(Tables.getcolumn(ChuiFrames.read_partition(s, h), c)))
        if c === :m && k == 1
            # Parquet2 drops min/max for a chunk holding a missing (ADR-0020 rule 3)
            @test st.lo === nothing && st.hi === nothing && st.nnull == 1
        else
            @test st.lo === minimum(v) && st.hi === maximum(v) && st.nnull == 0
        end
    end
    @test ChuiFrames.partition_stats(s, hs[2], :t).lo === dt(xs[101])
    for k in 1:3
        lo = ChuiFrames.partition_stats(s, hs[k], :t).lo
        @test kept(s, hs, :t, <=, lo) == 1:k
        @test rows(s, hs, kept(s, hs, :t, <=, lo), :t, <=, lo) == rows(s, hs, 1:3, :t, <=, lo)
    end
    # from bytes too
    sb = Base.get_extension(ChuiFrames, :ChuiFramesParquet2Ext).ParquetSource(read(p))
    @test ChuiFrames.partition_stats(sb, hs[3], :t).hi === dt(xs[300])
end

@testitem "Parquet: raw timestamp statistics fail closed" tags = [:unit] begin
    using ChuiFrames, Tables, Dates, Parquet2
    X = Base.get_extension(ChuiFrames, :ChuiFramesParquet2Ext)
    St = Parquet2.Meta.Statistics
    le(x::Int64) = collect(reinterpret(UInt8, [htol(x)]))
    V = ArrowTimestamp{Dates.Microsecond, nothing}
    @test X._raw_bound(St(min_value = le(-5), max_value = le(7)), :min_value, :min, V) === V(-5)
    @test X._raw_bound(St(min_value = le(-5), max_value = le(7)), :max_value, :max, V) === V(7)
    # the deprecated fields hold signed-order bounds, which is INT64's order: used when alone
    @test X._raw_bound(St(min = le(typemin(Int64))), :min_value, :min, V) === V(typemin(Int64))
    @test X._raw_bound(St(), :min_value, :min, V) === nothing                   # absent
    @test X._raw_bound(St(min_value = UInt8[1, 2, 3, 4]), :min_value, :min, V) === nothing   # 4 bytes
    @test X._raw_bound(St(min_value = UInt8[]), :min_value, :min, V) === nothing
    # a millisecond count outside the DateTime range is no bound (never an error)
    @test X._raw_bound(St(min_value = le(typemax(Int64))), :min_value, :min, DateTime) === nothing
    @test X._raw_bound(St(min_value = le(1)), :min_value, :min, DateTime) === DateTime(1970, 1, 1, 0, 0, 0, 1)
    # a struct without the expected fields (a changed Parquet2): no bound
    @test X._raw_bound((; a = 1), :min_value, :min, V) === nothing
end

@testitem "Parquet: millisecond timestamps exact where Parquet2's own decoding is 1 ms off (ADR-0021 TS-12)" tags = [:unit] begin
    using ChuiFrames, Tables, Dates, Parquet2
    # pyarrow-written fixture (test/io/data/README.md): values Parquet2's Float64 path reads 1 ms
    # early, naive and UTC-adjusted, ms/µs/ns, with pyarrow's ARROW:schema zone names
    p = joinpath(@__DIR__, "data", "timestamps_exact.parquet")
    v = [-2186259751700, -2176368591140, 1085072413093, 1704164645123]
    f = read_file(p)
    @test [Dates.value(x) - Dates.UNIXEPOCH for x in Tables.getcolumn(f, :ms)] == v
    # Parquet2's own decoding really is off for these values (the reason for the raw path)
    @test [Dates.value(x) - Dates.UNIXEPOCH for x in Parquet2.load(Parquet2.Dataset(p)[1], "ms")] != v
    @test Dates.value.(Tables.getcolumn(f, :us)) == v .* 1000 .+ 7
    @test eltype(Tables.getcolumn(f, :ns_utc)) <: Union{Missing, ArrowTimestamp{Dates.Nanosecond, :UTC}}
    @test Dates.value.(Tables.getcolumn(f, :ns_utc)) == v .* 10^6 .+ 9
    @test eltype(Tables.getcolumn(f, :us_b)) <: Union{Missing, ArrowTimestamp{Dates.Microsecond, Symbol("Europe/Berlin")}}
    @test eltype(Tables.getcolumn(f, :ms_utc)) <: Union{Missing, ArrowTimestamp{Dates.Millisecond, :UTC}}
    # without pyarrow's ARROW:schema, a UTC-adjusted column is :UTC (Parquet stores only the flag)
    g = read_file(joinpath(@__DIR__, "data", "timestamps_exact_noschema.parquet"))
    @test eltype(Tables.getcolumn(g, :us_b)) <: Union{Missing, ArrowTimestamp{Dates.Microsecond, :UTC}}
    @test isequal(collect(Tables.getcolumn(g, :us_b)), collect(Tables.getcolumn(f, :us_b)))   # same instants
end

@testitem "Parquet: timestamp writes are exact or raise (ADR-0021 rule 11)" tags = [:unit] begin
    using ChuiFrames, Tables, Dates, Parquet2, Random
    const TS = ArrowTimestamp
    rng = Random.MersenneTwister(7)
    xs = rand(rng, (-3 * 10^12):(10^13), 5000)
    dts = DateTime.(Dates.UTM.(xs .+ Dates.UNIXEPOCH))
    f = Frame(dt = dts, s = TS{Dates.Second}.(fld.(xs, 1000)), m = Union{Missing, DateTime}[dts[1:(end - 1)]; missing])
    mktempdir() do dir
        p = joinpath(dir, "w.parquet")
        write_file(f, p)
        g = read_file(p)
        @test [Dates.value(x) - Dates.UNIXEPOCH for x in Tables.getcolumn(g, :dt)] == xs    # Parquet2's writer alone is off for ~1%
        @test isequal(collect(Tables.getcolumn(g, :m)), collect(Tables.getcolumn(f, :m)))
        @test [Dates.value(x) - Dates.UNIXEPOCH for x in Tables.getcolumn(g, :s)] == fld.(xs, 1000) .* 1000   # s is stored as ms
        for bad in (Frame(t = TS{Dates.Microsecond}.([1])), Frame(t = TS{Dates.Millisecond, :UTC}.([1])))
            err = try
                write_file(bad, joinpath(dir, "bad.parquet"))
                nothing
            catch e
                e
            end
            @test err isa ArgumentError && occursin("Arrow", sprint(showerror, err))
        end
    end
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
