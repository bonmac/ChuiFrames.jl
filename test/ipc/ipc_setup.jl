# Shared helpers for the Arrow IPC reader tests (ADR-0001 rule 10).
#
# Expected values come from the pyarrow dumps in test/data/ipc/<case>.json (written by
# make_corpus.py). JSON is not a test dependency, so a minimal reader lives here: the dumps
# are produced by Python's `json.dump` (objects, arrays, strings, numbers, true/false/null),
# and reading them directly keeps the pyarrow output as the single source of truth, with
# no generated intermediate file to drift from it.

@testmodule IPCCorpus begin
    using ChuiFrames: ChuiFrames
    using Dates: Dates, Date, DateTime
    using Test: @test

    const DIR = joinpath(pkgdir(ChuiFrames), "test", "data", "ipc")

    "A JSON object with its keys in file order."
    struct JObj
        pairs::Vector{Pair{String, Any}}
    end
    Base.getindex(o::JObj, k::String) = (i = findfirst(p -> p.first == k, o.pairs); i === nothing ? throw(KeyError(k)) : o.pairs[i].second)
    Base.keys(o::JObj) = first.(o.pairs)

    mutable struct P
        s::Vector{UInt8}
        i::Int
    end
    function skipws(p::P)
        while p.i <= length(p.s) && p.s[p.i] in (0x20, 0x0a, 0x0d, 0x09)
            p.i += 1
        end
        return
    end
    peekc(p::P) = (skipws(p); p.i <= length(p.s) ? Char(p.s[p.i]) : error("unexpected end of JSON"))
    function expect(p::P, c::Char)
        peekc(p) == c || error("expected '$c' at byte $(p.i)")
        p.i += 1
        return
    end

    function value(p::P)
        c = peekc(p)
        if c == '{'
            p.i += 1
            pairs = Pair{String, Any}[]
            peekc(p) == '}' && (p.i += 1; return JObj(pairs))
            while true
                k = jstring(p)
                expect(p, ':')
                push!(pairs, k => value(p))
                peekc(p) == ',' ? (p.i += 1) : (expect(p, '}'); return JObj(pairs))
            end
        elseif c == '['
            p.i += 1
            arr = Any[]
            peekc(p) == ']' && (p.i += 1; return arr)
            while true
                push!(arr, value(p))
                peekc(p) == ',' ? (p.i += 1) : (expect(p, ']'); return arr)
            end
        elseif c == '"'
            return jstring(p)
        elseif startswith(String(p.s[p.i:min(end, p.i + 4)]), "true")
            p.i += 4
            return true
        elseif startswith(String(p.s[p.i:min(end, p.i + 4)]), "false")
            p.i += 5
            return false
        elseif startswith(String(p.s[p.i:min(end, p.i + 4)]), "null")
            p.i += 4
            return nothing
        else
            j = p.i
            while p.i <= length(p.s) && Char(p.s[p.i]) in "+-0123456789.eE"
                p.i += 1
            end
            t = String(p.s[j:(p.i - 1)])
            any(in(t), ".eE") && return parse(Float64, t)
            x = tryparse(Int64, t)
            return x === nothing ? parse(Int128, t) : x
        end
    end

    function jstring(p::P)
        expect(p, '"')
        io = IOBuffer()
        while true
            b = p.s[p.i]
            p.i += 1
            if b == UInt8('"')
                return String(take!(io))
            elseif b == UInt8('\\')
                e = Char(p.s[p.i])
                p.i += 1
                if e == 'u'
                    u = parse(UInt32, String(p.s[p.i:(p.i + 3)]); base = 16)
                    p.i += 4
                    if 0xd800 <= u <= 0xdbff   # surrogate pair
                        p.s[p.i] == UInt8('\\') && p.s[p.i + 1] == UInt8('u') || error("bad surrogate")
                        lo = parse(UInt32, String(p.s[(p.i + 2):(p.i + 5)]); base = 16)
                        p.i += 6
                        u = 0x00010000 + ((u - 0xd800) << 10) + (lo - 0xdc00)
                    end
                    print(io, Char(u))
                else
                    print(io, Dict('"' => '"', '\\' => '\\', '/' => '/', 'b' => '\b', 'f' => '\f', 'n' => '\n', 'r' => '\r', 't' => '\t')[e])
                end
            else
                write(io, b)
            end
        end
    end

    parsejson(s::AbstractString) = value(P(Vector{UInt8}(s), 1))
    loaddump(case::AbstractString) = parsejson(read(joinpath(DIR, case * ".json"), String))

    "Decode one value of a pyarrow dump (see `enc` in make_corpus.py) to the expected Julia value."
    function expected(v)
        v === nothing && return missing
        v isa JObj || return v
        k, x = only(v.pairs)
        k == "float" && return parse(Float64, x)        # "NaN", "Inf", "-Inf"
        k == "bytes" && return hex2bytes(x)
        k == "date" && return Date(x)
        if k == "datetime"                              # isoformat: microseconds; ms is enough here
            base, frac = occursin('.', x) ? split(x, '.') : (x, "0")
            return DateTime(base) + Dates.Millisecond(parse(Int, rpad(frac, 3, '0')[1:3]))
        end
        k == "struct" && return NamedTuple{Tuple(Symbol.(keys(x)))}(Tuple(expected(p.second) for p in x.pairs))
        k == "list" && return Any[expected(y) for y in x]
        error("unknown encoded value $k")
    end

    "The path of a corpus case (`.arrow` for the file format, `.arrows` for the stream format)."
    function casepath(case::AbstractString)
        p = joinpath(DIR, case * ".arrow")
        return isfile(p) ? p : joinpath(DIR, case * ".arrows")
    end

    "Element-wise `isequal` with matching lengths (a `StrView` equals its `String`)."
    same(a, b) = length(a) == length(b) && all(isequal(x, y) for (x, y) in zip(a, b))

    "Expected non-missing element type for a pyarrow type string, or a predicate for nested types."
    function expected_valuetype(t::AbstractString)
        S = Dict(
            "int8" => Int8, "int16" => Int16, "int32" => Int32, "int64" => Int64,
            "uint8" => UInt8, "uint16" => UInt16, "uint32" => UInt32, "uint64" => UInt64,
            "float" => Float32, "double" => Float64, "bool" => Bool,
            "string" => ChuiFrames.StrView, "large_string" => ChuiFrames.StrView, "string_view" => ChuiFrames.StrView,
            "binary" => ChuiFrames.ByteView, "large_binary" => ChuiFrames.ByteView, "binary_view" => ChuiFrames.ByteView,
            "date32[day]" => Date, "timestamp[ms]" => DateTime,
        )
        haskey(S, t) && return S[t]
        startswith(t, "dictionary<values=string") && return ChuiFrames.StrView
        (startswith(t, "list<") || startswith(t, "large_list<")) && return SubArray
        startswith(t, "struct<") && return NamedTuple
        error("no expected type for $t")
    end

    "The zero-null-slot invariant (ADR-0001 rule 2) and dictionary rules (rule 5), recursively."
    invariant_ok(c) = true
    function invariant_ok(c::ChuiFrames.PrimitiveColumn{E, T}) where {E, T}
        v = c.validity
        return v === nothing || all(v[i] || isequal(c.values[i], ChuiFrames.nullvalue(T)) for i in eachindex(v))
    end
    invariant_ok(c::ChuiFrames.BoolColumn) = c.validity === nothing || !any(c.values .& .!c.validity)
    function invariant_ok(c::ChuiFrames.VarColumn)   # the constructor checks it; re-check here
        v = c.validity
        return v === nothing || all(v[i] || c.offsets[i] == c.offsets[i + 1] for i in eachindex(v))
    end
    function invariant_ok(c::ChuiFrames.DictColumn)
        v = c.validity
        nullsok = v === nothing || all(v[i] || c.codes[i] == 0 for i in eachindex(v))
        return nullsok && !ChuiFrames.isnullable(c.dict) && allunique(collect(c.dict)) && invariant_ok(c.dict)
    end
    function invariant_ok(c::ChuiFrames.ListColumn)
        v = c.validity
        nullsok = v === nothing || all(v[i] || c.offsets[i] == c.offsets[i + 1] for i in eachindex(v))
        return nullsok && c.offsets[1] == 0 && invariant_ok(c.child)
    end
    invariant_ok(c::ChuiFrames.StructColumn) = all(invariant_ok, values(c.children))

    # -----------------------------------------------------------------------------------------
    # A tiny FlatBuffers writer, to hand-build IPC streams that no producer writes (a
    # big-endian schema, corrupt offsets). A table is a vector of `(field id, kind, value)`:
    # kinds :u8 :bool :i16 :i32 :i64 (scalars), :table (a sub-table), :tables (a vector of
    # tables), :string, :structs (`(count, raw element bytes)`). Layout is forward: each vtable
    # sits just before its table, children after their parent (all uoffsets point forward).

    const FBSIZES = Dict(:u8 => UInt8, :bool => Bool, :i16 => Int16, :i32 => Int32, :i64 => Int64)
    putle!(buf, x) = append!(buf, reinterpret(UInt8, [htol(x)]))
    patch32!(buf, p, x) = (buf[(p + 1):(p + 4)] = reinterpret(UInt8, [htol(UInt32(x))]); buf)

    function fb_emit!(buf::Vector{UInt8}, fields)
        maxid = maximum(f -> f[1], fields; init = -1)
        inl(k) = haskey(FBSIZES, k) ? sizeof(FBSIZES[k]) : 4
        vt = length(buf)
        putle!(buf, UInt16(4 + 2(maxid + 1)))
        putle!(buf, UInt16(4 + sum(f -> inl(f[2]), fields; init = 0)))
        slots = zeros(UInt16, maxid + 1)
        off = 4
        for (id, k, _) in fields
            slots[id + 1] = off
            off += inl(k)
        end
        foreach(s -> putle!(buf, s), slots)
        tpos = length(buf)
        putle!(buf, Int32(tpos - vt))
        pending = Tuple{Int, Symbol, Any}[]
        for (id, k, v) in fields
            if haskey(FBSIZES, k)
                putle!(buf, FBSIZES[k](v))
            else
                push!(pending, (length(buf), k, v))
                putle!(buf, UInt32(0))
            end
        end
        for (p, k, v) in pending
            if k === :table
                patch32!(buf, p, fb_emit!(buf, v) - p)
            elseif k === :string
                patch32!(buf, p, length(buf) - p)
                putle!(buf, UInt32(sizeof(v)))
                append!(buf, codeunits(v))
                push!(buf, 0x00)
            elseif k === :structs
                patch32!(buf, p, length(buf) - p)
                putle!(buf, UInt32(v[1]))
                append!(buf, v[2])
            else # :tables
                patch32!(buf, p, length(buf) - p)
                putle!(buf, UInt32(length(v)))
                slotpos = [length(buf) + 4(j - 1) for j in eachindex(v)]
                foreach(_ -> putle!(buf, UInt32(0)), v)
                for (j, t) in enumerate(v)
                    patch32!(buf, slotpos[j], fb_emit!(buf, t) - slotpos[j])
                end
            end
        end
        return tpos
    end
    function fb_buffer(fields)
        buf = zeros(UInt8, 4)
        patch32!(buf, 0, fb_emit!(buf, fields))
        return buf
    end

    "A schema field spec. `type` is `(type id, type-table fields)`; `dict` is `(id, index bits)`."
    function fb_field(name, type; nullable = true, children = [], dict = nothing)
        f = Any[(0, :string, name), (1, :bool, nullable), (2, :u8, type[1]), (3, :table, type[2])]
        dict === nothing || push!(f, (4, :table, Any[(0, :i64, dict[1]), (1, :table, Any[(0, :i32, dict[2]), (1, :bool, true)])]))
        isempty(children) || push!(f, (5, :tables, children))
        return f
    end
    const T_INT64 = (2, Any[(0, :i32, 64), (1, :bool, true)])
    const T_UTF8 = (5, Any[])

    schema_msg(fields; endianness = 0, version = 4) =
        fb_buffer(Any[(0, :i16, version), (1, :u8, 1), (2, :table, Any[(0, :i16, endianness), (1, :tables, fields)]), (3, :i64, 0)])
    structs(pairs) = (length(pairs), reduce(vcat, [vcat(reinterpret(UInt8, [htol(Int64(a))]), reinterpret(UInt8, [htol(Int64(b))])) for (a, b) in pairs]; init = UInt8[]))
    rb_table(len, nodes, bufs) = Any[(0, :i64, len), (1, :structs, structs(nodes)), (2, :structs, structs(bufs))]
    batch_msg(len, nodes, bufs, bodylen) =
        fb_buffer(Any[(0, :i16, 4), (1, :u8, 3), (2, :table, rb_table(len, nodes, bufs)), (3, :i64, bodylen)])
    dict_msg(id, len, nodes, bufs, bodylen; isdelta = false) =
        fb_buffer(Any[(0, :i16, 4), (1, :u8, 2), (2, :table, Any[(0, :i64, id), (1, :table, rb_table(len, nodes, bufs)), (2, :bool, isdelta)]), (3, :i64, bodylen)])

    pad8(v) = vcat(v, zeros(UInt8, (8 - length(v) % 8) % 8))
    "Encapsulate `(metadata, body)` messages as an IPC stream with continuation markers and EOS."
    function ipc_stream(msgs)
        out = UInt8[]
        for (meta, body) in msgs
            m = pad8(meta)
            putle!(out, 0xffffffff)
            putle!(out, Int32(length(m)))
            append!(out, m)
            append!(out, pad8(body))
        end
        putle!(out, 0xffffffff)
        putle!(out, Int32(0))
        return out
    end
    bytesof(T, xs) = collect(reinterpret(UInt8, T[htol(T(x)) for x in xs]))

    """
    A valid hand-built stream: `x::Int64` (2 rows, row 2 null) and `s::Utf8` (`"ab"`, `"cde"`).
    `offsets` replaces the string offsets (to corrupt them).
    """
    function handmade_stream(; offsets = [0, 2, 5], endianness = 0, s_nullable = true, xnulls = 1)
        fields = [fb_field("x", T_INT64), fb_field("s", T_UTF8; nullable = s_nullable)]
        validity = pad8(UInt8[0x01])                         # row 1 valid, row 2 null
        xs = bytesof(Int64, [7, 0])
        offs = pad8(bytesof(Int32, offsets))
        data = pad8(collect(codeunits("abcde")))
        body = vcat(validity, xs, offs, data)
        p1 = length(validity); p2 = p1 + length(xs); p3 = p2 + length(offs)
        bufs = [(0, xnulls == 0 ? 0 : 1), (p1, 16), (0, 0), (p2, 4 * length(offsets)), (p3, 5)]
        nodes = [(2, xnulls), (2, 0)]
        return ipc_stream([(schema_msg(fields; endianness), UInt8[]), (batch_msg(2, nodes, bufs, length(body)), body)])
    end

    "Run `f()`; return `:ok`, or the exception (for 'never anything but ArgumentError' checks)."
    outcome(f) = try
        f()
        :ok
    catch e
        e
    end

    "Check one corpus case against its pyarrow dump: per batch, concatenated, schema, element types."
    function checkcase(case::AbstractString)
        doc = loaddump(case)
        path = casepath(case)
        batches = ChuiFrames.read_ipc_batches(path)
        @test [ChuiFrames.nrows(b) for b in batches] == doc["batch_lengths"]
        t = ChuiFrames.read_ipc(path)
        names = Symbol[Symbol(f["name"]) for f in doc["schema"]]
        @test ChuiFrames.columnnames(t) == names
        @test ChuiFrames.nrows(t) == doc["num_rows"]
        sch = ChuiFrames.read_ipc_schema(path)
        @test collect(sch.names) == names
        for (j, f) in enumerate(doc["schema"])
            nm = names[j]
            col = ChuiFrames.getcol(t, nm)
            E = eltype(col)
            @test sch.types[j] === E
            @test (Missing <: E) == f["nullable"]
            @test nonmissingtype(E) <: expected_valuetype(f["type"])
            exp = Any[expected(x) for x in doc["columns"][f["name"]]]
            ok = same(col, exp)
            ok || @info "concatenated mismatch" case nm collect(col) exp
            @test ok
            perbatch = Any[x for b in batches for x in ChuiFrames.getcol(b, nm)]
            ok = same(perbatch, exp)
            ok || @info "per-batch mismatch" case nm perbatch exp
            @test ok
            @test all(eltype(ChuiFrames.getcol(b, nm)) === E for b in batches)
            @test invariant_ok(col)
            @test all(invariant_ok(ChuiFrames.getcol(b, nm)) for b in batches)
        end
        @test ChuiFrames.frame_equal(ChuiFrames.read_ipc(read(path)), t)   # bytes in, same frame out
        return t, batches
    end
end
