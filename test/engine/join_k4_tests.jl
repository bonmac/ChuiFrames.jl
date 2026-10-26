# Integer/float and other cross-type key pairs (phase-4 spec docs/superpowers/specs/2026-10-26-phase4-joins-groupby-codegen-design.md
# §1.1 N1 and the user's ★ K4): the compare type, the conversion before hashing, output key
# types, the 2^53 boundary in both orientations, and semi/anti returning x unconverted. Every
# case runs under each `_FORCE_JOIN` value.

@testitem "join K4: compare types and output key types" tags = [:unit] setup = [Force, JoinHelpers] begin
    CF = ChuiFrames
    # lossless pairs compare as promote_type; integer/float pairs not lossless as Float64
    x32 = Frame(k = Int32[1, 2, 3], a = [1, 2, 3])
    yf = Frame(k = [2.0, 3.0, 3.5], b = [20, 30, 35])
    for r in forall(() -> inner_join(yf; by = :k)(x32))
        @test eltype(CF.getcol(r, :k)) == Float64 && isequal(colvec(r, :k), [2.0, 3.0])
    end
    x64 = Frame(k = [1, 2, 3], a = [1, 2, 3])
    for r in forall(() -> full_join(yf; by = :k)(x64))
        @test eltype(CF.getcol(r, :k)) == Float64
        @test isequal(colvec(r, :k), [1.0, 2.0, 3.0, 3.5])
    end
    # keep = true: each key keeps its own type, unconverted (dplyr: k.x integer, k.y numeric)
    for r in forall(() -> left_join(yf; by = :k, keep = true)(x64))
        @test eltype(CF.getcol(r, :k_x)) == Int
        @test eltype(CF.getcol(r, :k_y)) == Union{Missing, Float64}
    end
    # Int32 vs Int64 (lossless) and Bool vs Int
    for r in forall(() -> inner_join(Frame(k = [2, 3], b = [1, 2]); by = :k)(x32))
        @test eltype(CF.getcol(r, :k)) == Int64
    end
    for r in forall(() -> inner_join(Frame(k = [1, 0], b = [1, 2]); by = :k)(Frame(k = [true, false, true])))
        @test eltype(CF.getcol(r, :k)) == Int && isequal(colvec(r, :b), [1, 2, 1])
    end
    # NaN32 matches NaN, Float32 vs Float64
    for r in forall(() -> inner_join(Frame(k = [NaN, 1.0], b = [1, 2]); by = :k)(Frame(k = Float32[NaN32, 1.0f0])))
        @test eltype(CF.getcol(r, :k)) == Float64 && isequal(colvec(r, :b), [1, 2])
    end
    # a nullable side adds Missing to the output key
    for r in forall(() -> inner_join(Frame(k = Union{Missing, Float64}[1.0, missing], b = [1, 2]); by = :k)(x64))
        @test eltype(CF.getcol(r, :k)) == Union{Missing, Float64}
    end
    # an all-missing key column pairs with any type and matches only missing
    for r in forall(() -> left_join(Frame(k = Union{Missing, Int}[missing, 1], b = [7, 8]); by = :k)(Frame(k = [missing, missing])))
        @test isequal(colvec(r, :b), [7, 7])
        @test eltype(CF.getcol(r, :k)) == Union{Missing, Int}
    end
    # semi/anti return x's columns unconverted, keys included
    for r in forall(() -> semi_join(yf; by = :k)(x64))
        @test eltype(CF.getcol(r, :k)) == Int && isequal(colvec(r, :k), [2, 3])
    end
    for r in forall(() -> anti_join(yf; by = :k)(x64))
        @test eltype(CF.getcol(r, :k)) == Int && isequal(colvec(r, :k), [1])
    end
    # nest_join: the key under keep = false has the compare type
    for r in forall(() -> nest_join(yf; by = :k)(x64))
        @test eltype(CF.getcol(r, :k)) == Float64
    end
end

@testitem "join K4: the 2^53 boundary, both orientations (documented precision loss)" tags = [:unit] setup = [Force, JoinHelpers] begin
    CF = ChuiFrames
    big = [2^53, 2^53 + 1, 2^53 - 1, -(2^53 + 1), typemax(Int64)]
    x = Frame(k = big, a = 1:5)
    y = Frame(k = [2.0^53, Float64(typemax(Int64)), -(2.0^53)], b = [1, 2, 3])
    for r in forall(() -> inner_join(y; by = :k)(x))
        # 2^53 and 2^53 + 1 both round to 2.0^53; -(2^53 + 1) to -(2.0^53); typemax to 2.0^63
        @test isequal(colvec(r, :a), [1, 2, 4, 5])
        @test isequal(colvec(r, :b), [1, 1, 3, 2])
        @test isequal(colvec(r, :k), [2.0^53, 2.0^53, -(2.0^53), 2.0^63])
        @test eltype(CF.getcol(r, :k)) == Float64
    end
    # y Int64 against x Float64: the same matches, seen from the other side
    for r in forall(() -> inner_join(x; by = :k)(y))
        @test isequal(colvec(r, :b), [1, 1, 2, 3])
        @test isequal(colvec(r, :a), [1, 2, 5, 4])
    end
    # the pair rule: isequal after conversion implies equal keyhash
    for (a, b) in ((2^53, 2.0^53), (2^53 + 1, 2.0^53), (true, 1.0), (Int32(7), 7.0), (NaN32, NaN), (-0.0f0, 0.0))
        T = CF._join_compare_types(
            CF._resolve_names(inner_join(Frame(k = [b]); by = :k), [:k], [:k]), Type[typeof(a)], Type[typeof(b)]
        )[1]
        ca, cb = convert(T, a), convert(T, b)
        isequal(CF._canon(ca), CF._canon(cb)) && @test CF.keyhash(ca) == CF.keyhash(cb)
    end
end

@testitem "join K4: the oracle agrees at the 2^53 boundary" tags = [:unit] setup = [Force, JoinHelpers, Oracle] begin
    x = (k = [2^53, 2^53 + 1, 7], a = [1, 2, 3])
    y = (k = [2.0^53, 7.0], b = [10, 20])
    o = Oracle.ojoin(:left, Oracle.OTable(x), Oracle.OTable(y); by = [:k => :k], T = Any[Float64])
    for r in forall(() -> left_join(Frame(y); by = :k)(Frame(x)))
        @test Oracle.agree(r, o)
    end
end
