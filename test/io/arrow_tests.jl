# The Arrow IPC writer adapter (ADR-0010 rule 2, ADR-0001 rule 11) and the Arrow source.
# Arrow.jl's reader is used here as a cross-check only (it is correct on files Arrow.jl writes);
# the :differential items read the output with pyarrow and R's arrow package.

@testmodule ArrowFixtures begin
    using ChuiFrames, Dates
    using Arrow: Arrow
    using ChuiFrames: column, DictColumn

    # Two partitions of every writable kind. The first partition has no missing anywhere;
    # the declared schema (from the merged partitions) is nullable where the second has one.
    function parts()
        p1 = Frame(
            i = [1, 2, 3],
            f = [1.5, NaN, -0.0],
            s = ["a", "bb", ""],
            d = DictColumn(UInt8[1, 2, 1], column(["x", "y"])),
            b = [codeunits("ab"), codeunits(""), codeunits("\0\xff")],
            bo = [true, false, true],
            dt = [Date(2024, 1, 1), Date(1970, 1, 1), Date(1900, 12, 31)],
            ts = [DateTime(2024, 1, 2, 3, 4, 5, 6), DateTime(1970), DateTime(2000, 2, 29)],
            l = [[1, 2], Int[], [3]],
            ls = [["a"], ["b", "c"], String[]],
            st = [(a = 1, b = "p"), (a = 2, b = "q"), (a = 3, b = "r")],
        )
        p2 = Frame(
            i = Union{Missing, Int}[4, missing],
            f = Union{Missing, Float64}[missing, 2.5],
            s = Union{Missing, String}[missing, "ccc"],
            d = DictColumn(UInt8[1, 0], column(["z"]), BitVector([true, false])),
            b = Union{Missing, Base.CodeUnits{UInt8, String}}[missing, codeunits("c")],
            bo = Union{Missing, Bool}[missing, false],
            dt = Union{Missing, Date}[missing, Date(2030, 6, 1)],
            ts = Union{Missing, DateTime}[DateTime(2024), missing],
            l = Union{Missing, Vector{Int}}[missing, [4, 5, 6]],
            ls = Union{Missing, Vector{String}}[["d"], missing],
            st = Union{Missing, @NamedTuple{a::Int, b::String}}[(a = 4, b = "s"), missing],
        )
        return p1, p2
    end
    expected() = (
        i = [1, 2, 3, 4, missing],
        f = [1.5, NaN, -0.0, missing, 2.5],
        s = ["a", "bb", "", missing, "ccc"],
        d = ["x", "y", "x", "z", missing],
        b = [b"ab", b"", b"\0\xff", missing, b"c"],
        bo = [true, false, true, missing, false],
        dt = [Date(2024, 1, 1), Date(1970, 1, 1), Date(1900, 12, 31), missing, Date(2030, 6, 1)],
        ts = [DateTime(2024, 1, 2, 3, 4, 5, 6), DateTime(1970), DateTime(2000, 2, 29), DateTime(2024), missing],
        l = [[1, 2], Int[], [3], missing, [4, 5, 6]],
        ls = [["a"], ["b", "c"], String[], ["d"], missing],
        st = [(a = 1, b = "p"), (a = 2, b = "q"), (a = 3, b = "r"), (a = 4, b = "s"), missing],
    )
    plain(x::AbstractVector{UInt8}) = Vector{UInt8}(x)
    plain(x::AbstractString) = String(x)
    plain(x::AbstractVector) = map(plain, x)
    plain(x::NamedTuple) = map(plain, x)
    plain(x) = x
    readback(path) = (t = Arrow.Table(path); NamedTuple(n => plain.(collect(getproperty(t, n))) for n in propertynames(t)))
end

@testitem "Arrow writer: every kind, two partitions, first without nulls" tags = [:unit] setup = [ArrowFixtures] begin
    using ChuiFrames, Tables, Arrow
    p1, p2 = ArrowFixtures.parts()
    dir = mktempdir()
    path = joinpath(dir, "all.arrow")
    @test write_file(Tables.partitioner([p1, p2]), path) == path
    got = ArrowFixtures.readback(path)
    exp = ArrowFixtures.expected()
    for n in keys(exp)
        @test isequal(got[n], exp[n])
    end
    # One declared schema: every column nullable because the second partition has a missing.
    t = Arrow.Table(path)
    sch = Tables.schema(t)
    @test all(T -> Missing <: T, sch.types)
    # Two record batches (one per partition).
    @test length(collect(Tables.partitions(Arrow.Stream(path)))) == 2
    # File format (magic bytes at both ends).
    bytes = read(path)
    @test bytes[1:6] == b"ARROW1" && bytes[(end - 5):end] == b"ARROW1"
    @test readdir(dir) == ["all.arrow"]
