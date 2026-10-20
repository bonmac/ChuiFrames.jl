# ArrowTimestamp (ADR-0021): the type's laws, conversion, text, ingest, and round trips through
# Arrow, CSV and Parquet. Corpus cases from Polars, pyarrow and R arrow are in test/ipc/.

@testitem "ArrowTimestamp: equality, hashing and order by exact instant (ADR-0021 rules 3-5)" tags = [:unit] begin
    using Dates
    const TS = ArrowTimestamp
    ms, us, ns = TS{Millisecond}(1), TS{Microsecond}(1_000), TS{Nanosecond}(1_000_000)
    @test ms == us == ns && isequal(ms, ns) && hash(ms) == hash(us) == hash(ns)
    @test ms == DateTime(1970, 1, 1, 0, 0, 0, 1) && hash(ms) == hash(DateTime(1970, 1, 1, 0, 0, 0, 1))
    @test TS{Nanosecond}(1) != TS{Nanosecond}(2) && TS{Nanosecond}(1) < TS{Microsecond}(1)
    # zones: by UTC instant, whatever the zone; naive vs zoned throws for ==/<, isequal is false
    utc, ber = TS{Microsecond, :UTC}(5), TS{Nanosecond, Symbol("Europe/Berlin")}(5_000)
    @test utc == ber && isequal(utc, ber) && hash(utc) == hash(ber)
    naive = TS{Microsecond}(5)
    @test_throws ArgumentError naive == utc
    @test_throws ArgumentError utc == DateTime(1970)
    @test_throws ArgumentError naive < utc
    @test_throws ArgumentError isless(DateTime(1970), utc)
    @test !isequal(naive, utc) && !isequal(utc, DateTime(1970))
    @test length(Set{Any}(Any[TS{Millisecond}(0), TS{Nanosecond}(0), DateTime(1970), TS{Second, :UTC}(0), TS{Nanosecond, :X}(0)])) == 2
    # constructor checks
    @test_throws ArgumentError TS{Day, nothing}(1)
    @test_throws ArgumentError TS{Second, Symbol("")}(1)
    @test_throws ArgumentError TS{Second, 1}(1)
    @test ChuiFrames.timestamp_unit(ns) === Nanosecond && ChuiFrames.timestamp_zone(ber) === Symbol("Europe/Berlin")
    @test Dates.value(ber) == 5_000
end

