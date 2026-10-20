# The reader's refusals (ADR-0001 rules 5, 6, 10): unsupported types name the type, and a
# corrupt or truncated input raises ArgumentError (never a crash or silent garbage).

@testitem "ipc: unsupported Arrow types raise ArgumentError naming the type" tags = [:unit, :ipc] setup = [IPCCorpus] begin
    using ChuiFrames: read_ipc, read_ipc_batches, read_ipc_schema
    cases = [
        "unsupported_decimal" => "Decimal128(5, 2)", "unsupported_time" => "Time64(MICROSECOND)",
        "unsupported_ree" => "RunEndEncoded", "unsupported_tsus" => "Timestamp(MICROSECOND)",
        "unsupported_tsns" => "Timestamp(NANOSECOND)", "unsupported_tss" => "Timestamp(SECOND)",
        "unsupported_tsmstz" => "Timestamp(MILLISECOND, timezone = \"UTC\")",
        "unsupported_date64" => "Date64", "unsupported_float16" => "Float16",
        "unsupported_duration" => "Duration(SECOND)", "unsupported_interval" => "Interval",
        "unsupported_fixedsizebinary" => "FixedSizeBinary(2)", "unsupported_fixedsizelist" => "FixedSizeList(2)",
        "unsupported_map" => "Map", "unsupported_union" => "Union", "unsupported_null" => "Null",
        "unsupported_listview" => "ListView", "unsupported_largelistview" => "LargeListView",
        "unsupported_extension" => "extension<arrow.uuid>", "ordered_dict" => "ordered dictionary",
    ]
    for (case, needle) in cases
        p = IPCCorpus.casepath(case)
        for f in (read_ipc, read_ipc_batches, read_ipc_schema)
            e = IPCCorpus.outcome(() -> f(p))
            ok = e isa ArgumentError && occursin(needle, e.msg) && occursin("\"x\"", e.msg)
            ok || @info "unexpected outcome" case f e
            @test ok
        end
    end
    e = IPCCorpus.outcome(() -> read_ipc(IPCCorpus.casepath("unsupported_tsus")))
    @test occursin("ArrowTimestamp", e.msg)          # points at the deferred phase-2 ADR
end

@testitem "ipc: hand-built stream (positive control), big-endian schema, old metadata" tags = [:unit, :ipc] setup = [IPCCorpus] begin
    using ChuiFrames: read_ipc, read_ipc_schema, getcol, StrView
    t = read_ipc(IPCCorpus.handmade_stream())
    @test isequal(collect(getcol(t, :x)), [7, missing])
    @test collect(getcol(t, :s)) == ["ab", "cde"]
    @test eltype(getcol(t, :s)) === Union{Missing, StrView}
    e = IPCCorpus.outcome(() -> read_ipc(IPCCorpus.handmade_stream(; endianness = 1)))
    @test e isa ArgumentError && occursin("big-endian", e.msg)
    e = IPCCorpus.outcome(() -> read_ipc_schema(IPCCorpus.handmade_stream(; endianness = 1)))
    @test e isa ArgumentError && occursin("big-endian", e.msg)
    old = IPCCorpus.ipc_stream([(IPCCorpus.schema_msg([IPCCorpus.fb_field("x", IPCCorpus.T_INT64)]; version = 2), UInt8[])])
    e = IPCCorpus.outcome(() -> read_ipc(old))
    @test e isa ArgumentError && occursin("metadata version", e.msg)
end