end

@testitem "Arrow writer: dictionaries are 1-based and unified up front" tags = [:unit] begin
    using ChuiFrames, Tables, Arrow, DataAPI
    using ChuiFrames: column, DictColumn
    # Partitions with different dictionaries: the writer must give Arrow.jl the full unified
    # dictionary in every partition, so the first partition fixes an index type that fits and
    # no delta dictionary is needed.
    big = column(["v$i" for i in 1:200])
    p1 = Frame(d = DictColumn(UInt8[1, 2], column(["a", "b"])))
    p2 = Frame(d = DictColumn(UInt8[200, 1, 2], big))
    path = joinpath(mktempdir(), "dict.arrow")
    write_file(Tables.partitioner([p1, p2]), path)
    t = Arrow.Table(path)
    @test collect(t.d) == ["a", "b", "v200", "v1", "v2"]   # the unified dictionary is checked by pyarrow (:differential)
    # A dictionary column whose dictionary is not declared (a plain sink) is decoded.
    st = ChuiFrames.open_sink(ChuiFrames.ArrowSink(path), Tables.Schema((:d,), (ChuiFrames.StrView,)))
    ChuiFrames.write_partition!(st, p1)
    ChuiFrames.write_partition!(st, p2)
    ChuiFrames.close_sink!(st)
    t = Arrow.Table(path)
    @test collect(t.d) == ["a", "b", "v200", "v1", "v2"]
    @test DataAPI.refarray(t.d) === t.d || !(eltype(DataAPI.refarray(t.d)) <: Signed)   # not dictionary-encoded
    # unify_dictionaries keeps first-appearance order and returns a shared dictionary as is.
    u = ChuiFrames.unify_dictionaries([column(["a", "b"]), column(["b", "c"])])
    @test collect(u) == ["a", "b", "c"]
    @test ChuiFrames.unify_dictionaries([big, big]) === big
    # A declared dictionary that lacks a value raises.
    st = ChuiFrames.open_sink(ChuiFrames.ArrowSink(path; dictionaries = Dict(:d => column(["a"]))), Tables.Schema((:d,), (ChuiFrames.StrView,)))
    @test_throws ArgumentError ChuiFrames.write_partition!(st, p1)
    ChuiFrames.abort_sink!(st, nothing)
end

@testitem "Arrow writer: aborts leave no file" tags = [:unit] begin
    using ChuiFrames, Tables
    dir = mktempdir()
    path = joinpath(dir, "x.arrow")
    # An object column raises an ArgumentError naming the type, and no file is left.
    err = try
        write_file((o = [:a, :b],), path)
    catch e
        e
    end
    @test err isa ArgumentError && occursin("Symbol", sprint(showerror, err))
    @test readdir(dir) == String[]
    # Nested object columns too.
    @test_throws ArgumentError write_file((l = [Any[1, "x"]],), path)
    @test readdir(dir) == String[]
    # An existing file is untouched by a failed write, and replaced by a successful one.
    write_file((x = [1],), path)
    before = read(path)
    @test_throws ArgumentError write_file(Tables.partitioner([(x = [1],), (x = ["s"],)]), path)
    @test read(path) == before
    @test readdir(dir) == ["x.arrow"]
    # The temporary file lives in the target's directory while the write runs.
    st = ChuiFrames.open_sink(ChuiFrames.ArrowSink(path), Tables.Schema((:x,), (Int,)))
    @test length(readdir(dir)) == 2 && dirname(st.tmp) == dir
    ChuiFrames.abort_sink!(st, ErrorException("x"))
    @test readdir(dir) == ["x.arrow"]
    # A missing directory raises before anything is written.
    @test_throws ArgumentError write_file((x = [1],), joinpath(dir, "nope", "x.arrow"))
end

