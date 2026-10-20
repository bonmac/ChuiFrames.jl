# Timestamps of every unit and zone (ADR-0021): files written by pyarrow 26.0.0, Polars 2.0.0
# and R arrow 23.0.1.1, checked against pyarrow's dumps, which hold the raw Int64 counts.

@testmodule TSCorpus begin
    using ChuiFrames: ChuiFrames, ArrowTimestamp, getcol
    const CASES = ("timestamps_pyarrow", "timestamps_pyarrow_stream", "polars_timestamps", "polars_timestamps_stream", "r_timestamps")

    "The element types of a column, recursively (list children, struct fields, dictionary values)."
    sig(c) = Any[eltype(c)]
    sig(c::ChuiFrames.ListColumn) = Any[eltype(c), sig(c.child)]
    sig(c::ChuiFrames.StructColumn) = Any[eltype(c), [k => sig(v) for (k, v) in pairs(c.children)]]
    sig(c::ChuiFrames.DictColumn) = Any[eltype(c), sig(c.dict)]
    framesig(t) = [n => sig(getcol(t, n)) for n in ChuiFrames.columnnames(t)]

    "Raw counts of a dumped column of flat timestamps (`nothing` for nulls)."
    raws(doc, name) = [x === nothing ? nothing : x["ts"][1] for x in doc["columns"][name]]
    isflat_ts(f) = startswith(f["type"], "timestamp[") || startswith(f["type"], "dictionary<values=timestamp[")
end

@testitem "ipc: timestamps of every unit and zone match the pyarrow dumps" tags = [:unit, :ipc] setup = [IPCCorpus, TSCorpus] begin
    for case in TSCorpus.CASES
        IPCCorpus.checkcase(case)
    end
end

@testitem "ipc: timestamp element types carry unit and zone exactly" tags = [:unit, :ipc] setup = [IPCCorpus, TSCorpus] begin
    using ChuiFrames: ArrowTimestamp, getcol, read_ipc, ListColumn, StructColumn, DictColumn, PrimitiveColumn
    using Dates: Second, Millisecond, Microsecond, Nanosecond, DateTime
    for case in ("timestamps_pyarrow", "timestamps_pyarrow_stream")
        t = read_ipc(IPCCorpus.casepath(case))
        @test eltype(getcol(t, :s)) === ArrowTimestamp{Second, nothing}                         # non-nullable
        @test eltype(getcol(t, :ms_utc)) === Union{Missing, ArrowTimestamp{Millisecond, :UTC}}   # zoned ms: not DateTime
        @test eltype(getcol(t, :us)) === Union{Missing, ArrowTimestamp{Microsecond, nothing}}
        @test eltype(getcol(t, :us_berlin)) === ArrowTimestamp{Microsecond, Symbol("Europe/Berlin")}
        @test eltype(getcol(t, :ns)) === ArrowTimestamp{Nanosecond, nothing}
        @test eltype(getcol(t, :ns_kolkata)) === Union{Missing, ArrowTimestamp{Nanosecond, Symbol("+05:30")}}
        @test getcol(t, :s) isa PrimitiveColumn
        d = getcol(t, :dict_us)
        @test d isa DictColumn
        @test eltype(d) === Union{Missing, ArrowTimestamp{Microsecond, nothing}}
        l = getcol(t, :lst_ns)
        @test l isa ListColumn
        @test eltype(l.child) === Union{Missing, ArrowTimestamp{Nanosecond, nothing}}
        s = getcol(t, :st)
        @test s isa StructColumn
        @test eltype(s.children.t) === Union{Missing, ArrowTimestamp{Microsecond, :UTC}}
    end
    for case in ("polars_timestamps", "polars_timestamps_stream")
        t = read_ipc(IPCCorpus.casepath(case))
        @test eltype(getcol(t, :us)) === Union{Missing, ArrowTimestamp{Microsecond, nothing}}       # Polars' default
        @test eltype(getcol(t, :ns_utc)) === Union{Missing, ArrowTimestamp{Nanosecond, :UTC}}
        @test eltype(getcol(t, :ms_berlin)) === Union{Missing, ArrowTimestamp{Millisecond, Symbol("Europe/Berlin")}}
        @test eltype(getcol(t, :range)) === Union{Missing, ArrowTimestamp{Microsecond, nothing}}
    end
    t = read_ipc(IPCCorpus.casepath("r_timestamps"))
    @test eltype(getcol(t, :utc)) === Union{Missing, ArrowTimestamp{Microsecond, :UTC}}
    @test eltype(getcol(t, :naive)) === Union{Missing, ArrowTimestamp{Microsecond, nothing}}  # tzone ""
    @test eltype(getcol(t, :ny)) === Union{Missing, ArrowTimestamp{Microsecond, Symbol("America/New_York")}}
    @test eltype(getcol(t, :frac)) === Union{Missing, ArrowTimestamp{Microsecond, :UTC}}
    @test IPCCorpus.expected_valuetype("timestamp[ms]") === DateTime        # ms naive stays DateTime
