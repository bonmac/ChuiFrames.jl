# Typed keys, `keyhash` and `KeyTable` (phase-4 spec §2.2, frozen API; ADR-0003 rule 8).

@testitem "typed keys: canonical values of one column" tags = [:unit] begin
    using ChuiFrames: typed_keys, keyhash
    nan2 = reinterpret(Float64, reinterpret(UInt64, NaN) | 0x01)   # a NaN with another payload
    col = [0.0, -0.0, NaN, -NaN, nan2, 1.5]
    k = typed_keys([col], 6)
    @test k isa Vector{Float64}
    @test all(!signbit, k[1:2])
    @test all(x -> reinterpret(UInt64, x) === reinterpret(UInt64, NaN), k[3:5])
    @test k[6] === 1.5
    @test keyhash(k[1]) == keyhash(k[2])
    @test keyhash(k[3]) == keyhash(k[4]) == keyhash(k[5])
    # keyhash canonicalises its argument too
    @test keyhash(-0.0) == keyhash(0.0)
    @test keyhash(nan2) == keyhash(NaN) == keyhash(-NaN32)

    # missing is its own key, the column's nullable element type is kept
    m = Union{Missing, Float64}[missing, -0.0, missing, 0.0]
    km = typed_keys([m], 4)
    @test km isa Vector{Union{Missing, Float64}}
    @test ismissing(km[1]) && ismissing(km[3])
    @test km[2] === 0.0 && km[4] === 0.0

    # a ChuiFrames column works the same (Float32 canonicalised in its own type)
    f32 = ChuiFrames.column(Float32[-0.0, NaN32])
    k32 = typed_keys([f32], 2)
    @test k32 isa Vector{Float32}
    @test k32[1] === 0.0f0 && isnan(k32[2])

    # NaN payloads in Float32 and Float16: one canonical NaN of the same type
    p32 = reinterpret(Float32, reinterpret(UInt32, NaN32) | 0x0001)
    p16 = reinterpret(Float16, reinterpret(UInt16, NaN16) | 0x0001)
    k32n = typed_keys([Float32[p32, -NaN32, NaN32]], 3)
    @test k32n isa Vector{Float32}
    @test all(x -> reinterpret(UInt32, x) === reinterpret(UInt32, NaN32), k32n)
    k16n = typed_keys([Float16[p16, -NaN16, NaN16, -0.0]], 4)
    @test k16n isa Vector{Float16}
    @test all(x -> reinterpret(UInt16, x) === reinterpret(UInt16, NaN16), k16n[1:3])
    @test k16n[4] === Float16(0.0)
    @test keyhash(p32) == keyhash(-NaN32) == keyhash(p16) == keyhash(-NaN16) == keyhash(NaN)
    # a Float32 DictColumn whose dictionary holds a payload NaN, NaN, -0 and 0: codes unified
    d32 = ChuiFrames.DictColumn(UInt8[1, 2, 3, 4], ChuiFrames.column(Float32[p32, NaN32, -0.0f0, 0.0f0]))
    kd = typed_keys([d32], 4)
    @test kd[1] == kd[2] && kd[3] == kd[4] && kd[1] != kd[3]
    kdv = typed_keys([d32], 4; codes = false)
    @test kdv isa Vector{Float32}
    @test reinterpret(UInt32, kdv[1]) === reinterpret(UInt32, NaN32) && kdv[3] === 0.0f0

    # strings and integers pass through
    @test typed_keys([["a", "b", "a"]], 3) == ["a", "b", "a"]
    @test typed_keys([[3, 1, 3]], 3) == [3, 1, 3]
    @test typed_keys([Missing[missing, missing]], 2) isa Vector{Missing}
end

@testitem "typed keys: abstract element types fall back to nothing" tags = [:unit] begin
    using ChuiFrames: typed_keys
    @test typed_keys([Any[1, "a"]], 2) === nothing
    @test typed_keys([Real[1, 2.0]], 2) === nothing
    @test typed_keys([[1, 2], Any[1, "a"]], 2) === nothing
    @test typed_keys([Union{Int, Float64}[1, 2.0]], 2) === nothing
    @test_throws DimensionMismatch typed_keys([[1, 2], [1]], 2)
    @test_throws DimensionMismatch typed_keys([[1, 2]], 3)
end

@testitem "typed keys: several columns give concrete tuples; zero columns one key" tags = [:unit] begin
    using ChuiFrames: typed_keys
    a = Union{Missing, Float64}[-0.0, 0.0, missing]
    b = ["x", "x", "y"]
    k = typed_keys([a, b], 3)
    @test k isa Vector{Tuple{Union{Missing, Float64}, String}}
    @test isequal(k, [(0.0, "x"), (0.0, "x"), (missing, "y")])
    @test !signbit(k[1][1])
    k0 = typed_keys(AbstractVector[], 4)
    @test k0 == fill((), 4)
    @test typed_keys([Float64[], String[]], 0) isa Vector{Tuple{Float64, String}}