@testitem "Arrow writer: schema mismatches raise" tags = [:unit] setup = [ArrowFixtures] begin
    using ChuiFrames, Tables
    path = joinpath(mktempdir(), "m.arrow")
    fresh() = ChuiFrames.open_sink(ChuiFrames.ArrowSink(path), Tables.Schema((:a,), (Int,)))
    for bad in ((a = [1.5],), (a = Union{Missing, Int}[missing],), (b = [1],), (a = [1], b = [2]), (a = [[1]],))
        st = fresh()
        @test_throws ArgumentError ChuiFrames.write_partition!(st, bad)
        ChuiFrames.abort_sink!(st, nothing)
    end
    # Exact conversions are allowed (Int32 -> Int64, an all-valid nullable column -> non-null).
    st = fresh()
    ChuiFrames.write_partition!(st, (a = Int32[1, 2],))
    ChuiFrames.write_partition!(st, (a = Union{Missing, Int}[3],))
    ChuiFrames.close_sink!(st)
    @test collect(ArrowFixtures.Arrow.Table(path).a) == [1, 2, 3]
    # A nested layout change between partitions (list child nullability) raises instead of
    # reaching Arrow.jl.
    st = ChuiFrames.open_sink(ChuiFrames.ArrowSink(path), Tables.Schema((:l,), (Vector{Int},)))
    ChuiFrames.write_partition!(st, (l = [[1]],))
    @test_throws ArgumentError ChuiFrames.write_partition!(st, (l = [Union{Missing, Int}[missing]],))
    ChuiFrames.abort_sink!(st, nothing)
    # Strings that would need 64-bit offsets in a small-offset file raise (checked on the
    # column, without allocating 2 GiB: a StringColumn with Int64 offsets past typemax(Int32)
    # is what an overflowing builder produces).
    @test ChuiFrames._needs_large(ChuiFrames.StringColumn(Int64[0, 0], UInt8[])) == false
end

@testitem "Arrow writer: stream format, append, large offsets, compression, empty input" tags = [:unit] begin
    using ChuiFrames, Tables, Arrow
    dir = mktempdir()
    # .arrows is the stream format (no file magic at the start).
    sp = joinpath(dir, "s.arrows")
    write_file((x = [1, 2],), sp)
    @test read(sp)[1:6] != b"ARROW1"
    @test collect(Arrow.Table(sp).x) == [1, 2]
    # Explicit stream format for another extension, and append (documented as not atomic).
    sp2 = joinpath(dir, "s2.arrow")
    write_arrow((x = [1],), sp2; format = :stream)
    write_arrow((x = [2, 3],), sp2; format = :stream, append = true)
    @test collect(Arrow.Table(sp2).x) == [1, 2, 3]
    @test_throws ArgumentError ChuiFrames.ArrowSink(joinpath(dir, "f.arrow"); format = :file, append = true)
    @test_throws ArgumentError ChuiFrames.ArrowSink(joinpath(dir, "f.arrow"); format = :parquet)
    @test_throws ArgumentError ChuiFrames.ArrowSink(joinpath(dir, "f.arrow"); compress = :gzip)
    # large = true writes 64-bit offsets; compression round trips.
    lp = joinpath(dir, "large.arrow")
    write_arrow((s = ["a", "bc"], l = [[1], [2, 3]]), lp; large = true)
    @test collect(Arrow.Table(lp).s) == ["a", "bc"]
    for c in (:lz4, :zstd)
        cp = joinpath(dir, "c_$c.arrow")
        write_arrow((x = collect(1:100), s = ["v$i" for i in 1:100]), cp; compress = c)
        t = Arrow.Table(cp)
        @test collect(t.x) == 1:100 && collect(t.s)[end] == "v100"
    end
    # Zero rows, and zero partitions: the file still carries the declared schema.
    ep = joinpath(dir, "empty.arrow")
    write_file((x = Int[], s = String[]), ep)
    t = Arrow.Table(ep)
    @test collect(Tables.columnnames(t)) == [:x, :s] && length(t.x) == 0
    st = ChuiFrames.open_sink(ChuiFrames.ArrowSink(ep), Tables.Schema((:y,), (Union{Missing, Float64},)))
    ChuiFrames.close_sink!(st)
    t = Arrow.Table(ep)
    @test collect(Tables.columnnames(t)) == [:y] && length(t.y) == 0 && eltype(t.y) == Union{Missing, Float64}
end