end

@testitem "ipc: ns timestamps keep 1 ns differences, Int64 limits and distinctness" tags = [:unit, :ipc] setup = [IPCCorpus, TSCorpus] begin
    using ChuiFrames: getcol, read_ipc, distinct, nrows
    using Dates: Dates
    for case in ("timestamps_pyarrow", "timestamps_pyarrow_stream")
        t = read_ipc(IPCCorpus.casepath(case))
        ns = collect(getcol(t, :ns))
        @test Dates.value.(ns[1:2]) == [1_700_000_000_000_000_000, 1_700_000_000_000_000_001]
        @test !isequal(ns[1], ns[2]) && ns[1] != ns[2] && isless(ns[1], ns[2])
        @test Dates.value(ns[5]) === typemax(Int64)
        @test Dates.value(ns[6]) === typemin(Int64)
        @test Dates.value(ns[4]) == -1_000_000_000_000_000_001                 # pre-1970
        @test ns[3] < ns[7]                                                      # -1 ns < 0 ns
        @test length(unique(ns)) == length(unique(Dates.value.(ns)))
        @test nrows(distinct(:ns)(t)) == length(unique(Dates.value.(ns)))       # the verb, not just Base
        lst = getcol(t, :lst_ns)
        @test !isequal(collect(lst[6])[1], collect(lst[6])[2])
    end
    # every flat timestamp column of every case: as many distinct values as distinct raw counts
    for case in TSCorpus.CASES
        doc = IPCCorpus.loaddump(case)
        t = read_ipc(IPCCorpus.casepath(case))
        for f in doc["schema"]
            TSCorpus.isflat_ts(f) || continue
            col = collect(getcol(t, Symbol(f["name"])))
            ok = length(unique(col)) == length(unique(TSCorpus.raws(doc, f["name"])))
            ok || @info "distinct count differs" case f["name"]
            @test ok
            @test length(Set(col)) == length(unique(col))                      # hash agrees with isequal
        end
    end
end

@testitem "ipc: timestamps round-trip through write_arrow with unit and zone" tags = [:unit, :ipc] setup = [IPCCorpus, TSCorpus] begin
    using ChuiFrames: read_ipc, write_arrow, read_arrow, frame_equal
    mktempdir() do dir
        for case in TSCorpus.CASES, ext in (".arrow", ".arrows")
            t = read_ipc(IPCCorpus.casepath(case))
            p = write_arrow(t, joinpath(dir, case * ext))
            r = read_arrow(p)
            ok = frame_equal(r, t)
            ok || @info "round trip differs" case ext
            @test ok
            same = TSCorpus.framesig(r) == TSCorpus.framesig(t)
            same || @info "round trip types differ" case ext TSCorpus.framesig(t) TSCorpus.framesig(r)
            @test same          # with equal instants (frame_equal), equal types mean equal raw counts
        end
    end
end
