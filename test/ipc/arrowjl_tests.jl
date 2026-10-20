# Cross-checks with Arrow.jl: its WRITER produces input for a property test, and its reader
# is compared only on cases where it is known to be correct (ADR-0001 rule 10: not on Polars
# files, ST-03, ST-04 or #610).

@testitem "ipc property: Arrow.jl-written tables read back equal (file and stream)" tags = [:property, :ipc] begin
    using ChuiFrames: read_ipc, read_ipc_batches, getcol, nrows, StrView
    using Arrow: Arrow
    using Tables: Tables
    using Supposition: Supposition, Data, @check, @composed

    ints = Data.Integers{Int64}() | Data.Just(missing)
    floats = Data.Floats{Float64}() | Data.Just(missing)                 # includes NaN, ±Inf, -0.0
    strs = Data.Text(Data.Characters(; valid = true); max_len = 40) | Data.Just(missing)   # > 12 bytes too
    row = @composed function arow(a = ints, b = floats, c = strs, d = Data.Integers{Int32}())
        return (a, b, c, d)
    end

    function roundtrips(rows, file::Bool, parts::Int)
        tbl = (
            a = Union{Missing, Int64}[r[1] for r in rows], b = Union{Missing, Float64}[r[2] for r in rows],
            c = Union{Missing, String}[r[3] for r in rows], d = Int32[r[4] for r in rows],
        )
        n = length(rows)
        io = IOBuffer()
        if parts > 1 && n >= parts
            cuts = round.(Int, range(0, n; length = parts + 1))
            chunks = [map(v -> v[(cuts[k] + 1):cuts[k + 1]], tbl) for k in 1:parts]
            Arrow.write(io, Tables.partitioner(chunks); file = file)
        else
            Arrow.write(io, tbl; file = file)
        end
        bytes = take!(io)
        t = read_ipc(bytes)
        sum(nrows, read_ipc_batches(bytes); init = 0) == n || return false
        eltype(getcol(t, :a)) === Union{Missing, Int64} || return false
        eltype(getcol(t, :c)) === Union{Missing, StrView} || return false
        eltype(getcol(t, :d)) === Int32 || return false
        return all(isequal(collect(getcol(t, k)), tbl[k]) for k in keys(tbl))
    end

    r = @check record = false db = false max_examples = 300 function arrowjl_roundtrip(
            rows = Data.Vectors(row; max_size = 40), file = Data.Booleans(), parts = Data.Integers(1, 3),
        )
        roundtrips(rows, file, parts)
    end
    @test Supposition.results(r).ispass      # @check inside @testset is not recorded on Julia 1.10
    # and a fixed example, so the property is not vacuous
    @test roundtrips([(1, NaN, "a string longer than twelve bytes", Int32(3)), (missing, -0.0, missing, Int32(-1))], true, 2)
end

@testitem "ipc cross-check: Arrow.jl's reader agrees where it is known correct" tags = [:unit, :ipc] setup = [IPCCorpus] begin
    using ChuiFrames: read_ipc, getcol
    using Arrow: Arrow
    using Tables: Tables
    # pyarrow-written compressed files, the all-types files and R's files (no views, no
    # sliced dictionary batch, no replacement dictionaries)
    for case in ("pyarrow_lz4", "pyarrow_zstd", "pyarrow_lz4_stream", "pyarrow_zstd_stream", "alltypes", "alltypes_stream", "r_feather", "r_stream")
        p = IPCCorpus.casepath(case)
        ours = read_ipc(p)
        theirs = Arrow.Table(p)
        @test Tables.columnnames(theirs) == Tables.columnnames(ours)
        for nm in Tables.columnnames(theirs)
            ok = IPCCorpus.same(getcol(ours, nm), Tables.getcolumn(theirs, nm))
            ok || @info "Arrow.jl disagrees" case nm
            @test ok
        end
    end
end