end

@testitem "typed keys: DictColumn, codes = true and codes = false" tags = [:unit] begin
    using ChuiFrames: typed_keys, DictColumn, column
    # dictionary with ±0 entries and two NaN payloads: entries 1/2 and 3/4 are one key each
    nan2 = reinterpret(Float64, reinterpret(UInt64, NaN) | 0x01)
    dict = column([0.0, -0.0, NaN, nan2, 2.0])
    codes = UInt32[2, 1, 3, 4, 5, 0, 2]
    valid = BitVector([1, 1, 1, 1, 1, 0, 1])
    dc = DictColumn(codes, dict, valid)
    kc = typed_keys([dc], 7)
    @test kc isa Vector{UInt32}
    @test kc[1] == kc[2] == kc[7]          # -0.0 and 0.0 entries: one code
    @test kc[3] == kc[4]                   # NaN payloads: one code
    @test length(unique(kc)) == 4          # {±0, NaN, 2.0, missing}
    @test kc[6] == 0                       # missing is code 0
    @test all(!=(0), kc[[1:5; 7]])
    kv = typed_keys([dc], 7; codes = false)
    @test kv isa Vector{Union{Missing, Float64}}
    @test kv[1] === 0.0 && kv[2] === 0.0 && kv[7] === 0.0
    @test isnan(kv[3]) && reinterpret(UInt64, kv[4]) === reinterpret(UInt64, NaN)
    @test ismissing(kv[6]) && kv[5] === 2.0
    # no validity: non-nullable values
    dn = DictColumn(UInt8[1, 2, 1], column(["a", "b"]))
    @test typed_keys([dn], 3) == UInt32[1, 2, 1]
    @test typed_keys([dn], 3; codes = false) == ["a", "b", "a"]
    # the column's own element type (a StringColumn's is a StringView), hashing as String
    kvs = typed_keys([dn], 3; codes = false)
    @test eltype(kvs) == eltype(column(["a"])) && eltype(kvs) <: AbstractString
    @test ChuiFrames.keyhash(kvs[1]) == ChuiFrames.keyhash("a") == ChuiFrames.keyhash(SubString("ab", 1, 1))
    # inside a tuple key
    kt = typed_keys([dn, [1, 1, 2]], 3)
    @test kt == [(UInt32(1), 1), (UInt32(2), 1), (UInt32(1), 2)]
end

@testitem "KeyTable: dense first-seen ids, lookup, growth, keyvalues" tags = [:unit] begin
    using ChuiFrames: KeyTable, getorinsert!, lookup, keyvalues, keyhash
    t = KeyTable{Float64}(2)
    @test length(t) == 0
    @test lookup(t, 1.0, keyhash(1.0)) == 0
    @test getorinsert!(t, 3.0, keyhash(3.0)) == 1
    @test getorinsert!(t, 1.0, keyhash(1.0)) == 2
    @test getorinsert!(t, 3.0, keyhash(3.0)) == 1
    @test getorinsert!(t, -0.0, keyhash(-0.0)) == 3
    @test getorinsert!(t, 0.0, keyhash(0.0)) == 3       # ±0 is one key
    @test getorinsert!(t, -NaN, keyhash(-NaN)) == 4
    @test getorinsert!(t, NaN, keyhash(NaN)) == 4
    @test length(t) == 4
    @test lookup(t, 0.0, keyhash(0.0)) == 3
    @test lookup(t, 7.0, keyhash(7.0)) == 0
    # growth past many resizes keeps ids
    @test all(getorinsert!(t, Float64(i + 10), keyhash(Float64(i + 10))) == i + 4 for i in 1:10_000)
    @test length(t) == 10_004
    @test all(lookup(t, Float64(i + 10), keyhash(Float64(i + 10))) == i + 4 for i in 1:10_000)
    kv = keyvalues(t)
    @test kv isa Vector{Float64}
    @test kv[1:4] == [3.0, 1.0, 0.0, NaN] || isequal(kv[1:4], [3.0, 1.0, 0.0, NaN])
    @test length(kv) == 10_004
    # load factor <= 0.5 and power-of-two capacity
    cap = length(t.slots)
    @test ispow2(cap) && 2 * length(t) <= cap
    # missing is a key of its own
    tm = KeyTable{Union{Missing, Int}}(4)
    @test getorinsert!(tm, missing, keyhash(missing)) == 1
    @test getorinsert!(tm, 0, keyhash(0)) == 2
    @test lookup(tm, missing, keyhash(missing)) == 1
