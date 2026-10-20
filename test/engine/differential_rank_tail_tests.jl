# Differential tests of the phase-2b ranking tail against dplyr 1.2.0 through `Rscript` (tag
# :differential, excluded from the default run: `julia scripts/ci.jl test -- differential`).
# Modelled on differential_dplyr_tests.jl: fixed generated data with missing, NaN, ±0.0 and ±Inf.
#
# Documented divergences, and how each case avoids or encodes it:
# - group_by(drop = false) orders groups by CF-008's `isless` order of the key values; dplyr
#   orders a factor by its level order. The R side sorts its result by the key values
#   (`arrange(as.character(f))`), so the case compares the same groups and counts.
# - when_any/when_all broadcast a constant argument; dplyr requires every argument to have the
#   frame's size. Not exercised (dplyr errors).
# - NaN in a comparison is `false` in Julia and NA in R (ADR-0002 rule 12), so the when_any /
#   when_all cases use comparisons on the NaN-free Int column `y` and the logical columns.
# - `maximum` of an empty (drop = false) group is an ArgumentError (CC-007); R warns and gives
#   -Inf. Not exercised.
# - Strings in the arrange(locale) cases are compared by row id only, so no non-ASCII text goes
#   through R's output encoding; the R source writes them as \u escapes.

@testitem "differential: dplyr rank tail" tags = [:differential] begin
    using Tables, Statistics
    const ⨟ = ChuiFrames.Upstream.:⨟

    function run_differential_rank_tail()
        rscript = Sys.which("Rscript")
        if rscript === nothing
            @info "differential rank tail: Rscript not found on PATH; skipping the dplyr comparison"
            @test_skip false
            return
        end

        # ---- fixed data ---------------------------------------------------------------------------
        n = 40
        XS = Union{Missing, Float64}[1.5, NaN, missing, -0.0, 0.0, 3.0, -2.0, 1.0, Inf, -Inf]
        GS = Union{Missing, String}["a", "b", "c", missing]
        LS = Union{Missing, Bool}[true, false, missing]
        SS = Union{Missing, String}["b", "B", "a", "A", "é", "e", "Z", "z", "_", "1", "ä", "Ab", "ab", missing]
        # factor levels, deliberately not sorted, with absent levels "q" and "m"
        LEVELS = ["z", "b", "q", "a", "m"]
        FS = Union{Missing, String}["z", "b", "a", missing, "b"]
        fvals = Union{Missing, String}[FS[mod(i * 3 + div(i, 7), 5) + 1] for i in 1:n]
        fcol = ChuiFrames.DictColumn(
            UInt8[ismissing(v) ? 0 : findfirst(==(v), LEVELS) for v in fvals],
            ChuiFrames.column(LEVELS), BitVector(!ismissing(v) for v in fvals),
        )
        d = (
            id = collect(1:n),
            g = Union{Missing, String}[GS[mod(i * 3, 4) + 1] for i in 1:n],
            x = Union{Missing, Float64}[XS[mod(i * 7, 10) + 1] for i in 1:n],
            y = [mod(i * 5, 7) - 3 for i in 1:n],
            a = Union{Missing, Bool}[LS[mod(i, 3) + 1] for i in 1:n],
            b = Union{Missing, Bool}[LS[mod(div(i, 3), 3) + 1] for i in 1:n],
            s = Union{Missing, String}[SS[mod(i * 5, 14) + 1] for i in 1:n],
            f = fcol,
        )
        rnum(v) = ismissing(v) ? "NA" : isnan(v) ? "NaN" : isinf(v) ? (v > 0 ? "Inf" : "-Inf") : (iszero(v) && signbit(v) ? "-0" : repr(v))
        resc(s) = join(isascii(ch) ? string(ch) : "\\u" * string(UInt32(ch); base = 16, pad = 4) for ch in s)
        rstr(v) = ismissing(v) ? "NA" : "\"" * resc(v) * "\""
        rlgl(v) = ismissing(v) ? "NA" : v ? "TRUE" : "FALSE"
        rdata = """
        d <- tibble::tibble(
          id = c($(join(d.id, ", "))),
          g = c($(join(rstr.(d.g), ", "))),
          x = c($(join(rnum.(d.x), ", "))),
          y = c($(join(string.(d.y) .* "L", ", "))),
          a = c($(join(rlgl.(d.a), ", "))),
          b = c($(join(rlgl.(d.b), ", "))),
          s = c($(join(rstr.(d.s), ", "))),
          f = factor(c($(join(rstr.(fvals), ", "))), levels = c($(join(rstr.(LEVELS), ", "))))
        )
        """

        # ---- cases: (name, Julia pipeline, R expression on `d`) --------------------------------------
        cases = [
            (
                "ranks_ungrouped",
                mutate(pr = percent_rank(c.x), cd = cume_dist(c.x), nt = ntile(c.x, 3), nty = ntile(c.y, 6)) ⨟ select(:id, :pr, :cd, :nt, :nty),
                "d |> mutate(pr = percent_rank(x), cd = cume_dist(x), nt = ntile(x, 3), nty = ntile(y, 6)) |> select(id, pr, cd, nt, nty)",
            ),
            (
                "ranks_desc",
                mutate(pr = percent_rank(desc(c.x)), cd = cume_dist(desc(c.x)), nt = ntile(desc(c.x), 4), py = percent_rank(desc(c.y))) ⨟ select(:id, :pr, :cd, :nt, :py),
                "d |> mutate(pr = percent_rank(desc(x)), cd = cume_dist(desc(x)), nt = ntile(desc(x), 4), py = percent_rank(desc(y))) |> select(id, pr, cd, nt, py)",
            ),
            (
                "ranks_grouped",
                group_by(:g) ⨟ mutate(pr = percent_rank(c.y), cd = cume_dist(c.x), nt = ntile(c.x, 2), nd = ntile(desc(c.y), 3), nn = ntile(n = 3)) ⨟ ungroup() ⨟ select(:id, :pr, :cd, :nt, :nd, :nn),
                "d |> group_by(g) |> mutate(pr = percent_rank(y), cd = cume_dist(x), nt = ntile(x, 2), nd = ntile(desc(y), 3), nn = ntile(n = 3)) |> ungroup() |> select(id, pr, cd, nt, nd, nn)",
            ),
            (
                "ntile_more_tiles", mutate(nt = ntile(c.y, 50)) ⨟ select(:id, :nt),
                "d |> mutate(nt = ntile(y, 50)) |> select(id, nt)",
            ),
            (
                "when_any_all",
                mutate(wa = when_any(c.a, c.b), wl = when_all(c.a, c.b), war = when_any(c.a, c.b; na_rm = true), wlr = when_all(c.a, c.b; na_rm = true), wy = when_any(c.y .> 1, c.a, c.y .< -2), wz = when_all(c.y .>= -1, c.b)) ⨟ select(:id, :wa, :wl, :war, :wlr, :wy, :wz),
                "d |> mutate(wa = when_any(a, b), wl = when_all(a, b), war = when_any(a, b, na_rm = TRUE), wlr = when_all(a, b, na_rm = TRUE), wy = when_any(y > 1, a, y < -2), wz = when_all(y >= -1, b)) |> select(id, wa, wl, war, wlr, wy, wz)",
            ),
            (
                "when_filter", filter(when_any(c.a, c.y .> 2)) ⨟ select(:id),
                "d |> filter(when_any(a, y > 2)) |> select(id)",
            ),
            (
                "when_all_grouped_filter", group_by(:g) ⨟ filter(when_all(c.b, c.y .== maximum(c.y); na_rm = true)) ⨟ ungroup() ⨟ select(:id),
                "d |> group_by(g) |> filter(when_all(b, y == max(y), na_rm = TRUE)) |> ungroup() |> select(id)",
            ),
            (   # level order (dplyr) vs value order (CF-008): R sorts by the key values
                "drop_false_factor",
                group_by(:f; drop = false) ⨟ summarise(n = n_rows(), s = sum(c.y), m = mean(c.y)),
                "d |> group_by(f, .drop = FALSE) |> summarise(n = n(), s = sum(y), m = mean(y)) |> arrange(as.character(f))",
            ),
            (
                "drop_false_two_keys",
                group_by(:g, :f; drop = false) ⨟ summarise(n = n_rows()) ⨟ ungroup(),
                "d |> group_by(g, f, .drop = FALSE) |> summarise(n = n()) |> ungroup() |> arrange(g, as.character(f))",
            ),
            (
                "drop_false_factor_first",
                group_by(:f, :g; drop = false) ⨟ summarise(n = n_rows()) ⨟ ungroup(),
                "d |> group_by(f, g, .drop = FALSE) |> summarise(n = n()) |> ungroup() |> arrange(as.character(f), g)",
            ),
            (
                "drop_true_factor", group_by(:f) ⨟ summarise(n = n_rows()),
                "d |> group_by(f) |> summarise(n = n()) |> arrange(as.character(f))",
            ),
            ("arrange_locale_c", arrange(c.s; locale = "C") ⨟ select(:id), "d |> arrange(s, .locale = 'C') |> select(id)"),
            ("arrange_locale_default", arrange(c.s) ⨟ select(:id), "d |> arrange(s) |> select(id)"),
            ("arrange_locale_desc", arrange(desc(c.s), c.id; locale = "C") ⨟ select(:id), "d |> arrange(desc(s), id, .locale = 'C') |> select(id)"),
        ]

        # ---- run R once ---------------------------------------------------------------------------
        rcode = """
            suppressPackageStartupMessages(library(dplyr))
            options(dplyr.summarise.inform = FALSE)
            stopifnot(packageVersion("dplyr") == "1.2.0")
            fmt <- function(v) {
              if (is.factor(v)) v <- as.character(v)
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

        # ---- parse R output -----------------------------------------------------------------------
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
            @test [first(p) for p in jcols] == [first(p) for p in r.cols]
            okall = length(jcols) == length(r.cols)
            for ((jk, jv), (rk, rv)) in zip(jcols, r.cols)
                ok = length(jv) == length(rv) && all(same(a, b) for (a, b) in zip(jv, rv))
                ok || @info "differential mismatch" case = nm column = jk julia = jv dplyr = rv
                @test ok
                okall &= ok
            end
            @test string.(groupcols(jl)) == r.groups
            return okall
        end
        passed = 0
        for (nm, pipe, _) in cases
            @test haskey(rres, nm)
            haskey(rres, nm) || continue
            passed += compare(nm, pipe(d), rres[nm])
        end
        # the drop = false cases really keep empty groups (absent levels "q" and "m")
        @test any(iszero, last(only(filter(p -> first(p) == "n", rres["drop_false_factor"].cols))))
        @info "differential rank tail: $(passed)/$(length(cases)) cases agree with dplyr 1.2.0"
        return nothing
    end
    run_differential_rank_tail()
end