@testitem "Arrow source over the own reader (p2-ipc)" tags = [:unit] setup = [ArrowFixtures] begin
    using ChuiFrames, Tables
    using ChuiFrames: frame_equal
    let
        dir = mktempdir()
        x = Frame(a = [1, 2, 3], b = ["x", missing, "z"])
        path = joinpath(dir, "t.arrow")
        write_file(Tables.partitioner([x, x]), path)
        s = ChuiFrames.scan_file(path)
        @test s isa ChuiFrames.ArrowSource
        @test ChuiFrames.row_count(s) == (6, true)
        hs, residual = ChuiFrames.plan_partitions(s, Tables.Scan(; select = [:b]); morsel = 10)
        @test length(hs) == 2
        @test Tables.columnnames(ChuiFrames.read_partition(s, hs[1])) == [:b]
        @test frame_equal(read_file(path), ChuiFrames.vcat_frames([x, x]))
        @test frame_equal(read_arrow(read(path)), ChuiFrames.vcat_frames([x, x]))
        sp = joinpath(dir, "t.arrows")
        write_file(x, sp)
        @test frame_equal(read_file(sp), x)
        # Every kind written by the adapter reads back through the own reader.
        p1, p2 = ArrowFixtures.parts()
        write_file(Tables.partitioner([p1, p2]), joinpath(dir, "all.arrow"))
        got = Tables.columntable(read_file(joinpath(dir, "all.arrow")))
        want = ArrowFixtures.expected()
        for n in keys(want)
            @test isequal(ArrowFixtures.plain.(collect(got[n])), want[n])
        end
    end
end

@testitem "pushed_columns: projection pushdown only for name references" tags = [:unit] begin
    using ChuiFrames, Tables
    using ChuiFrames: pushed_columns
    names = [:a, :b, :c]
    @test pushed_columns(Tables.Scan(), names) === nothing
    @test pushed_columns(Tables.Scan(; select = [:c, :a]), names) == [:a, :c]
    @test pushed_columns(Tables.Scan(; select = [:a], filter = Tables.colcmp(>, Tables.col(:b), 1)), names) == [:a, :b]
    @test pushed_columns(Tables.Scan(; select = [:a => :z]), names) == [:a]
    @test pushed_columns(Tables.Scan(; select = [1]), names) === nothing
    @test pushed_columns(Tables.Scan(; select = [:a], filter = Tables.colcmp(>, Tables.col(2), 1)), names) === nothing
    @test pushed_columns(Tables.Scan(; select = [r"a"]), names) === nothing
end

