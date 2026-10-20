# CSV over CSV.jl 1.x (ADR-0019): the source, the sink and the readr-style API. The
# :differential item compares read_csv with readr::read_csv on the same files (ADR-0019 rule 4).

@testitem "read_csv: inferred column kinds" tags = [:unit] begin
    using ChuiFrames, Dates
    using ChuiFrames: StringColumn, BoolColumn, PrimitiveColumn, StrView
    dir = mktempdir()
    p = joinpath(dir, "a.csv")
    write(p, "i,f,s,l,d,t,e\n1,2.5,x,TRUE,2024-01-02,2024-01-02T03:04:05,\n2,NA,,false,2024-01-03,2024-01-02 03:04:05.25,\n")
    f = read_csv(p)
    @test f.names == [:i, :f, :s, :l, :d, :t, :e]
    @test eltype(f.columns[1]) == Int64
    @test eltype(f.columns[2]) == Union{Missing, Float64}
    @test f.columns[3] isa StringColumn && eltype(f.columns[3]) == Union{Missing, StrView}
    @test f.columns[4] isa BoolColumn
    @test eltype(f.columns[5]) == Date
    @test eltype(f.columns[6]) == DateTime && f.columns[6][2] == DateTime(2024, 1, 2, 3, 4, 5, 250)
    @test eltype(f.columns[7]) == Union{Missing, Bool}            # all missing: logical, as readr
    @test isequal(collect(f.columns[3]), ["x", missing])
    # A timestamp with sub-millisecond digits reads exactly as an ArrowTimestamp (ADR-0021 rule 12).
    write(p, "t\n2024-01-02T03:04:05.123456\n")
    @test eltype(read_csv(p).columns[1]) === ArrowTimestamp{Dates.Nanosecond, nothing}
    @test Dates.value(read_csv(p).columns[1][1]) == 1_704_164_645_123_456_000
    @test collect(read_csv(p; col_types = (t = String,)).columns[1]) == ["2024-01-02T03:04:05.123456"]
end

@testitem "read_csv: readr arguments" tags = [:unit] begin
    using ChuiFrames, Dates
    dir = mktempdir()
    p = joinpath(dir, "b.csv")
    write(p, "junk line\nmore junk\nx,y,z\n1,a,2024-01-01\n# a comment\n2,-,2024-01-02\n3,c,2024-01-03\n")
    f = read_csv(p; skip = 2, comment = "#", na = ["-"])
    @test f.names == [:x, :y, :z] && f.nrow == 3
    @test isequal(collect(f.columns[2]), ["a", missing, "c"])
    @test read_csv(p; skip = 2, comment = "#", n_max = 2).nrow == 2
    g = read_csv(p; skip = 3, comment = "#", col_names = false)
    @test g.names == [:X1, :X2, :X3] && g.nrow == 3                 # readr's generated names
    # readr's logical spellings.
    @test collect(read_csv(Vector{UInt8}("a\nT\nfalse\nTrue\nF\n")).columns[1]) == [true, false, true, false]
    h = read_csv(p; skip = 3, comment = "#", col_names = [:a, :b, :c])
    @test h.names == [:a, :b, :c] && collect(h.columns[1]) == [1, 2, 3]
    # Column types: compact readr codes (with skip and guess), pairs, a NamedTuple.
    k = read_csv(p; skip = 2, comment = "#", col_types = "d_?")
    @test k.names == [:x, :z] && eltype(k.columns[1]) == Float64 && eltype(k.columns[2]) == Date
    @test eltype(read_csv(p; skip = 2, comment = "#", col_types = [:x => 'c']).columns[1]) == ChuiFrames.StrView
    @test eltype(read_csv(p; skip = 2, comment = "#", col_types = (x = Float64,)).columns[1]) == Float64
    @test_throws ArgumentError read_csv(p; col_types = "q")
    @test_throws ArgumentError read_csv(p; col_types = 42)
    # col_select keeps the named columns (in file order, as CSV.jl does).
    @test read_csv(p; skip = 2, comment = "#", col_select = [:z, :x]).names == [:x, :z]
    # Delimiters, TSV, whitespace trimming, quoting.
    q = joinpath(dir, "c.txt")
    write(q, "a;b\n 1 ; x \n2;\"p;q\"\n")
    m = read_csv(q; delim = ';')
    @test collect(m.columns[1]) == [1, 2] && collect(m.columns[2]) == ["x", "p;q"]
    @test collect(read_csv(q; delim = ';', trim_ws = false, col_types = "cc").columns[2]) == [" x ", "p;q"]
    t = joinpath(dir, "d.tsv")
    write(t, "a\tb\n1\tx\n")
    @test read_tsv(t).names == [:a, :b]
    @test read_file(t).names == [:a, :b]                           # .tsv: tab by default
    @test read_csv(Vector{UInt8}("a\n1\n")).nrow == 1
