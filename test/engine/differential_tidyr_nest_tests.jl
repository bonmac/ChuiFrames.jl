# Differential tests of the tidyr nesting and missing-value verbs against tidyr 1.3.1 (with
# dplyr 1.2.0 and tibble) through `Rscript` (tag :differential, excluded from the default run:
# `julia scripts/ci.jl test -- differential`). Each case pairs a Julia computation with the R
# expression it mirrors; results are compared as flat tables (nested columns are unnested or
# summarised by their row counts first), with the grouping columns.
#
# Documented divergences (no case encodes them, they are unit-tested instead):
# - `unnest` of a zero-row column of tables: tidyr keeps an unspecified (`<???>`) column, we keep
#   an all-`missing` object column of the same name (no table to read names or types from).
# - `expand(:a, :a)`: tidyr repairs the names (`a...1`, `a...2`); we throw an ArgumentError.
# - `unnest_longer`/`unnest_wider` over `Dict` elements follow the Dict's iteration order (R
#   lists are ordered); use an ordered dictionary for a fixed order.
# - `fill` and `complete(; fill)` treat NaN as missing, as tidyr does (vctrs `is.na`), unlike the
#   rest of ChuiFrames (ADR-0002 rule 12): matched here, not a divergence, and documented in the
#   docstrings.