@testitem "ArrowTimestamp: conversion, arithmetic and text (ADR-0021 rules 6, 7, 9)" tags = [:unit] begin
    using Dates
    const TS = ArrowTimestamp
    # DateTime floors (monotone), zoned values give UTC
    @test DateTime(TS{Nanosecond}(-1)) == DateTime(1969, 12, 31, 23, 59, 59, 999)
    @test DateTime(TS{Microsecond}(1_999)) == DateTime(1970, 1, 1, 0, 0, 0, 1)
    @test DateTime(TS{Second, :UTC}(60)) == DateTime(1970, 1, 1, 0, 1)
    @test Date(TS{Second}(86_400)) == Date(1970, 1, 2)
    @test_throws InexactError DateTime(TS{Second}(typemax(Int64)))
    @test (year(TS{Microsecond}(1_704_164_645_123_456)), microsecond(TS{Microsecond}(1_704_164_645_123_456)), nanosecond(TS{Nanosecond}(7))) == (2024, 456, 7)
    # exact or InexactError
    @test TS{Microsecond}(DateTime(2024, 1, 2)) == DateTime(2024, 1, 2)
    @test_throws InexactError TS{Second}(DateTime(2024, 1, 2, 0, 0, 0, 5))
    @test_throws InexactError TS{Nanosecond}(DateTime(3000))           # ns spans 1677-2262
    @test TS{Millisecond}(TS{Nanosecond}(2_000_000)) === TS{Millisecond}(2)
    @test_throws InexactError TS{Millisecond}(TS{Nanosecond}(1))
    @test_throws ArgumentError TS{Second, :UTC}(TS{Second, :CET}(1))   # zones are not converted
    @test convert(TS{Microsecond, nothing}, DateTime(1970)) === TS{Microsecond}(0)
    @test_throws MethodError convert(ArrowTimestamp, DateTime(1970))  # only fully specified targets
    # arithmetic: fixed periods exact, calendar periods refused, differences in the finer unit
    @test TS{Second}(0) + Day(1) === TS{Second}(86_400)
    @test TS{Second}(0) + Week(2) === TS{Second}(1_209_600)
    @test TS{Second}(0) + Second(10^10) === TS{Second}(10^10)
    @test TS{Microsecond}(5) - Nanosecond(1000) === TS{Microsecond}(4)
    @test_throws InexactError TS{Millisecond}(0) + Microsecond(1)
    @test_throws ArgumentError TS{Second}(0) + Month(1)
    @test TS{Microsecond}(5) - TS{Nanosecond}(1) == Nanosecond(4_999)
    @test DateTime(1970) - TS{Microsecond}(1) == Microsecond(-1)
    @test_throws ArgumentError TS{Second}(0) - TS{Second, :UTC}(0)
    # text: the unit's digits, Z when zoned, expanded years outside 0000-9999
    @test string(TS{Second}(1)) == "1970-01-01T00:00:01"
    @test string(TS{Millisecond, :UTC}(5)) == "1970-01-01T00:00:00.005Z"
    @test string(TS{Microsecond}(1_704_164_645_123_456)) == "2024-01-02T03:04:05.123456"
    @test string(TS{Nanosecond}(-1)) == "1969-12-31T23:59:59.999999999"
    @test string(TS{Second}(-62_135_596_800 - 86_400)) == "0000-12-31T00:00:00"
    @test string(TS{Second}(typemax(Int64))) == "+292277026596-12-04T15:30:07"
    @test startswith(sprint(show, TS{Second}(typemin(Int64))), "ArrowTimestamp{Dates.Second, nothing}(-9223372036854775808)")
    @test endswith(sprint(show, [TS{Microsecond, :UTC}(1)]), "Microsecond, :UTC}[1970-01-01T00:00:00.000001Z]")
end