end

@testitem "KeyTable: home slot is the low bits of the hash" tags = [:unit] begin
    using ChuiFrames: KeyTable, getorinsert!, lookup
    t = KeyTable{Int}(4)
    cap = length(t.slots)
    h = UInt64(0xabcdef0000000005)
    id = getorinsert!(t, 42, h)
    @test t.slots[(h & (cap - 1)) + 1] == id
    # keys that share the low bits probe linearly; high bits do not matter for the slot
    h2 = h ⊻ (UInt64(1) << 63)
    id2 = getorinsert!(t, 43, h2)
    @test t.slots[((h2 + 1) & (cap - 1)) + 1] == id2
    @test lookup(t, 42, h) == id && lookup(t, 43, h2) == id2
end

@testitem "KeyTable: tuple keys and cross-type lookup" tags = [:unit] begin
    using ChuiFrames: KeyTable, getorinsert!, lookup, keyhash, typed_keys
    # Int32 x probing a Float64 y table (a join): isequal across types, keyhash agrees
    y = KeyTable{Float64}(8)
    for v in (1.0, 2.5, -0.0, NaN)
        getorinsert!(y, v, keyhash(v))
    end
    @test lookup(y, Int32(1), keyhash(Int32(1))) == 1
    @test lookup(y, Int32(2), keyhash(Int32(2))) == 0
    @test lookup(y, Int32(0), keyhash(Int32(0))) == 3     # 0 against the canonical 0.0
    @test lookup(y, NaN32, keyhash(NaN32)) == 4
    @test lookup(y, true, keyhash(true)) == 1
    s = KeyTable{String}(4)
    getorinsert!(s, "ab", keyhash("ab"))
    sub = SubString("xaby", 2, 3)
    @test lookup(s, sub, keyhash(sub)) == 1
    # tuple keys from typed_keys
    ks = typed_keys([Union{Missing, Float64}[-0.0, 0.0, missing], ["a", "a", "b"]], 3)
    T = KeyTable{eltype(ks)}(4)
    ids = [getorinsert!(T, k, keyhash(k)) for k in ks]
    @test ids == [1, 1, 2]
    @test lookup(T, (Int32(0), SubString("ab", 1, 1)), keyhash((Int32(0), SubString("ab", 1, 1)))) == 1
    @test lookup(T, (missing, "b"), keyhash((missing, "b"))) == 2
end

@testitem "raw first-seen keys: the caller's parallel vector" tags = [:unit] begin
    using ChuiFrames: KeyTable, typed_keys, keyhashes, keyids!
    col = [-0.0, 1.0, 0.0, 1.0, NaN, -0.0]
    keys = typed_keys([col], 6)
    t = KeyTable{eltype(keys)}(4)
    ids = zeros(Int, 6)
    firstrows = Int[]
    keyids!(ids, t, keys, keyhashes(keys), firstrows)
    @test ids == [1, 2, 1, 2, 3, 1]
    @test firstrows == [1, 2, 5]
    rawkeys = col[firstrows]            # rawkeys[id]: the uncanonicalised first-seen value
    @test signbit(rawkeys[1])           # the first ±0 in row order is -0.0 (rule 8)
    # the same pattern by hand: a new id is length(t) after the call
    t2 = KeyTable{Float64}(4)
    raw2 = Float64[]
    for (i, k) in enumerate(keys)
        id = ChuiFrames.getorinsert!(t2, k, ChuiFrames.keyhash(k))
        id > length(raw2) && push!(raw2, col[i])
    end
    @test isequal(raw2, rawkeys)
end