@testitem "differential: tidyr nest" tags = [:differential] begin
    using Tables
    using DataAPI: nrow
    const ⨟ = ChuiFrames.Upstream.:⨟

    function run_differential()
        rscript = Sys.which("Rscript")
        if rscript === nothing
            @info "differential: Rscript not found on PATH; skipping the tidyr nest comparison"
            @test_skip false
            return
        end

        # ---- fixed data -------------------------------------------------------------------------
        d = (
            g = Union{Missing, String}["b", "a", "b", missing, "a", "c", "b"],
            x = Union{Missing, Float64}[1.5, NaN, missing, -0.0, 2.0, 3.0, missing],
            y = [10, 20, 30, 40, 50, 60, 70],
        )
        e = (g = String[], x = Float64[], y = Int[])
        fd = (
            g = [1, 1, 1, 1, 2, 2, 2, 2],
            v = Union{Missing, Float64}[missing, 3.0, missing, NaN, missing, NaN, 1.0, missing],
            w = Union{Missing, String}["a", missing, missing, "b", missing, "c", missing, missing],
        )
        ce = (
            a = Union{Missing, Float64}[2.0, 1.0, missing, 2.0, 1.0],
            b = Union{Missing, String}["y", "x", "x", missing, "x"],
            k = [true, false, true, true, true],
            n = Union{Missing, Int}[1, 2, 3, missing, 5],
        )
        ce0 = (a = Float64[], b = String[], k = Bool[], n = Int[])
        rnum(v) = ismissing(v) ? "NA" : isnan(v) ? "NaN" : isinf(v) ? (v > 0 ? "Inf" : "-Inf") : (iszero(v) && signbit(v) ? "-0" : repr(v))
        rstr(v) = ismissing(v) ? "NA" : repr(v)
        rint(v) = ismissing(v) ? "NA" : string(v, "L")
        rlgl(v) = ismissing(v) ? "NA" : v ? "TRUE" : "FALSE"
        rvec(f, v) = "c(" * join(f.(v), ", ") * ")"
        rdata = """
        d <- tibble::tibble(g = $(rvec(rstr, d.g)), x = $(rvec(rnum, d.x)), y = $(rvec(rint, d.y)))
        e <- d[0, ]
        fd <- tibble::tibble(g = $(rvec(rint, fd.g)), v = $(rvec(rnum, fd.v)), w = $(rvec(rstr, fd.w)))
        ce <- tibble::tibble(a = $(rvec(rnum, ce.a)), b = $(rvec(rstr, ce.b)), k = $(rvec(rlgl, ce.k)), n = $(rvec(rint, ce.n)))
        ce0 <- ce[0, ]
        lf <- tibble::tibble(g = 1:4, data = list(tibble::tibble(x = 1:2, s = c("p", "q")), tibble::tibble(x = integer(), s = character()), NULL, tibble::tibble(x = 3L, s = NA)))
        lv <- tibble::tibble(g = 1:4, v = list(c(1L, 2L), integer(), NULL, 3L))
        ln <- tibble::tibble(g = 1:3, v = list(list(a = 1, b = 2), list(a = 3), NULL))
        lw <- tibble::tibble(g = 1:3, v = list(list(a = 1, b = "x"), NULL, list(b = "y", c = TRUE)))
        lu <- tibble::tibble(g = 1:2, v = list(c(1L, 2L), 3L))
        """
        lf = (g = [1, 2, 3, 4], data = Any[Frame(x = [1, 2], s = ["p", "q"]), Frame(x = Int[], s = String[]), missing, Frame(x = [3], s = Union{Missing, String}[missing])])
        lv = (g = [1, 2, 3, 4], v = Union{Missing, Vector{Int}}[[1, 2], Int[], missing, [3]])
        ln = (g = [1, 2, 3], v = Any[(a = 1.0, b = 2.0), (a = 3.0,), missing])
        lw = (g = [1, 2, 3], v = Any[(a = 1.0, b = "x"), missing, (b = "y", c = true)])
        lu = (g = [1, 2], v = [[1, 2], [3]])
        sizes(r) = (g = Tables.getcolumn(r, :g), n = [nrow(x) for x in Tables.getcolumn(r, :data)])

        # ---- cases: (name, Julia result thunk, R expression) -----------------------------------
        cases = [
            # nest / unnest
            ("nest_sizes", () -> sizes(nest(data = [:x, :y])(d)), "nest(d, data = c(x, y)) |> mutate(n = vapply(data, nrow, integer(1))) |> select(g, n)"),
            ("nest_roundtrip", () -> (nest(data = Not(:g)) ⨟ unnest(:data))(d), "nest(d, data = -g) |> unnest(data)"),
            ("nest_grouped", () -> (group_by(:g) ⨟ nest() ⨟ unnest(:data))(d), "d |> group_by(g) |> nest() |> unnest(data)"),
            ("nest_two", () -> (nest(a = :x, b = :y) ⨟ unnest(:a, :b))(d), "nest(d, a = x, b = y) |> unnest(c(a, b))"),
            ("nest_empty", () -> (nest(data = [:x, :y]) ⨟ unnest(:data) ⨟ select(:g))(e), "nest(e, data = c(x, y)) |> unnest(data) |> select(g)"),
            ("unnest_frames", () -> unnest(:data)(lf), "unnest(lf, data)"),
            ("unnest_keep_empty", () -> unnest(:data; keep_empty = true)(lf), "unnest(lf, data, keep_empty = TRUE)"),
            ("unnest_names_sep", () -> unnest(:data; names_sep = "_")(lf), "unnest(lf, data, names_sep = '_')"),
            ("unnest_vectors", () -> unnest(:v)(lv), "unnest(lv, v)"),
            ("unnest_vectors_keep", () -> unnest(:v; keep_empty = true)(lv), "unnest(lv, v, keep_empty = TRUE)"),
            # unnest_longer / unnest_wider
            ("longer", () -> unnest_longer(:v)(lv), "unnest_longer(lv, v)"),
            ("longer_idx_keep", () -> unnest_longer(:v; values_to = :val, indices_to = :i, keep_empty = true)(lv), "unnest_longer(lv, v, values_to = 'val', indices_to = 'i', keep_empty = TRUE)"),
            ("longer_named", () -> unnest_longer(:v)(ln), "unnest_longer(ln, v)"),
            ("wider_named", () -> unnest_wider(:v)(ln), "unnest_wider(ln, v)"),
            ("wider_mixed", () -> unnest_wider(:v)(lw), "unnest_wider(lw, v)"),
            ("wider_sep", () -> unnest_wider(:v; names_sep = "_")(lu), "unnest_wider(lu, v, names_sep = '_')"),
            # pack / unpack
            ("pack_unpack_sep", () -> (pack(xy = [:x, :y]) ⨟ unpack(:xy; names_sep = "_"))(d), "pack(d, xy = c(x, y)) |> unpack(xy, names_sep = '_')"),
            ("pack_grouped", () -> (group_by(:g) ⨟ pack(xy = [:x, :y]) ⨟ unpack(:xy))(d), "d |> group_by(g) |> pack(xy = c(x, y)) |> unpack(xy)"),
            ("pack_empty", () -> (pack(gy = [:g, :y]) ⨟ unpack(:gy))(e), "pack(e, gy = c(g, y)) |> unpack(gy)"),
            # fill, every direction, ungrouped and grouped (NaN counts as missing, as tidyr)
            [("fill_$dir", () -> fill(c.v, c.w; direction = dir)(fd), "fill(fd, v, w, .direction = '$dir')") for dir in (:down, :up, :downup, :updown)]...,
            [("fill_grouped_$dir", () -> (group_by(:g) ⨟ fill(c.v, c.w; direction = dir))(fd), "fd |> group_by(g) |> fill(v, w, .direction = '$dir')") for dir in (:down, :up, :downup, :updown)]...,
            ("fill_empty", () -> fill(c.x)(e), "fill(e, x)"),
            # expand / nesting / complete
            ("expand_ab", () -> expand(:a, :b)(ce), "expand(ce, a, b)"),
            ("expand_ba", () -> expand(:b, :a)(ce), "expand(ce, b, a)"),
            ("expand_nesting", () -> expand(nesting(:a, :b), :k)(ce), "expand(ce, nesting(a, b), k)"),
            ("expand_grouped", () -> expand(:a, :b)(group_by(:k)(ce)), "ce |> group_by(k) |> expand(a, b)"),
            ("expand_nan", () -> expand(:x)(d), "expand(d, x)"),
            ("expand_empty", () -> expand(:a, :b)(ce0), "expand(ce0, a, b)"),
            ("complete_ab", () -> complete(:a, :b)(ce), "complete(ce, a, b)"),
            ("complete_fill", () -> complete(:a, :b; fill = (n = 0, k = false))(ce), "complete(ce, a, b, fill = list(n = 0L, k = FALSE))"),
            ("complete_implicit", () -> complete(:a, :b; fill = (n = 0,), explicit = false)(ce), "complete(ce, a, b, fill = list(n = 0L), explicit = FALSE)"),
            ("complete_nesting", () -> complete(nesting(:a, :b), :k)(ce), "complete(ce, nesting(a, b), k)"),
            ("complete_grouped", () -> complete(:a, :b)(group_by(:k)(ce)), "ce |> group_by(k) |> complete(a, b)"),
            ("complete_nan_fill", () -> complete(:g; fill = (x = 0.0,))(d), "complete(d, g, fill = list(x = 0))"),
            ("complete_empty", () -> complete(:a, :b)(ce0), "complete(ce0, a, b)"),
        ]

        # ---- run R once -------------------------------------------------------------------------
        rcode = """
            suppressPackageStartupMessages({ library(dplyr); library(tidyr) })
            stopifnot(packageVersion("tidyr") == "1.3.1", packageVersion("dplyr") == "1.2.0")
            fmt <- function(v) {
              if (is.logical(v)) return(ifelse(is.na(v), "NA", ifelse(v, "TRUE", "FALSE")))
              if (is.numeric(v)) { v <- as.double(v); return(ifelse(is.nan(v), "NaN", ifelse(is.na(v), "NA", sprintf("%.17g", v)))) }
              ifelse(is.na(v), "NA", as.character(v))
            }
            emit <- function(name, r) {
              cat("CASE\\t", name, "\\t", nrow(r), "\\t", paste(group_vars(r), collapse = ","), "\\n", sep = "")
              for (nm in names(r)) cat("COL\\t", nm, "\\t", paste(fmt(r[[nm]]), collapse = "|"), "\\n", sep = "")
            }
            $rdata
            """ * join(["emit($(repr(nm)), $(rx))" for (nm, _, rx) in cases], "\n")
        dir = mktempdir()
        rfile = joinpath(dir, "cases.R")
        write(rfile, rcode)
        out = read(`$rscript --vanilla $rfile`, String)

        # ---- parse R output ---------------------------------------------------------------------
        parseval(s) = s == "NA" ? missing : s == "NaN" ? NaN : s == "TRUE" ? true : s == "FALSE" ? false :
            (x = tryparse(Float64, s); x === nothing ? s : x)
        rres = Dict{String, Any}()
        cur = ""
        for line in split(out, '\n'; keepempty = false)
            f = split(line, '\t')
            if f[1] == "CASE"
                cur = String(f[2])
                rres[cur] = (n = parse(Int, f[3]), groups = filter(!isempty, split(f[4], ',')), cols = Pair{String, Vector{Any}}[])
            elseif f[1] == "COL"
                vals = length(f) < 3 || isempty(f[3]) ? Any[] : Any[parseval(String(s)) for s in split(f[3], '|')]
                push!(rres[cur].cols, String(f[2]) => vals)
            end
        end

        same(a, b) = (ismissing(a) && ismissing(b)) ||
            (
            !ismissing(a) && !ismissing(b) && (
                (a isa Number && b isa Number && (isequal(Float64(a), Float64(b)) || isapprox(Float64(a), Float64(b); rtol = 1.0e-12, atol = 1.0e-12))) ||
                    (!(a isa Number) && !(b isa Number) && string(a) == string(b))
            )
        )
        function compare(nm, jl, r)
            jcols = Pair{String, Vector{Any}}[string(k) => Any[x for x in Tables.getcolumn(jl, k)] for k in Tables.columnnames(jl)]
            okn = [first(p) for p in jcols] == [first(p) for p in r.cols]
            okn || @info "differential mismatch (names)" case = nm julia = first.(jcols) tidyr = first.(r.cols)
            @test okn
            okall = okn
            for ((jk, jv), (rk, rv)) in zip(jcols, r.cols)
                ok = length(jv) == length(rv) && all(same(a, b) for (a, b) in zip(jv, rv))
                ok || @info "differential mismatch" case = nm column = jk julia = jv tidyr = rv
                @test ok
                okall &= ok
            end
            okg = string.(groupcols(jl)) == r.groups
            okg || @info "differential mismatch (groups)" case = nm julia = groupcols(jl) tidyr = r.groups
            @test okg
            return okall && okg
        end
        passed = 0
        for (nm, thunk, _) in cases
            @test haskey(rres, nm)
            haskey(rres, nm) || continue
            passed += compare(nm, thunk(), rres[nm])
        end
        @info "differential: $(passed)/$(length(cases)) cases agree with tidyr 1.3.1"
        return nothing
    end
    run_differential()
end