@testitem "ArrowTimestamp: ingest, concatenation and printing (ADR-0021 rules 1, 7, 8)" tags = [:unit] begin
    using Dates, Tables
    const TS = ArrowTimestamp
    f = Frame(t = [TS{Microsecond}(1), missing, TS{Microsecond}(3)], z = [TS{Nanosecond, :UTC}(1), TS{Nanosecond, :UTC}(2), TS{Nanosecond, :UTC}(3)])
    tc = getfield(f, :columns)[1]
    @test tc isa ChuiFrames.PrimitiveColumn && eltype(tc) === Union{Missing, TS{Microsecond, nothing}}
    @test Dates.value(tc.values[2]) == 0                                 # zero-null-slot invariant
    # promotion to the finer unit, exactly; mixed kinds and zones raise
    col(v) = ChuiFrames.column(v)
    v = ChuiFrames.vcat_columns([col([TS{Microsecond}(1)]), col([DateTime(1970)])])
    @test eltype(v) === TS{Microsecond, nothing} && collect(v) == [TS{Microsecond}(1), TS{Microsecond}(0)]
    @test eltype(ChuiFrames.vcat_columns([col([TS{Second, :UTC}(1)]), col([TS{Nanosecond, :UTC}(1)])])) === TS{Nanosecond, :UTC}
    @test_throws ArgumentError ChuiFrames.vcat_columns([col([TS{Microsecond}(1)]), col([TS{Microsecond, :UTC}(1)])])
    @test_throws ArgumentError ChuiFrames.vcat_columns([col([TS{Microsecond, :UTC}(1)]), col([TS{Microsecond, :CET}(1)])])
    @test_throws ArgumentError ChuiFrames.vcat_columns([col([TS{Nanosecond}(1)]), col([DateTime(3000)])])
    @test_throws ArgumentError bind_rows((t = [TS{Microsecond, :UTC}(1)],))((t = [TS{Microsecond}(1)],))
    # abstract element types narrow to the values' type (critic): never an object column
    @test col(TS{Microsecond}[TS{Microsecond}(1), TS{Microsecond}(2)]) isa ChuiFrames.PrimitiveColumn{TS{Microsecond, nothing}}
    @test eltype(col(Union{Missing, ArrowTimestamp, DateTime}[TS{Microsecond}(1), missing, DateTime(1970)])) === Union{Missing, TS{Microsecond, nothing}}
    @test col(Any[TS{Microsecond}(1)]) isa ChuiFrames.ObjectColumn      # Any stays an object column (ADR-0001 rule 12)
    # an Any column mixing naive and zoned values groups in first-seen order (rule 5), never crashes
    mix = Frame([:t], ChuiFrames.AbstractColumn[col(Any[TS{Microsecond, :UTC}(1), TS{Microsecond}(2), TS{Microsecond, :UTC}(1)])])
    @test collect(Tables.getcolumn(summarise(n = n_rows())(group_by(:t)(mix)), :n)) == [2, 1]
    @test_throws ArgumentError arrange(c.t)(mix)
    # broadcasting a timestamp scalar
    @test ([TS{Microsecond}(0)] .== TS{Microsecond}(0)) == [true]
    # verbs: grouping keeps ns-distinct values apart; arrange orders by instant
    g = Frame(t = TS{Nanosecond}.([3, 1, 2, 1]), x = 1:4) |> group_by(:t) |> summarise(n = n_rows())
    @test collect(Tables.getcolumn(g, :t)) == TS{Nanosecond}.([1, 2, 3]) && collect(Tables.getcolumn(g, :n)) == [2, 1, 1]
    a = Frame(t = [TS{Microsecond}(5), TS{Microsecond}(-5), TS{Microsecond}(0)]) |> arrange(desc(c.t))
    @test Dates.value.(collect(Tables.getcolumn(a, :t))) == [5, 0, -5]
    @test collect(Tables.getcolumn(filter(c.t .> TS{Microsecond}(0))(a), :t)) == [TS{Microsecond}(5)]
    @test_throws ArgumentError filter(c.z .== DateTime(1970))(f)          # zoned vs naive throws, never silently empty
    # printing: unit and zone in the header, UTC text with Z
    s = sprint(show, MIME("text/plain"), f; context = :displaysize => (24, 100))
    @test occursin("<dttm[us]?>", s) && occursin("<dttm[ns, UTC]>", s) && occursin("1970-01-01T00:00:00.000000001Z", s)
end

@testitem "ArrowTimestamp: Arrow IPC round trip keeps unit and zone (ADR-0021 rule 10)" tags = [:unit] begin
    using Dates, Tables
    const TS = ArrowTimestamp
    f = Frame(
        s = TS{Second}.([1, 2]), us = [TS{Microsecond}(1_704_164_645_123_456), missing],
        ns_b = TS{Nanosecond, Symbol("Europe/Berlin")}.([-1, typemax(Int64)]),
        ms_utc = TS{Millisecond, :UTC}.([5, 6]), off = TS{Second, Symbol("+05:30")}.([0, 1]), dt = [DateTime(2020), DateTime(2021)],
    )
    mktempdir() do dir
        for p in (joinpath(dir, "t.arrow"), joinpath(dir, "t.arrows"))
            write_arrow(f, p)
            g = read_arrow(p)
            @test ChuiFrames.frame_equal(f, g)
            @test [eltype(c) for c in getfield(g, :columns)] == [eltype(c) for c in getfield(f, :columns)]
            @test all(Dates.value.(skipmissing(Tables.getcolumn(g, n))) == Dates.value.(skipmissing(Tables.getcolumn(f, n))) for n in (:s, :us, :ns_b, :ms_utc, :off))
        end
        # a dictionary-encoded timestamp column writes plain Arrow values (no extension tag)
        d = ChuiFrames.DictColumn(UInt8[1, 2, 1], ChuiFrames.column(TS{Microsecond}.([7, 8])))
        p = joinpath(dir, "d.arrow")
        write_arrow(Frame([:d], ChuiFrames.AbstractColumn[d]), p)
        @test collect(Tables.getcolumn(read_arrow(p), :d)) == TS{Microsecond}.([7, 8, 7])
    end