end

@testitem "CSV source: sequential batches, projection pushdown, residual" tags = [:unit] begin
    using ChuiFrames, Tables
    using ChuiFrames: frame_equal, read_source
    dir = mktempdir()
    p = joinpath(dir, "big.csv")
    open(p, "w") do io
        println(io, "i,s,f")
        for i in 1:500
            println(io, i, ",s", i, ",", i / 2)
        end
    end
    # Small byte windows give several batches; never assume a count.
    s = ChuiFrames.CSVSource(p; chunkbytes = 1024)
    hs, residual = ChuiFrames.plan_partitions(s, Tables.Scan(); morsel = 100)
    @test length(hs) > 1
    @test residual == Tables.Scan() || ChuiFrames._is_identity(residual)
    whole = read_csv(p)
    @test frame_equal(read_source(s), whole)
    # Handles out of order restart the sequential cursor.
    b3 = ChuiFrames.read_partition(s, hs[3])
    b1 = ChuiFrames.read_partition(s, hs[1])
    @test collect(b1.columns[1])[1] == 1
    @test frame_equal(b3, ChuiFrames.read_partition(s, hs[3]))
    # Projection is pushed through CSV.Chunks' select; the whole Scan is the residual.
    q = Tables.Scan(; select = [:f], filter = Tables.colcmp(>, Tables.col(:i), 495))
    hq, rq = ChuiFrames.plan_partitions(s, q; morsel = 100)
    @test rq === q
    @test ChuiFrames.read_partition(s, hq[1]).names == [:i, :f]
    r = read_source(s; scan = q)
    @test r.names == [:f] && collect(r.columns[1]) == [248.0, 248.5, 249.0, 249.5, 250.0]
    @test frame_equal(read_source(s; scan = Tables.Scan(; offset = 10, limit = 3)), ChuiFrames.take(whole, 11:13))
    @test ChuiFrames.isthreadsafe(s) === false
    @test ChuiFrames.source_label(s) == "CSV big.csv"
    # A header-only file: zero batches, the declared schema still holds.
    e = joinpath(dir, "e.csv")
    write(e, "a,b\n")
    fe = read_csv(e)
    @test fe.names == [:a, :b] && fe.nrow == 0
    @test_throws ArgumentError ChuiFrames.CSVSource(p; pool = true)
end

@testitem "CSV sink: round trip, atomic, unwritable kinds" tags = [:unit] begin
    using ChuiFrames, Tables, Dates
    using ChuiFrames: frame_equal
    dir = mktempdir()
    p = joinpath(dir, "w.csv")
    x = Frame(
        i = [1, 2, 3], f = [0.5, missing, -1.0e-8], s = ["plain", "with,comma \"q\"\nline", ""],
        m = Union{Missing, String}["a", missing, "c"], l = [true, false, missing],
        d = [Date(2024, 1, 1), Date(1999, 12, 31), Date(2000, 2, 29)],
        t = [DateTime(2024, 1, 2, 3, 4, 5, 6), DateTime(2020), DateTime(1999, 1, 1, 0, 0, 1)],
    )
    @test write_csv(x, p) == p
    y = read_csv(p)
    @test frame_equal(y, x)                                # "" stays "", missing stays missing
    @test startswith(read(p, String), "i,f,s,m,l,d,t\n")
    # Partitions are written sequentially under one header.
    write_file(Tables.partitioner([(a = [1],), (a = [2, 3],)]), p)
    @test read(p, String) == "a\n1\n2\n3\n"
    # TSV, na, no header.
    write_tsv((a = [1, missing],), joinpath(dir, "w.tsv"); na = "")
    @test read(joinpath(dir, "w.tsv"), String) == "a\n1\n\n"
    write_csv((a = [1],), joinpath(dir, "nh.csv"); col_names = false)
    @test read(joinpath(dir, "nh.csv"), String) == "1\n"
    # Empty input writes the header only.
    write_csv((a = Int[], b = String[]), joinpath(dir, "empty.csv"))
    @test read(joinpath(dir, "empty.csv"), String) == "a,b\n"
    # Kinds CSV cannot hold raise ArgumentError, and leave no file.
    sub = mktempdir()
    for bad in ((o = [:a],), (b = [codeunits("x")],), (l = [[1, 2]],), (st = [(a = 1,)],))
        @test_throws ArgumentError write_csv(bad, joinpath(sub, "bad.csv"))
    end
    @test readdir(sub) == String[]
    # An aborted write leaves no file; an existing file is kept.
    write_csv((a = [1],), joinpath(sub, "keep.csv"))
    @test_throws ArgumentError write_file(Tables.partitioner([(a = [1],), (a = ["x"],)]), joinpath(sub, "keep.csv"))
    @test read(joinpath(sub, "keep.csv"), String) == "a\n1\n"
    @test readdir(sub) == ["keep.csv"]