@testitem "ipc: corrupt offsets, indices and nulls raise ArgumentError" tags = [:unit, :ipc] setup = [IPCCorpus] begin
    using ChuiFrames: read_ipc
    bad(bytes, needle) = (e = IPCCorpus.outcome(() -> read_ipc(bytes)); e isa ArgumentError && occursin(needle, e.msg))
    @test bad(IPCCorpus.handmade_stream(; offsets = [0, 2, 100]), "out of range")      # past the data
    @test bad(IPCCorpus.handmade_stream(; offsets = [0, 4, 2]), "decrease")
    @test bad(IPCCorpus.handmade_stream(; offsets = [-3, 2, 5]), "out of range")
    # a non-nullable field holding nulls
    S = IPCCorpus
    fields = [S.fb_field("x", S.T_INT64; nullable = false)]
    body = vcat(S.pad8(UInt8[0x01]), S.bytesof(Int64, [1, 2]))
    st = S.ipc_stream([(S.schema_msg(fields), UInt8[]), (S.batch_msg(2, [(2, 1)], [(0, 1), (8, 16)], length(body)), body)])
    @test bad(st, "non-nullable")
    # a buffer outside the body, and a batch whose node length disagrees with the batch length
    st = S.ipc_stream([(S.schema_msg(fields), UInt8[]), (S.batch_msg(2, [(2, 0)], [(0, 0), (8, 64)], length(body)), body)])
    @test bad(st, "outside the message body")
    st = S.ipc_stream([(S.schema_msg(fields), UInt8[]), (S.batch_msg(3, [(2, 0)], [(0, 0), (8, 16)], length(body)), body)])
    @test bad(st, "the batch length governs")
    # huge node lengths whose byte size overflows Int64 (found by the fuzz test on Julia 1.10)
    for n in (2^39, 2^61, 2^61 + 1, 2^62, typemax(Int64))
        needle = n <= 2^40 ? "needed" : "bad field node"     # past 2^40 rows the node itself is refused
        huge = S.ipc_stream([(S.schema_msg(fields), UInt8[]), (S.batch_msg(n, [(n, 0)], [(0, 0), (8, 16)], length(body)), body)])
        @test bad(huge, needle)
        sfields = [S.fb_field("s", S.T_UTF8)]
        huge = S.ipc_stream([(S.schema_msg(sfields), UInt8[]), (S.batch_msg(n, [(n, 0)], [(0, 0), (0, 8), (8, 8)], length(body)), body)])
        @test bad(huge, needle)
    end
    # buffer and body lengths near typemax(Int64) (the range checks subtract instead of adding)
    st = S.ipc_stream([(S.schema_msg(fields), UInt8[]), (S.batch_msg(2, [(2, 0)], [(0, 0), (typemax(Int64) - 4, 16)], length(body)), body)])
    @test bad(st, "outside the message body")
    st = S.ipc_stream([(S.schema_msg(fields), UInt8[]), (S.batch_msg(2, [(2, 0)], [(0, 0), (8, 16)], typemax(Int64)), body)])
    @test bad(st, "runs past the end")
    # dictionary: an index past the dictionary, and a batch before its dictionary
    dfields = [S.fb_field("d", S.T_UTF8; dict = (0, 8))]
    dbody = vcat(S.pad8(S.bytesof(Int32, [0, 1, 2])), S.pad8(collect(codeunits("ab"))))
    dmsg = (S.dict_msg(0, 2, [(2, 0)], [(0, 0), (0, 12), (16, 2)], length(dbody)), dbody)
    rmsg(idx) = (S.batch_msg(2, [(2, 0)], [(0, 0), (0, 2)], 8), S.pad8(S.bytesof(Int8, idx)))
    good = S.ipc_stream([(S.schema_msg(dfields), UInt8[]), dmsg, rmsg([0, 1])])
    @test collect(read_ipc(good).columns[1]) == ["a", "b"]                        # positive control
    @test bad(S.ipc_stream([(S.schema_msg(dfields), UInt8[]), dmsg, rmsg([0, 5])]), "out of range")
    @test bad(S.ipc_stream([(S.schema_msg(dfields), UInt8[]), dmsg, rmsg([0, -1])]), "out of range")
    @test bad(S.ipc_stream([(S.schema_msg(dfields), UInt8[]), rmsg([0, 1])]), "not sent before")
end