end

@testitem "ArrowTimestamp: CSV reads exactly, writes ISO text, parses col_types (ADR-0021 rule 12)" tags = [:unit] begin
    using Dates, Tables
    const TS = ArrowTimestamp
    mktempdir() do dir
        p = joinpath(dir, "a.csv")
        write(p, "t,u,v\n2024-01-02T03:04:05.123456,2024-01-02T03:04:05.123,2024-01-02T03:04:05.000001\n2024-01-02T03:04:05.000000001,NA,2024-01-02T03:04:05\n")
        f = read_csv(p)
        @test eltype(Tables.getcolumn(f, :t)) === TS{Nanosecond, nothing}          # any finer digit: ns
        @test eltype(Tables.getcolumn(f, :u)) === Union{Missing, DateTime}          # whole ms: DateTime
        @test Dates.value.(collect(Tables.getcolumn(f, :t))) == [1_704_164_645_123_456_000, 1_704_164_645_000_000_001]
        # write: the unit's digits, Z when zoned; read back exactly with col_types
        g = Frame(z = [TS{Microsecond, :UTC}(1_704_164_645_123_456), missing], n = TS{Nanosecond}.([-1, 5]), s = TS{Second}.([1, 2]))
        q = joinpath(dir, "g.csv")
        write_csv(g, q)
        @test read(q, String) == "z,n,s\n2024-01-02T03:04:05.123456Z,1969-12-31T23:59:59.999999999,1970-01-01T00:00:01\nNA,1970-01-01T00:00:00.000000005,1970-01-01T00:00:02\n"
        h = read_csv(q; col_types = (z = TS{Microsecond, :UTC}, s = TS{Second}))
        @test isequal(collect(Tables.getcolumn(h, :z)), collect(Tables.getcolumn(g, :z)))
        @test collect(Tables.getcolumn(h, :n)) == collect(Tables.getcolumn(g, :n))
        @test eltype(Tables.getcolumn(h, :s)) === Union{Missing, TS{Second, nothing}}
        # the ISO parser: offsets shift to UTC, naive targets refuse suffixes, extra digits raise
        P = ChuiFrames.parse_timestamp
        @test P(TS{Second, :UTC}, "2024-01-01T13:00:00+01:00") == P(TS{Second, :UTC}, "2024-01-01 12:00:00Z")
        @test P(TS{Second, :UTC}, "2024-01-01T07:00:00-0500") == P(TS{Second, :UTC}, "2024-01-01T12:00:00Z")
        @test P(TS{Nanosecond, nothing}, "1969-12-31T23:59:59.999999999") === TS{Nanosecond}(-1)
        @test_throws ArgumentError P(TS{Second, nothing}, "2024-01-01T13:00:00Z")
        @test_throws ArgumentError P(TS{Second, nothing}, "2024-01-01T13:00:00.5")
        @test_throws ArgumentError P(TS{Second, nothing}, "2024-01-01")
        @test_throws ArgumentError P(TS{Second, :UTC}, "2024-01-01T12:00:00+99:99")   # bad offset
        @test_throws ArgumentError P(TS{Second, nothing}, "2023-02-29T00:00:00")       # no such day
        # the parser reads every text form ChuiFrames writes, including expanded years
        for t in (TS{Second}(typemax(Int64)), TS{Second}(typemin(Int64)), TS{Microsecond}(-10^19 ÷ 2), TS{Nanosecond}(-1), TS{Second}(-62_135_596_800 - 86_400))
            @test P(typeof(t), string(t)) === t
        end
        # a first batch outside the ns range reads as microseconds
        o = joinpath(dir, "o.csv")
        write(o, "t\n1600-01-01T00:00:00.000001\n")
        @test eltype(read_csv(o).columns[1]) === TS{Microsecond, nothing}
        r = joinpath(dir, "r.csv")
        write(r, "t\n2024-01-01T00:00:00Z\nnot a time\n")
        @test_throws ArgumentError read_csv(r; col_types = (t = TS{Second, :UTC},))
        # an explicit DateTime target (readr `T`) is exact: whole ms read, finer digits raise
        # naming ArrowTimestamp, never `missing` (review M1)
        d = joinpath(dir, "d.csv")
        write(d, "t\n2024-01-01T00:00:00.123\n2024-01-01 00:00:01\n")
        @test read_csv(d; col_types = "T").columns[1] == [DateTime(2024, 1, 1, 0, 0, 0, 123), DateTime(2024, 1, 1, 0, 0, 1)]
        write(d, "t\n2024-01-01T00:00:00.123456\n")
        for ct in ("T", (t = DateTime,))
            err = try
                read_csv(d; col_types = ct)
                nothing
            catch e
                e
            end
            @test err isa ArgumentError && occursin("ArrowTimestamp{Nanosecond}", err.msg)
        end
        # ArrowTimestamp with no unit raises an ArgumentError asking for one (review m3)
        err = try
            read_csv(d; col_types = (t = TS,))
            nothing
        catch e
            e
        end
        @test err isa ArgumentError && occursin("give ArrowTimestamp a unit", err.msg)
    end
    # a struct column with a timestamp field may have missing parents (review m4)
    NT = NamedTuple{(:t,), Tuple{TS{Microsecond, nothing}}}
    f = Frame(s = Union{Missing, NT}[(t = TS{Microsecond}(5),), missing])
    @test isequal(collect(f.columns[1]), Union{Missing, NT}[(t = TS{Microsecond}(5),), missing])