end

@testitem "read_csv against readr" tags = [:differential] begin
    using ChuiFrames, Dates
    rs = Sys.which("Rscript")
    if rs === nothing || !success(`$rs -e 'quit(status = !requireNamespace("readr", quietly = TRUE))'`)
        @test_skip "Rscript with readr not found: readr differential not run"
    else
        dir = mktempdir()
        # (name, file content, read_csv keywords, readr arguments, expected divergences)
        cases = [
            ("basic", "a,b,c,d,e\n1,x,2.5,TRUE,2024-01-02\n2,,NA,FALSE,2024-01-03\n3,z,4,NA,\n", (;), "", Set([:int_as_double])),
            ("na", "a,b\n1,-\n-,y\n3,z\n", (; na = ["-"]), "na = c(\"-\")", Set([:int_as_double])),
            ("na_keeps_empty", "a,b\n1,\n2,y\n", (; na = ["NA"]), "na = c(\"NA\")", Set([:int_as_double, :empty_is_missing])),
            ("skip", "junk\njunk2\nx,y\n1.5,a\n2.5,b\n", (; skip = 2), "skip = 2", Set{Symbol}()),
            ("comment", "x,y\n1.5,a\n# note\n2.5,b\n", (; comment = "#"), "comment = \"#\"", Set{Symbol}()),
            # readr also drops a trailing comment; CSV.jl only skips lines that start with it.
            ("comment_before_header", "junk\n# c\nx,y\n1.5,a\n", (; skip = 1, comment = "#"), "skip = 1, comment = \"#\"", Set{Symbol}()),
            ("comment_trailing", "x,y\n1.5,a # note\n2.5,b\n", (; comment = "#"), "comment = \"#\"", Set([:text_value])),
            ("n_max", "x\n1.5\n2.5\n3.5\n", (; n_max = 2), "n_max = 2", Set{Symbol}()),
            ("no_header", "1.5,a\n2.5,b\n", (; col_names = false), "col_names = FALSE", Set{Symbol}()),
            ("no_header_skip", "junk\n1.5,a,x\n2.5,b,y\n", (; col_names = false, skip = 1), "col_names = FALSE, skip = 1", Set{Symbol}()),
            ("col_types", "a,b,c\n1,2,x\n3,4,y\n", (; col_types = "dc_"), "col_types = \"dc_\"", Set{Symbol}()),
            ("quoted", "s,t\n\"a,b\",\"say \"\"hi\"\"\"\n\"multi\nline\",plain\n", (;), "", Set{Symbol}()),
            ("datetime", "t,d\n2024-01-02T03:04:05,2024-02-29\n2024-01-02 03:04:05.5,1999-12-31\n", (;), "", Set{Symbol}()),
            ("trim", "a,b\n x ,1.5\ny  ,2.5\n", (;), "", Set{Symbol}()),
            ("semicolon", "a;b\n1.5;x\n2.5;y\n", (; delim = ';'), "delim = \";\"", Set{Symbol}()),
            ("bools", "a\nTRUE\nfalse\nT\n", (;), "", Set{Symbol}()),
            # readr keeps numbers with leading zeros as character; CSV.jl parses them.
            ("leading_zero", "a\n007\n010\n", (;), "", Set([:type_mismatch])),
        ]
        # R: one line per column, "case<US>name<US>class<US>values...", NA as "\x01NA".
        DUMP_R = raw"""
        for (n in names(df)) {
          x <- df[[n]]
          cls <- class(x)[1]
          v <- if (inherits(x, "POSIXct")) format(x, "%Y-%m-%dT%H:%M:%OS3", tz = "UTC") else if (inherits(x, "Date")) as.character(x) else if (is.double(x)) sprintf("%.17g", x) else as.character(x)
          v[is.na(x)] <- "\x01NA"
          v <- gsub("\n", "\\\\n", v)
          writeLines(paste(c("@CASE@", n, cls, v), collapse = "\x1f"), out)
        }
        """
        script = IOBuffer()
        println(script, "suppressPackageStartupMessages(library(readr))")
        println(script, "out <- file(\"out.txt\", \"w\")")
        for (name, content, _, rargs, _) in cases
            write(joinpath(dir, name * ".csv"), content)
            fn = occursin("delim", rargs) ? "read_delim" : "read_csv"
            println(script, "df <- $fn(\"$name.csv\", show_col_types = FALSE, progress = FALSE$(isempty(rargs) ? "" : ", " * rargs))")
            println(script, replace(DUMP_R, "@CASE@" => name))
        end
        println(script, "close(out)")
        write(joinpath(dir, "check.R"), take!(script))
        run(Cmd(`$rs check.R`; dir))
        rows = Dict{String, Vector{Vector{String}}}()
        for line in eachline(joinpath(dir, "out.txt"))
            parts = split(line, '\x1f')
            push!(get!(rows, String(parts[1]), Vector{String}[]), String.(parts[2:end]))
        end
        rstr(x::Missing) = "\x01NA"
        rstr(x::AbstractString) = replace(String(x), "\n" => "\\n")
        rstr(x::Bool) = x ? "TRUE" : "FALSE"
        rstr(x::Date) = string(x)
        rstr(x::DateTime) = Dates.format(x, dateformat"yyyy-mm-ddTHH:MM:SS.sss")
        rstr(x::Real) = x
        rclass(T) = T <: AbstractString ? "character" : T <: Bool ? "logical" : T <: Real ? "numeric" :
            T === Date ? "Date" : T === DateTime ? "POSIXct" : string(T)
        report = String[]
        for (name, _, kw, _, allowed) in cases
            f = read_csv(joinpath(dir, name * ".csv"); kw...)
            r = rows[name]
            found = Set{Symbol}()
            names_r = [x[1] for x in r]
            if string.(f.names) != names_r
                push!(found, :column_names)       # readr X1, X2 vs CSV.jl Column1, Column2
            end
            @test length(r) == length(f.names)
            for (j, (n, cls, vals...)) in enumerate(r)
                c = f.columns[j]
                T = nonmissingtype(eltype(c))
                if rclass(T) != cls
                    push!(found, :type_mismatch)
                    push!(report, "$name/$n: readr class $cls vs ChuiFrames $T")
                end
                T === Int64 && cls == "numeric" && push!(found, :int_as_double)
                @test length(vals) == length(c)
                for (k, v) in enumerate(vals)
                    x = c[k]
                    ok = if v == "\x01NA" || ismissing(x)
                        v == "\x01NA" && ismissing(x)
                    elseif x isa Real && !(x isa Bool)
                        isapprox(parse(Float64, v), x; rtol = 1.0e-15)
                    else
                        rstr(x) == v
                    end
                    if !ok
                        if cls == "character" && v == "" && ismissing(x)
                            push!(found, :empty_is_missing)
                        elseif cls == "logical" || cls == "character"
                            push!(found, :text_value)
                        else
                            push!(found, :value_mismatch)
                        end
                        push!(report, "$name/$n[$k]: readr $(repr(v)) vs ChuiFrames $(repr(x))")
                    end
                end
            end
            push!(report, "$name: divergences $(sort(collect(found)))")
            @test found == allowed
        end
        println("readr differential report:\n", join(report, "\n"))
    end
end