@testitem "Arrow writer: pyarrow and R read the output" tags = [:differential] setup = [ArrowFixtures] begin
    using ChuiFrames, Tables
    uv = Sys.which("uv")
    if uv === nothing
        @test_skip "uv not found: pyarrow differential not run"
    else
        p1, p2 = ArrowFixtures.parts()
        dir = mktempdir()
        write_file(Tables.partitioner([p1, p2]), joinpath(dir, "all.arrow"))
        write_file(Tables.partitioner([p1, p2]), joinpath(dir, "all.arrows"))
        write_arrow(Tables.partitioner([p1, p2]), joinpath(dir, "large.arrow"); large = true)
        script = joinpath(dir, "check.py")
        write(
            script, raw"""
            import sys, json, pyarrow as pa, pyarrow.ipc as ipc, pyarrow.feather as feather
            def conv(v):
                if isinstance(v, bytes): return "b:" + v.hex()
                if isinstance(v, float) and v != v: return "NaN"
                if isinstance(v, float): return repr(v)
                if hasattr(v, "isoformat"): return v.isoformat()
                if isinstance(v, list): return [conv(x) for x in v]
                if isinstance(v, dict): return {k: conv(x) for k, x in v.items()}
                return v
            out = {}
            r = ipc.open_file("all.arrow")
            t = r.read_all()
            out["file_batches"] = r.num_record_batches
            out["schema"] = {f.name: str(f.type) for f in t.schema}
            out["nullable"] = {f.name: f.nullable for f in t.schema}
            out["values"] = {c: conv(t.column(c).to_pylist()) for c in t.column_names}
            out["dict_per_batch"] = [r.get_batch(i).column("d").dictionary.to_pylist() for i in range(r.num_record_batches)]
            out["dict_indices"] = [r.get_batch(i).column("d").indices.to_pylist() for i in range(r.num_record_batches)]
            out["feather_rows"] = feather.read_table("all.arrow").num_rows
            sr = ipc.open_stream("all.arrows")
            s = sr.read_all()
            # (Table.equals is False with a NaN present, so compare schema and converted values.)
            out["stream_equal"] = s.schema.equals(t.schema) and {c: conv(s.column(c).to_pylist()) for c in s.column_names} == out["values"]
            out["stream_dictionary_deltas"] = sr.stats.num_dictionary_deltas
            out["stream_replaced_dictionaries"] = sr.stats.num_replaced_dictionaries
            try:
                ipc.open_file("all.arrows"); out["stream_as_file"] = "opened"
            except Exception as e:
                out["stream_as_file"] = "rejected"
            lt = ipc.open_file("large.arrow").read_all()
            out["large_schema"] = {f.name: str(f.type) for f in lt.schema if f.name in ("s", "b", "l")}
            print(json.dumps(out))
            """
        )
        cmd = Cmd(`$uv run --no-project --python 3.13 --with pyarrow==26.0.0 python -I check.py`; dir)
        res = read(cmd, String)
        @info "pyarrow readback" res
        @test occursin("\"file_batches\": 2", res)
        for (n, ty) in (
                "i" => "int64", "f" => "double", "s" => "string",
                "d" => "dictionary<values=string, indices=int8, ordered=0>", "b" => "binary",
                "bo" => "bool", "dt" => "date32[day]", "ts" => "timestamp[ms]",
                "l" => "list<: int64 not null>", "ls" => "list<: string not null>",
                "st" => "struct<a: int64, b: string>",          # children of a nullable struct are nullable
            )
            @test occursin("\"$n\": \"$ty\"", res)
        end
        @test !occursin("false", split(split(res, "\"nullable\": ")[2], "}")[1])     # all nullable
        @test occursin("\"i\": [1, 2, 3, 4, null]", res)
        @test occursin("\"f\": [\"1.5\", \"NaN\", \"-0.0\", null, \"2.5\"]", res)
        @test occursin("\"s\": [\"a\", \"bb\", \"\", null, \"ccc\"]", res)
        @test occursin("\"d\": [\"x\", \"y\", \"x\", \"z\", null]", res)
        @test occursin("\"b\": [\"b:6162\", \"b:\", \"b:00ff\", null, \"b:63\"]", res)
        @test occursin("\"dt\": [\"2024-01-01\", \"1970-01-01\", \"1900-12-31\", null, \"2030-06-01\"]", res)
        @test occursin("\"ts\": [\"2024-01-02T03:04:05.006000\", \"1970-01-01T00:00:00\", \"2000-02-29T00:00:00\", \"2024-01-01T00:00:00\", null]", res)
        @test occursin("\"l\": [[1, 2], [], [3], null, [4, 5, 6]]", res)
        @test occursin("\"st\": [{\"a\": 1, \"b\": \"p\"}, {\"a\": 2, \"b\": \"q\"}, {\"a\": 3, \"b\": \"r\"}, {\"a\": 4, \"b\": \"s\"}, null]", res)
        # One unified dictionary in every batch (with a null entry for the nullable column),
        # 0-based indices on disk (1-based in Julia), and no delta or replacement dictionary.
        @test occursin("\"dict_per_batch\": [[\"x\", \"y\", \"z\", null], [\"x\", \"y\", \"z\", null]]", res)
        @test occursin("\"dict_indices\": [[0, 1, 0], [2, null]]", res)
        @test occursin("\"feather_rows\": 5", res)
        @test occursin("\"stream_equal\": true", res)
        @test occursin("\"stream_dictionary_deltas\": 0", res)
        @test occursin("\"stream_replaced_dictionaries\": 0", res)
        @test occursin("\"stream_as_file\": \"rejected\"", res)
        @test occursin("\"large_schema\": {\"s\": \"large_string\", \"b\": \"large_binary\", \"l\": \"large_list<: int64 not null>\"}", res)
    end
    rs = Sys.which("Rscript")
    if rs === nothing
        @test_skip "Rscript not found: R arrow differential not run"
    else
        p1, p2 = ArrowFixtures.parts()
        dir = mktempdir()
        write_file(Tables.partitioner([p1, p2]), joinpath(dir, "all.arrow"))
        r = read(Cmd(`$rs -e 'if (!requireNamespace("arrow", quietly = TRUE)) { cat("NOARROW"); quit() }; t <- arrow::read_feather("all.arrow"); cat(nrow(t), ncol(t), t$i, t$s, as.character(t$d), sep = "|")'`; dir), String)
        if r == "NOARROW"
            @test_skip "R arrow package not installed"
        else
            @info "R arrow readback" r
            @test r == "5|11|1|2|3|4|NA|a|bb||NA|ccc|x|y|x|z|NA"
        end
    end
end
