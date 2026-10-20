# Differential tests against dplyr 1.2.0 through `Rscript` (tag :differential, excluded from the
# default run: `julia scripts/ci.jl test -- differential`). The R snippets are below, next to
# the Julia pipelines they mirror. Fixed generated data with missing, NaN, ±0.0 and ±Inf, and
# cases with empty results. Documented divergences (ADR-0002 rule 12: a predicate that is true
# on NaN keeps the row in Julia, dplyr drops it) are encoded as expected differences.

@testitem "differential: dplyr 1.2.0" tags = [:differential] begin
    using Tables, Statistics
    const ⨟ = ChuiFrames.Upstream.:⨟

    # a function body, so the loops below have local scope
    function run_differential()
        rscript = Sys.which("Rscript")
        if rscript === nothing
            @info "differential: Rscript not found on PATH; skipping the dplyr comparison"
            @test_skip false
            return
        end

        # ---- fixed data ---------------------------------------------------------------------------
        n = 40
        XS = Union{Missing, Float64}[1.5, NaN, missing, -0.0, 0.0, 3.0, -2.0, 1.0, Inf, -Inf]
        GS = Union{Missing, String}["a", "b", "c", missing]
        KS = Union{Missing, Float64}[0.0, -0.0, NaN, missing, 1.0]
        d = (
            id = collect(1:n),
            g = Union{Missing, String}[GS[mod(i * 3, 4) + 1] for i in 1:n],
            k = Union{Missing, Float64}[KS[mod(i * 2 + div(i, 5), 5) + 1] for i in 1:n],
            x = Union{Missing, Float64}[XS[mod(i * 7, 10) + 1] for i in 1:n],
            y = [mod(i * 5, 7) - 3 for i in 1:n],
        )
        rnum(v) = ismissing(v) ? "NA" : isnan(v) ? "NaN" : isinf(v) ? (v > 0 ? "Inf" : "-Inf") : (iszero(v) && signbit(v) ? "-0" : repr(v))
        rstr(v) = ismissing(v) ? "NA" : repr(v)
        rdata = """
        d <- tibble::tibble(
          id = c($(join(d.id, ", "))),
          g = c($(join(rstr.(d.g), ", "))),
          k = c($(join(rnum.(d.k), ", "))),
          x = c($(join(rnum.(d.x), ", "))),
          y = c($(join(string.(d.y) .* "L", ", ")))
        )
        """

        # ---- cases: (name, Julia pipeline, R expression on `d`, kind) -------------------------------
        # kind :exact; :nan_kept (rule 12: Julia additionally keeps the rows where x is NaN); or
        # :skip_keeps_nan (R's na.rm = TRUE drops NaN as well as NA; Julia's skipmissing keeps NaN, so
        # the `sx` sum is NaN in Julia for groups holding a NaN, and equal elsewhere)
        cases = [
            ("filter_gt", filter(c.x .> 1), "filter(d, x > 1)", :exact),
            ("filter_not_gt", filter(.!(c.x .> 1)), "filter(d, !(x > 1))", :nan_kept),
            ("filter_ne", filter(c.x .!= 1), "filter(d, x != 1)", :nan_kept),
            ("filter_and", filter(c.x .> -3, c.y .>= 0), "filter(d, x > -3, y >= 0)", :exact),
            ("filter_empty", filter(c.y .> 100), "filter(d, y > 100)", :exact),
            ("filter_out", filter_out(c.x .> 1), "filter_out(d, x > 1)", :exact),
            ("filter_grouped", group_by(:g) ⨟ filter(c.y .== maximum(c.y)) ⨟ ungroup(), "d |> group_by(g) |> filter(y == max(y)) |> ungroup()", :exact),
            ("arrange_x", arrange(c.x) ⨟ select(:id), "arrange(d, x) |> select(id)", :exact),
            ("arrange_desc", arrange(desc(c.x)) ⨟ select(:id), "arrange(d, desc(x)) |> select(id)", :exact),
            ("arrange_multi", arrange(c.g, desc(c.k), c.y) ⨟ select(:id), "arrange(d, g, desc(k), y) |> select(id)", :exact),
            (
                "summarise_g", group_by(:g) ⨟ summarise(n = n_rows(), s = sum(c.y), m = mean(c.y), mx = maximum(c.y), sx = sum(skipmissing(c.x))),
                "d |> group_by(g) |> summarise(n = n(), s = sum(y), m = mean(y), mx = max(y), sx = sum(x, na.rm = TRUE))", :skip_keeps_nan,
            ),
            (   # the same without NaN in the data: skipmissing and na.rm agree
                "summarise_skip_nonan", filter(.!isnan.(coalesce.(c.x, 0.0))) ⨟ group_by(:g) ⨟ summarise(sx = sum(skipmissing(c.x))),
                "d |> filter(!is.nan(x)) |> group_by(g) |> summarise(sx = sum(x, na.rm = TRUE))", :exact,
            ),
            ("summarise_k", group_by(:k) ⨟ summarise(n = n_rows(), s = sum(c.y)), "d |> group_by(k) |> summarise(n = n(), s = sum(y))", :exact),
            ("summarise_gk", group_by(:g, :k) ⨟ summarise(n = n_rows()) ⨟ ungroup(), "d |> group_by(g, k) |> summarise(n = n()) |> ungroup()", :exact),
            ("summarise_empty_grouped", filter(c.y .> 100) ⨟ group_by(:g) ⨟ summarise(n = n_rows()), "d |> filter(y > 100) |> group_by(g) |> summarise(n = n())", :exact),
            ("summarise_empty", filter(c.y .> 100) ⨟ summarise(n = n_rows(), s = sum(c.y)), "d |> filter(y > 100) |> summarise(n = n(), s = sum(y))", :exact),
            (
                "window", group_by(:g) ⨟ mutate(dm = c.y .- mean(c.y), r = row_number(), l = lag(c.y), ld = lead(c.y, 1; default = 0), cs = cumsum(c.y), cm = cummean(c.y)) ⨟ ungroup() ⨟ select(:id, :dm, :r, :l, :ld, :cs, :cm),
                "d |> group_by(g) |> mutate(dm = y - mean(y), r = row_number(), l = lag(y), ld = lead(y, 1, default = 0L), cs = cumsum(y), cm = cummean(y)) |> ungroup() |> select(id, dm, r, l, ld, cs, cm)", :exact,
            ),
            (
                "ranks", mutate(rn = row_number(c.x), mr = min_rank(c.x), dr = dense_rank(c.x), md = min_rank(desc(c.y))) ⨟ select(:id, :rn, :mr, :dr, :md),
                "d |> mutate(rn = row_number(x), mr = min_rank(x), dr = dense_rank(x), md = min_rank(desc(y))) |> select(id, rn, mr, dr, md)", :exact,
            ),
            ("n_distinct", group_by(:g) ⨟ summarise(nx = n_distinct(c.x), nk = n_distinct(c.k)), "d |> group_by(g) |> summarise(nx = n_distinct(x), nk = n_distinct(k))", :exact),
            ("distinct_gk", distinct(:g, :k), "distinct(d, g, k)", :exact),
            ("count_g", count_by(:g), "count(d, g)", :exact),
            ("count_sorted", count_by(:k; sort = true), "count(d, k, sort = TRUE)", :exact),
            ("count_wt", count_by(:g; wt = c.y), "count(d, g, wt = y)", :exact),
            ("tally", group_by(:g) ⨟ tally(), "d |> group_by(g) |> tally()", :exact),
            ("add_count", add_count(:g) ⨟ select(:id, :n), "add_count(d, g) |> select(id, n)", :exact),
            ("slice_head", group_by(:g) ⨟ slice_head(n = 2) ⨟ ungroup() ⨟ select(:id), "d |> group_by(g) |> slice_head(n = 2) |> ungroup() |> select(id)", :exact),
            ("slice_tail", group_by(:g) ⨟ slice_tail(n = 1) ⨟ ungroup() ⨟ select(:id), "d |> group_by(g) |> slice_tail(n = 1) |> ungroup() |> select(id)", :exact),
            ("slice", group_by(:g) ⨟ slice(2:3) ⨟ ungroup() ⨟ select(:id), "d |> group_by(g) |> slice(2:3) |> ungroup() |> select(id)", :exact),
            ("slice_min", group_by(:g) ⨟ slice_min(c.y; n = 2) ⨟ ungroup() ⨟ select(:id), "d |> group_by(g) |> slice_min(y, n = 2) |> ungroup() |> select(id)", :exact),
            ("slice_max_noties", slice_max(c.y; n = 3, with_ties = false) ⨟ select(:id), "d |> slice_max(y, n = 3, with_ties = FALSE) |> select(id)", :exact),
            ("slice_min_x", slice_min(c.x; n = 4) ⨟ select(:id), "d |> slice_min(x, n = 4) |> select(id)", :exact),
            ("case_when", mutate(cw = case_when((c.x .> 1) => "big", (c.x .<= 0) => "neg"; default = "other")) ⨟ select(:id, :cw), "d |> mutate(cw = case_when(x > 1 ~ 'big', x <= 0 ~ 'neg', .default = 'other')) |> select(id, cw)", :exact),
            ("consecutive_id", mutate(ci = consecutive_id(c.g)) ⨟ select(:id, :ci), "d |> mutate(ci = consecutive_id(g)) |> select(id, ci)", :exact),
            ("between", mutate(b = between(c.y, -1, 1)) ⨟ select(:id, :b), "d |> mutate(b = between(y, -1, 1)) |> select(id, b)", :exact),
            ("if_any", filter(if_any([:x, :y], v -> v .> 2)) ⨟ select(:id), "d |> filter(if_any(c(x, y), ~ .x > 2)) |> select(id)", :exact),
            ("across_mean", group_by(:g) ⨟ summarise(across([:x, :y], mean)), "d |> group_by(g) |> summarise(across(c(x, y), mean))", :exact),
            ("select_rename", select(:y, :g) ⨟ rename(G = :g) ⨟ relocate(:G), "d |> select(y, g) |> rename(G = g) |> relocate(G)", :exact),
            ("mutate_keep", mutate(z = c.y .* 2; keep = :used), "mutate(d, z = y * 2, .keep = 'used')", :exact),
            ("reframe", group_by(:g) ⨟ reframe(q = quantile(c.y, [0.25, 0.75])), "d |> group_by(g) |> reframe(q = quantile(y, c(0.25, 0.75)))", :exact),
            ("bind_rows", select(:id, :g) ⨟ bind_rows((id = [99], h = ["z"]); id = :src), "bind_rows(select(d, id, g), tibble::tibble(id = 99L, h = 'z'), .id = 'src') |> mutate(src = as.integer(src))", :exact),
            ("union", select(:g) ⨟ union_rows((g = ["z", "a"],)), "union(select(d, g), tibble::tibble(g = c('z', 'a')))", :exact),
            ("intersect", select(:k) ⨟ intersect_rows((k = [0.0, NaN, 5.0],)), "intersect(select(d, k), tibble::tibble(k = c(0, NaN, 5)))", :exact),
            ("setdiff", select(:g) ⨟ setdiff_rows((g = ["a"],)), "setdiff(select(d, g), tibble::tibble(g = 'a'))", :exact),
        ]

        # ---- run R once ---------------------------------------------------------------------------
        rcode = """
            suppressPackageStartupMessages(library(dplyr))
            options(dplyr.summarise.inform = FALSE)
            stopifnot(packageVersion("dplyr") == "1.2.0")
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
            """ * join(["emit($(repr(nm)), $(rx))" for (nm, _, rx, _) in cases], "\n")
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
        function compare(nm, jl, r, kind)
            jcols = Pair{String, Vector{Any}}[string(k) => Any[x for x in Tables.getcolumn(jl, k)] for k in Tables.columnnames(jl)]
            if kind === :nan_kept
                xs = Any[x for x in Tables.getcolumn(jl, :x)]
                keep = [!(x isa AbstractFloat && isnan(x)) for x in xs]
                @test any(!, keep)                          # the divergence really occurs ...
                jcols = [k => v[keep] for (k, v) in jcols]  # ... and is the only difference
            end
            @test [first(p) for p in jcols] == [first(p) for p in r.cols]
            okall = length(jcols) == length(r.cols)
            for ((jk, jv), (rk, rv)) in zip(jcols, r.cols)
                if kind === :skip_keeps_nan && jk == "sx"
                    nanrows = [x isa AbstractFloat && isnan(x) for x in jv]
                    @test any(nanrows)                      # the divergence really occurs
                    jv, rv = jv[.!nanrows], rv[.!nanrows]
                end
                ok = length(jv) == length(rv) && all(same(a, b) for (a, b) in zip(jv, rv))
                ok || @info "differential mismatch" case = nm column = jk julia = jv dplyr = rv
                @test ok
                okall &= ok
            end
            @test string.(groupcols(jl)) == r.groups
            return okall
        end
        passed = 0
        for (nm, pipe, _, kind) in cases
            @test haskey(rres, nm)
            haskey(rres, nm) || continue
            passed += compare(nm, pipe(d), rres[nm], kind)
        end
        @info "differential: $(passed)/$(length(cases)) cases agree with dplyr 1.2.0 ($(count(x -> x[4] !== :exact, cases)) with an encoded NaN divergence)"
        return nothing
    end
    run_differential()
end