@testitem "ipc: bad magic, truncation, empty and wrong inputs" tags = [:unit, :ipc] setup = [IPCCorpus] begin
    using ChuiFrames: read_ipc, read_ipc_batches, read_ipc_schema
    isarg(f) = IPCCorpus.outcome(f) isa ArgumentError
    file = read(IPCCorpus.casepath("alltypes"))
    @test isarg(() -> read_ipc(UInt8[]))
    @test isarg(() -> read_ipc(joinpath(IPCCorpus.DIR, "no_such_file.arrow")))
    @test isarg(() -> read_ipc(42))
    @test isarg(() -> read_ipc(collect(codeunits("this is not an arrow file at all"))))
    @test isarg(() -> read_ipc(vcat(file[1:(end - 6)], collect(codeunits("ARROW2")))))   # trailing magic
    @test isarg(() -> read_ipc_schema(file[1:(end - 1)]))
    # every truncation of a file raises ArgumentError (the footer is gone or out of range)
    @test all(k -> isarg(() -> read_ipc(file[1:k])), 1:(length(file) - 1))
    # a truncated stream either reads the complete messages before the cut or raises
    stream = read(IPCCorpus.casepath("alltypes_stream"))
    outs = [IPCCorpus.outcome(() -> read_ipc_batches(stream[1:k])) for k in 1:(length(stream) - 1)]
    @test all(o -> o === :ok || o isa ArgumentError, outs)
    @test count(o -> o isa ArgumentError, outs) > length(outs) ÷ 2
end

@testitem "ipc: stream framing (legacy no-marker form, missing EOS)" tags = [:unit, :ipc] setup = [IPCCorpus] begin
    using ChuiFrames: read_ipc, frame_equal, _read_message
    bytes = read(IPCCorpus.casepath("dict_replacement_stream"))
    ref = read_ipc(bytes)
    # rewrite every message without its 0xFFFFFFFF continuation marker (pre-0.15 framing)
    legacy = let out = UInt8[], pos = 0
        while true
            msg, next = _read_message(bytes, pos)
            msg === nothing && break
            append!(out, bytes[(pos + 5):next])
            pos = next
        end
        append!(out, zeros(UInt8, 4))
    end
    @test frame_equal(read_ipc(legacy), ref)
    @test frame_equal(read_ipc(bytes[1:(end - 8)]), ref)          # no end-of-stream marker
end

@testitem "ipc: random byte corruption never escapes as a non-ArgumentError" tags = [:unit, :ipc] setup = [IPCCorpus] begin
    using ChuiFrames: read_ipc
    using Random: Xoshiro
    rng = Xoshiro(20261020)
    others = Any[]
    cases = ("alltypes", "alltypes_stream", "polars_file", "st03_two_views_stream", "dict_delta_stream", "pyarrow_zstd", "pyarrow_lz4_stream", "dict_dups_nullentry")
    nok = sum(cases) do case
        orig = read(IPCCorpus.casepath(case))
        k = 0
        for it in 1:200
            b = copy(orig)
            if isodd(it)     # byte flips
                for _ in 1:rand(rng, 1:3)
                    i = rand(rng, eachindex(b))
                    b[i] = rand(rng, (0x00, 0xff, 0x7f, 0x80, rand(rng, UInt8), b[i] ⊻ 0x01))
                end
            else             # an extreme Int32/Int64 over a length or offset (the overflow class)
                x = Int64(rand(rng, (typemax(Int64), typemin(Int64), 2^62, 2^61, -1, 2^40, typemax(Int32))))
                w = rand(rng, (4, 8))
                i = rand(rng, 1:(length(b) - w))
                b[i:(i + w - 1)] = w == 8 ? reinterpret(UInt8, [x]) : reinterpret(UInt8, [x % Int32])
            end
            o = IPCCorpus.outcome(() -> read_ipc(b))
            o === :ok && (k += 1)
            (o === :ok || o isa ArgumentError) || push!(others, (case, o))
        end
        k
    end
    isempty(others) || @info "non-ArgumentError outcomes" others[1:min(end, 5)]
    @test isempty(others)
    @test nok > 0          # some mutations hit data bytes only and still read
end
