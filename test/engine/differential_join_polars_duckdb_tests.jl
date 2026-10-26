# Differential tests of the join verbs against Polars and DuckDB (tag :differential, plus
# :polars_duckdb). Phase-4 spec docs/superpowers/specs/2026-10-26-phase4-joins-groupby-codegen-design.md
# §4. Python runs only through `uv`, pinned as in test/engine/differential_polars_duckdb_tests.jl,
# in a `mktempdir()`; the tables go over as Arrow IPC written by ChuiFrames.
#
# What is compared: the matched pairs (x row id, y row id; `missing` for the side a row lacks),
# as sorted multisets. Row order is checked against dplyr (differential_join_dplyr_tests.jl),
# whose order ChuiFrames follows; Polars and DuckDB do not promise one.
#
# Key semantics differ for nulls and NaN (the `na_matches` equivalent). Each case pairs
# `na_matches = :na` with Polars `nulls_equal=True` and DuckDB `IS NOT DISTINCT FROM`, and
# `:never` with `nulls_equal=False` and `=`. A case kind is :exact or `(:nan_rows,)`: the pairs
# that involve a NaN key differ, the rest match exactly. An encoded divergence that stops
# occurring fails the test. Every divergence is documented in docs/research/differentials-joins.md.

@testitem "differential: joins against Polars and DuckDB" tags = [:differential, :polars_duckdb] begin
    using Tables

    const POLARS = "2.0.0"
    const DUCKDB = "1.5.6"
    const PYARROW = "26.0.0"

    function run_differential()
        uv = Sys.which("uv")
        if uv === nothing
            @info "differential: uv not found on PATH; skipping the Polars and DuckDB join comparison"
            @test_skip false
            return
        end
        F = Union{Missing, Float64}
        x = Frame(
            xid = collect(1:9), k = F[2.0, 1.0, NaN, missing, -0.0, 2.0, 7.0, 0.0, NaN],
            i = [1, 2, 1, 3, 2, 1, 1, 4, 2], s = Union{Missing, String}["a", "b", missing, "a", "c", "b", "a", missing, "d"],
        )
        y = Frame(
            yid = collect(1:8), k = F[2.0, 0.0, NaN, 2.0, 5.0, missing, -0.0, missing],
            i = [1, 1, 2, 3, 1, 1, 5, 2], s = Union{Missing, String}["b", "a", "a", missing, "z", "c", missing, "a"],
        )
        nanx = Set(i for i in 1:9 if isequal(x.columns[2][i], NaN))
        nany = Set(i for i in 1:8 if isequal(y.columns[2][i], NaN))

        jfun(kind) = kind === :inner ? inner_join : kind === :left ? left_join : kind === :right ? right_join :
            kind === :full ? full_join : kind === :semi ? semi_join : anti_join
        sqlj(kind) = Dict(:inner => "INNER JOIN", :left => "LEFT JOIN", :right => "RIGHT JOIN", :full => "FULL OUTER JOIN", :semi => "SEMI JOIN", :anti => "ANTI JOIN")[kind]
        # (name, Julia thunk -> frame of xid[, yid], Polars expression, DuckDB SQL, Polars kind, DuckDB kind)
        cases = Any[]
        for (by, keys) in ((:k, ["k"]), (:i, ["i"]), (:s, ["s"]), ([:k, :i], ["k", "i"])), na in (:na, :never), kind in (:inner, :left, :right, :full, :semi, :anti)
            nm = "$(kind)_$(join(keys, "_"))_$(na)"
            sel = kind in (:semi, :anti) ? [:xid] : [:xid, :yid]
            jl = () -> select(sel...)(jfun(kind)(y; by, na_matches = na)(x))
            pkeys = "[" * join(repr.(keys), ", ") * "]"
            pcols = kind in (:semi, :anti) ? "'xid'" : "'xid', 'yid'"
            px = "x.join(y, on=$pkeys, how='$(kind)', nulls_equal=$(na === :na ? "True" : "False")).select($pcols)"
            op = na === :na ? "IS NOT DISTINCT FROM" : "="
            cond = join(["x.$k $op y.$k" for k in keys], " AND ")
            scols = kind in (:semi, :anti) ? "x.xid" : "x.xid, y.yid"
            sx = "SELECT $scols FROM x $(sqlj(kind)) y ON $cond"
            haskf = :k in (by isa Vector ? by : [by])
            # under :never ChuiFrames' NaN key matches nothing; Polars' and DuckDB's NaN equals NaN
            pk = (haskf && na === :never) ? (:nan_rows,) : :exact
            push!(cases, (nm, jl, px, sx, pk, pk))
        end

        dir = mktempdir()
        write_arrow(x, joinpath(dir, "x.arrow"))
        write_arrow(y, joinpath(dir, "y.arrow"))
        pystr(s) = "r'''" * s * "'''"
        pycases = join(["    ($(pystr(nm)), $(pystr(px)), $(pystr(sx)))," for (nm, _, px, sx, _, _) in cases], "\n")
        py = """
        import sys
        import pyarrow.ipc as ipc
        import polars as pl
        import duckdb
        assert pl.__version__ == "$POLARS", pl.__version__
        assert duckdb.__version__ == "$DUCKDB", duckdb.__version__
        dirp = sys.argv[1]
        xt = ipc.open_file(f"{dirp}/x.arrow").read_all()
        yt = ipc.open_file(f"{dirp}/y.arrow").read_all()
        con = duckdb.connect()
        con.register("x_arrow", xt); con.sql("CREATE TABLE x AS SELECT * FROM x_arrow")
        con.register("y_arrow", yt); con.sql("CREATE TABLE y AS SELECT * FROM y_arrow")
        x = pl.from_arrow(xt); y = pl.from_arrow(yt)
        CASES = [
        $pycases
        ]
        enc = lambda v: "N" if v is None else str(v)
        hx = lambda s: str(s).encode().hex()
        with open(f"{dirp}/out.txt", "w") as out:
            out.write(f"VERSIONS\\t{pl.__version__}\\t{duckdb.__version__}\\n")
            for name, pexpr, sql in CASES:
                for eng in ("polars", "duckdb"):
                    try:
                        if eng == "polars":
                            r = eval(pexpr, {"pl": pl, "x": x, "y": y})
                            cols = [r[c].to_list() for c in r.columns]
                        else:
                            t = con.sql(sql).fetch_arrow_table()
                            cols = [col.to_pylist() for col in t.columns]
                    except Exception as e:
                        out.write(f"ERR\\t{eng}\\t{name}\\t{hx(type(e).__name__ + ': ' + str(e).splitlines()[0][:300])}\\n")
                        continue
                    rows = list(zip(*cols)) if cols else []
                    out.write(f"CASE\\t{eng}\\t{name}\\t" + ";".join(",".join(enc(v) for v in r) for r in rows) + "\\n")
        """
        pyfile = joinpath(dir, "cases.py")
        write(pyfile, py)
        cmd = `$uv run --no-project --python 3.13 --with polars==$POLARS --with duckdb==$DUCKDB --with pyarrow==$PYARROW python -I $pyfile $dir`
        run(pipeline(cmd; stderr = devnull))
        out = read(joinpath(dir, "out.txt"), String)

        res = Dict{Tuple{String, String}, Any}()
        versions = String[]
        for line in split(out, '\n'; keepempty = false)
            f = split(line, '\t'; keepempty = true)
            if f[1] == "VERSIONS"
                versions = String.(f[2:end])
            elseif f[1] == "CASE"
                rows = isempty(f[4]) ? Vector{Any}[] : [Any[v == "N" ? missing : parse(Int, v) for v in split(r, ',')] for r in split(f[4], ';')]
                res[(String(f[2]), String(f[3]))] = rows
            elseif f[1] == "ERR"
                res[(String(f[2]), String(f[3]))] = String(hex2bytes(f[4]))
            end
        end
        @test versions == [POLARS, DUCKDB]

        key(r) = Tuple(ismissing(v) ? typemax(Int) : v for v in r)
        canon(rows) = sort(rows; by = key)
        jlrows(f) = Vector{Any}[Any[c[i] for c in f.columns] for i in 1:f.nrow]
        nanrow(r) = (r[1] !== missing && r[1] in nanx) || (length(r) > 1 && r[2] !== missing && r[2] in nany)
        passed = Dict("polars" => 0, "duckdb" => 0)
        exact = Dict("polars" => 0, "duckdb" => 0)
        divergent = Dict("polars" => String[], "duckdb" => String[])
        for (nm, jl, _, _, kpl, kdb) in cases
            j = canon(jlrows(jl()))
            for (eng, kind) in (("polars", kpl), ("duckdb", kdb))
                r = get(res, (eng, nm), nothing)
                if !(r isa Vector)
                    @info "differential: engine error" case = nm engine = eng error = r
                    @test r isa Vector
                    continue
                end
                f = canon(r)
                if j == f
                    passed[eng] += 1
                    exact[eng] += 1
                    continue
                end
                # (:nan_rows,): only pairs involving a NaN key may differ
                if kind isa Tuple && kind[1] === :nan_rows
                    restok = filter(!nanrow, j) == filter(!nanrow, f)
                    restok || @info "differential mismatch (outside NaN-key pairs)" case = nm engine = eng julia = j foreign = f
                    @test restok
                    restok && (passed[eng] += 1; push!(divergent[eng], nm))
                    continue
                else
                    @info "differential mismatch" case = nm engine = eng julia = j foreign = f
                    @test j == f
                end
            end
        end
        # every encoded NaN divergence must still occur somewhere (else the document is stale)
        for eng in ("polars", "duckdb")
            nanc = count(c -> (eng == "polars" ? c[5] : c[6]) isa Tuple, cases)
            @test length(divergent[eng]) == nanc      # an encoded divergence that stops occurring fails
            @info "differential: $(passed[eng])/$(length(cases)) join cases agree with $eng ($(exact[eng]) exactly; NaN-key pairs differ in $(length(divergent[eng])) of the $nanc cases that allow it)" divergent = divergent[eng]
        end
        return nothing
    end
    run_differential()
end