@testitem "keyhash agrees with isequal on allowed key pairs (critic N1)" tags = [:unit, :property] begin
    using ChuiFrames: keyhash, _lossless_key_promotion, _keypair_allowed, _canon
    using Dates
    using Supposition, Supposition.Data
    NUM = (
        Bool, Int8, Int16, Int32, Int64, Int128, UInt8, UInt16, UInt32, UInt64, UInt128,
        Float16, Float32, Float64,
    )
    # the lossless rule of spec §1.1
    @test _lossless_key_promotion(Int32, Float64)
    @test _lossless_key_promotion(Int32, Int64)
    @test _lossless_key_promotion(UInt32, Int64)
    @test _lossless_key_promotion(Bool, Int8)
    @test _lossless_key_promotion(Bool, Float16)
    @test _lossless_key_promotion(Float32, Float64)
    @test _lossless_key_promotion(Int8, Float16)
    @test _lossless_key_promotion(Int64, Int64)
    @test !_lossless_key_promotion(Int64, UInt64)
    @test !_lossless_key_promotion(Int8, UInt8)
    @test !_lossless_key_promotion(Int64, Float64)
    @test !_lossless_key_promotion(Int32, Float32)
    @test !_lossless_key_promotion(UInt16, Float16)
    @test !_lossless_key_promotion(Int128, Float64)
    # the pair rule: identical, both strings, or lossless numeric
    @test _keypair_allowed(String, SubString{String})
    @test _keypair_allowed(Date, Date)
    @test _keypair_allowed(Int32, Float64)
    @test !_keypair_allowed(Date, DateTime)
    @test !_keypair_allowed(Int64, UInt64)
    @test !_keypair_allowed(Int64, Float64)
    @test !_keypair_allowed(String, Int)
    @test !_keypair_allowed(Rational{Int}, Int)
    @test !_keypair_allowed(BigFloat, Float64)
    @test !_keypair_allowed(Float64, BigFloat)
    @test !_keypair_allowed(Char, String)
    # an all-missing side (nonmissing type Union{}) can only match missing: it pairs with anything
    @test _keypair_allowed(Union{}, Int64)
    @test _keypair_allowed(Int64, Union{})
    @test _keypair_allowed(Union{}, String)
    @test _keypair_allowed(Union{}, Union{})
    @test _lossless_key_promotion(Union{}, Int64) && _lossless_key_promotion(Float64, Union{})
    # symmetry
    for a in NUM, b in NUM
        @test _lossless_key_promotion(a, b) == _lossless_key_promotion(b, a)
    end
    pairs = [(a, b) for a in NUM for b in NUM if _keypair_allowed(a, b)]
    @test (Int32, Float64) in pairs && (Bool, Int64) in pairs && !((Int64, Float64) in pairs)
    # exact conversion or nothing
    bothnan(r, v) = r isa AbstractFloat && v isa AbstractFloat && isnan(r) && isnan(v)
    conv(::Type{T}, v) where {T} = try
        r = T(v)
        (r == v || bothnan(r, v)) ? r : nothing    # Float64(typemax(Int)) rounds: not exact
    catch err
        err isa InexactError || rethrow()
        nothing
    end
    agree(a, b) = !isequal(_canon(a), _canon(b)) || keyhash(a) == keyhash(b)
    function holds(v)
        for (A, B) in pairs
            a, b = conv(A, v), conv(B, v)
            (a === nothing || b === nothing) && continue
            agree(a, b) || return false
            isequal(_canon(a), _canon(b)) || (A === B) || return false   # exact conversions are equal
        end
        return true
    end
    # specials: ±0.0, NaN payloads, NaN32 vs NaN, true vs 1, extremes
    nan2 = reinterpret(Float64, reinterpret(UInt64, NaN) | 0x01)
    for v in (0, 1, -1, 0.0, -0.0, NaN, -NaN, nan2, Inf, -Inf, 0.5, 2.0^53, typemax(Int64), typemin(Int64), true)
        @test holds(v)
    end
    @test keyhash(NaN32) == keyhash(NaN) == keyhash(nan2)
    @test keyhash(true) == keyhash(1) == keyhash(1.0) == keyhash(Int32(1))
    @test keyhash(-0.0f0) == keyhash(0) == keyhash(false)
    @test keyhash(SubString("abc", 1, 2)) == keyhash("ab")
    # same-type pairs beyond numbers
    for (a, b) in ((Date(2020), Date(2020)), ("x", "x"), ((1, "a"), (1, "a")), (missing, missing))
        @test agree(a, b)
    end
    # generated values (Supposition)
    sr = @check record = false db = false max_examples = 200 holds(Data.Integers{Int64}())
    @test Supposition.results(sr).ispass
    sr = @check record = false db = false max_examples = 200 holds(Data.Integers(-300, 300))
    @test Supposition.results(sr).ispass
    sr = @check record = false db = false max_examples = 200 holds(Data.Floats{Float64}())
    @test Supposition.results(sr).ispass
    sr = @check record = false db = false max_examples = 200 holds(Data.Floats{Float32}())
    @test Supposition.results(sr).ispass
    # string pairs: String, SubString and a StringColumn's StringView element
    strs = Data.Text(Data.Characters(); max_len = 6)
    function shash(s)
        sub = SubString(s * "z", 1, lastindex(s))
        sv = ChuiFrames.column([s])[1]
        _keypair_allowed(typeof(sub), typeof(sv)) || return false
        return isequal(sub, s) && isequal(sv, s) && keyhash(sub) == keyhash(s) == keyhash(sv)
    end
    sr = @check record = false db = false max_examples = 200 shash(strs)
    @test Supposition.results(sr).ispass
end