end

@testitem "ArrowTimestamp: property laws (isequal ⇒ hash, strict order, floor monotone)" tags = [:property] begin
    using Supposition, Supposition.Data, Dates
    const TS = ArrowTimestamp
    units = (Second, Millisecond, Microsecond, Nanosecond)
    # values small enough that every unit's instant stays comparable, with ties across units
    raw = Data.Integers(-10^12, 10^12)               # microseconds since 1970
    near = Data.Integers(-2, 2)
    # naive values in any unit, or a DateTime; zoned values in any unit and two zones
    kinds = Data.SampledFrom(Any[units..., DateTime])
    zones = Data.SampledFrom([:UTC, Symbol("Europe/Berlin")])
    ugen = Data.SampledFrom(collect(units))
    count(u, x) = u === Second ? fld(x, 10^6) : u === Millisecond ? fld(x, 10^3) : u === Microsecond ? x : x * 1000
    mk(k, x, z) = k === DateTime ? DateTime(1970) + Millisecond(fld(x, 10^3)) : TS{k, z}(count(k, x))
    # pairs drawn from one instant (plus a step of -2..2 µs), so ties across units are common
    naivepair = @composed function np(k1 = kinds, k2 = kinds, x = raw, d = near)
        return (mk(k1, x, nothing), mk(k2, x + d, nothing))
    end
    zonedpair = @composed function zp(u1 = ugen, u2 = ugen, z1 = zones, z2 = zones, x = raw, d = near)
        return (mk(u1, x, z1), mk(u2, x + d, z2))
    end
    law(h) = function (p)
        a, b = p
        return (!isequal(a, b) || h(a) == h(b)) && (isless(a, b) + isless(b, a) + isequal(a, b) == 1) &&
            (!isless(a, b) || DateTime(a) <= DateTime(b))
    end
    for gen in (naivepair, zonedpair)
        r = @check record = false db = false max_examples = 2000 law(hash)(gen)
        @test Supposition.results(r).ispass
    end
    # the planted violation, through the same law and the same generator: a hash of the raw
    # count ignores the unit, so equal instants in different units must be caught
    badhash(t) = hash(Dates.value(t))
    r2 = @check record = false db = false max_examples = 2000 law(badhash)(naivepair)
    @test !Supposition.results(r2).ispass
    # exact conversion (ADR-0021 rule 6): to any naive unit, the value is kept or InexactError
    conv(p) = all(units) do u
        a = p[1]
        try
            isequal(convert(TS{u, nothing}, a), a)
        catch err
            err isa InexactError
        end
    end
    r3 = @check record = false db = false max_examples = 2000 conv(naivepair)
    @test Supposition.results(r3).ispass
end
