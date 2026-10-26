# Differential tests of the join verbs against dplyr 1.2.0 (with tidyr 1.3.1 for `unnest`)
# through `Rscript` (tag :differential, excluded from the default run:
# `julia scripts/ci.jl test -- differential`). Phase-4 spec
# docs/superpowers/specs/2026-10-26-phase4-joins-groupby-codegen-design.md §1.6, §4. Each case
# pairs a Julia computation with the R expression it mirrors; results are compared as flat
# tables (names, values in order, grouping). The Julia side passes `suffix = (".x", ".y")` where
# names clash, so dplyr's names compare directly (the default `("_x", "_y")` is a documented
# divergence, docs/research/parity-dplyr.md). Error cases compare dplyr's message lines.
#
# Divergences, documented and not encoded (docs/research/differentials-joins.md): the default
# suffix; nest_join's default `name` (`:y`, dplyr deparses the argument); `multiple = "warning"`
# and the `relationship` warning (not offered); integer keys above 2^53 (no dplyr counterpart).

@testitem "differential: dplyr joins" tags = [:differential] begin
    using Tables
    using DataAPI: nrow
    const ⨟ = ChuiFrames.Upstream.:⨟

    function run_differential()
        rscript = Sys.which("Rscript")
        if rscript === nothing
            @info "differential: Rscript not found on PATH; skipping the dplyr join comparison"
            @test_skip false
            return
        end
        F = Union{Missing, Float64}
        x = Frame(k = F[2.0, 1.0, NaN, missing, -0.0, 2.0, 7.0], i = [1, 2, 1, 3, 2, 1, 1], v = ["a", "b", "c", "d", "e", "f", "g"])
        y = Frame(k = F[2.0, 0.0, NaN, 2.0, 5.0, missing], i = [1, 1, 2, 3, 1, 1], w = [10.0, 20.0, 30.0, 40.0, 50.0, 60.0], v = ["p", "q", "r", "s", "t", "u"])
        x0 = Frame(k = F[], i = Int[], v = String[])
        y0 = Frame(k = F[], i = Int[], w = Float64[], v = String[])
        xc = Frame(a = [5, 6], y = ["old", "older"], k = [2.0, 9.0])   # a column named like nest_join's name
        # ★ K4: integer keys (inside R's 32-bit integers) against double keys
        xi = Frame(k = Union{Missing, Int}[1, 2, 3, missing, 3], a = [1, 2, 3, 4, 5])
        yd = Frame(k = F[1.0, 2.5, 3.0, 3.0, missing], b = [10, 20, 30, 40, 50])
        rdata = """
        x <- tibble::tibble(k = c(2, 1, NaN, NA, -0, 2, 7), i = c(1L, 2L, 1L, 3L, 2L, 1L, 1L), v = c("a", "b", "c", "d", "e", "f", "g"))
        y <- tibble::tibble(k = c(2, 0, NaN, 2, 5, NA), i = c(1L, 1L, 2L, 3L, 1L, 1L), w = c(10, 20, 30, 40, 50, 60), v = c("p", "q", "r", "s", "t", "u"))
        x0 <- x[0, ]
        y0 <- y[0, ]
        xc <- tibble::tibble(a = c(5L, 6L), y = c("old", "older"), k = c(2, 9))
        xi <- tibble::tibble(k = c(1L, 2L, 3L, NA, 3L), a = 1:5)
        yd <- tibble::tibble(k = c(1, 2.5, 3, 3, NA), b = c(10L, 20L, 30L, 40L, 50L))
        """
        sfx = (".x", ".y")
        sizes(r, col) = (v = collect(Tables.getcolumn(r, :v)), n = [nrow(f) for f in Tables.getcolumn(r, col)])
        cases = [
            # the six keyed joins, one key, NaN/missing/±0.0 keys and duplicates
            ("inner_k", () -> inner_join(y; by = :k, suffix = sfx)(x), "inner_join(x, y, by = 'k')"),
            ("left_k", () -> left_join(y; by = :k, suffix = sfx)(x), "left_join(x, y, by = 'k')"),
            ("right_k", () -> right_join(y; by = :k, suffix = sfx)(x), "right_join(x, y, by = 'k')"),
            ("full_k", () -> full_join(y; by = :k, suffix = sfx)(x), "full_join(x, y, by = 'k')"),
            ("semi_k", () -> semi_join(y; by = :k)(x), "semi_join(x, y, by = 'k')"),
            ("anti_k", () -> anti_join(y; by = :k)(x), "anti_join(x, y, by = 'k')"),
            # na_matches = "never"
            ("inner_never", () -> inner_join(y; by = :k, na_matches = :never, suffix = sfx)(x), "inner_join(x, y, by = 'k', na_matches = 'never')"),
            ("full_never", () -> full_join(y; by = :k, na_matches = :never, suffix = sfx)(x), "full_join(x, y, by = 'k', na_matches = 'never')"),
            ("anti_never", () -> anti_join(y; by = :k, na_matches = :never)(x), "anti_join(x, y, by = 'k', na_matches = 'never')"),
            # several keys, a renamed key, keep
            ("inner_ki", () -> inner_join(y; by = [:k, :i], suffix = sfx)(x), "inner_join(x, y, by = c('k', 'i'))"),
            ("left_pair", () -> left_join(y; by = :i => :i, suffix = sfx)(x), "left_join(x, y, by = c('i' = 'i'))"),
            ("left_join_by", () -> left_join(y; by = join_by(:v => :v), suffix = sfx)(x), "left_join(x, y, by = join_by(v == v))"),
            ("inner_keep", () -> inner_join(y; by = :k, keep = true, suffix = sfx)(x), "inner_join(x, y, by = 'k', keep = TRUE)"),
            ("full_keep", () -> full_join(y; by = :i, keep = true, suffix = sfx)(x), "full_join(x, y, by = 'i', keep = TRUE)"),
            ("right_ki_keep", () -> right_join(y; by = [:i => :i, :k => :k], keep = true, suffix = sfx)(x), "right_join(x, y, by = c('i', 'k'), keep = TRUE)"),
            # multiple, and unchosen y rows counting as unmatched (critic n3)
            ("inner_first", () -> inner_join(y; by = :k, multiple = :first, suffix = sfx)(x), "inner_join(x, y, by = 'k', multiple = 'first')"),
            ("left_last", () -> left_join(y; by = :i, multiple = :last, suffix = sfx)(x), "left_join(x, y, by = 'i', multiple = 'last')"),
            ("right_first", () -> right_join(y; by = :k, multiple = :first, suffix = sfx)(x), "right_join(x, y, by = 'k', multiple = 'first')"),
            ("full_last", () -> full_join(y; by = :i, multiple = :last, suffix = sfx)(x), "full_join(x, y, by = 'i', multiple = 'last')"),
            ("inner_any", () -> inner_join(y; by = :i, multiple = :any, suffix = sfx)(x), "inner_join(x, y, by = 'i', multiple = 'any')"),
            # empty inputs
            ("inner_empty_x", () -> inner_join(y; by = :k, suffix = sfx)(x0), "inner_join(x0, y, by = 'k')"),
            ("full_empty_x", () -> full_join(y; by = :k, suffix = sfx)(x0), "full_join(x0, y, by = 'k')"),
            ("left_empty_y", () -> left_join(y0; by = :k, suffix = sfx)(x), "left_join(x, y0, by = 'k')"),
            ("anti_empty_y", () -> anti_join(y0; by = :k)(x), "anti_join(x, y0, by = 'k')"),
            # grouped x keeps its groups
            ("left_grouped", () -> left_join(y; by = :k, suffix = sfx)(group_by(:i)(x)), "left_join(group_by(x, i), y, by = 'k')"),
            # nest_join: nested sizes, the unnested rows, keep, na_matches, a name clash
            ("nest_sizes", () -> sizes(nest_join(y; by = :k)(x), :y), "nest_join(x, y, by = 'k') |> mutate(n = vapply(y, nrow, integer(1))) |> select(v, n)"),
            ("nest_unnest", () -> (nest_join(y; by = :k, name = :m) ⨟ unnest(:m; keep_empty = true, names_sep = "_"))(x), "nest_join(x, y, by = 'k', name = 'm') |> tidyr::unnest(m, keep_empty = TRUE, names_sep = '_')"),
            ("nest_keep", () -> (nest_join(y; by = :i, keep = true, name = :m) ⨟ unnest(:m; keep_empty = true, names_sep = "_"))(x), "nest_join(x, y, by = 'i', keep = TRUE, name = 'm') |> tidyr::unnest(m, keep_empty = TRUE, names_sep = '_')"),
            ("nest_never", () -> sizes(nest_join(y; by = :k, na_matches = :never)(x), :y), "nest_join(x, y, by = 'k', na_matches = 'never') |> mutate(n = vapply(y, nrow, integer(1))) |> select(v, n)"),
            ("nest_clash", () -> (b = Base.CoreLogging.with_logger(() -> nest_join(y; by = :k)(xc), Base.CoreLogging.NullLogger()); (names = string.(b.names), n = Any[[nrow(f) for f in Tables.getcolumn(b, :y)]; fill(missing, length(b.names) - b.nrow)])), "{r <- nest_join(xc, y, by = 'k'); tibble::tibble(names = names(r), n = c(vapply(r\$y, nrow, integer(1)), rep(NA, length(names(r)) - nrow(r))))}"),
            # cross_join
            ("cross", () -> cross_join(y; suffix = sfx)(x), "cross_join(x, y)"),
            ("cross_empty", () -> cross_join(y0; suffix = sfx)(x), "cross_join(x, y0)"),
            # ★ K4: integer against double keys, compared as double
            ("k4_inner", () -> inner_join(yd; by = :k)(xi), "inner_join(xi, yd, by = 'k')"),
            ("k4_full", () -> full_join(yd; by = :k)(xi), "full_join(xi, yd, by = 'k')"),
            ("k4_keep", () -> left_join(yd; by = :k, keep = true, suffix = sfx)(xi), "left_join(xi, yd, by = 'k', keep = TRUE)"),
            ("k4_reverse", () -> inner_join(xi; by = :k, suffix = sfx)(yd), "inner_join(yd, xi, by = 'k')"),
        ]
        # error cases: (name, Julia thunk, R expression); compared by the first line of dplyr's message
        errcases = [
            ("err_x_unmatched", () -> inner_join(Frame(k = [1, 1]); by = :k, unmatched = :error, multiple = :error)(Frame(k = [2, 1])), "inner_join(tibble::tibble(k = c(2, 1)), tibble::tibble(k = c(1, 1)), by = 'k', unmatched = 'error', multiple = 'error')"),
            ("err_multiple", () -> inner_join(Frame(k = [1, 1]); by = :k, unmatched = :error, multiple = :error)(Frame(k = [1, 2])), "inner_join(tibble::tibble(k = c(1, 2)), tibble::tibble(k = c(1, 1)), by = 'k', unmatched = 'error', multiple = 'error')"),
            ("err_y_unmatched", () -> left_join(Frame(k = [1, 3]); by = :k, unmatched = :error)(Frame(k = [1])), "left_join(tibble::tibble(k = 1), tibble::tibble(k = c(1, 3)), by = 'k', unmatched = 'error')"),
            ("err_right", () -> right_join(Frame(k = [1]); by = :k, unmatched = :error)(Frame(k = [1, 2])), "right_join(tibble::tibble(k = c(1, 2)), tibble::tibble(k = 1), by = 'k', unmatched = 'error')"),
            ("err_n3", () -> left_join(Frame(k = [1, 1]); by = :k, multiple = :first, unmatched = :error)(Frame(k = [1])), "left_join(tibble::tibble(k = 1), tibble::tibble(k = c(1, 1)), by = 'k', multiple = 'first', unmatched = 'error')"),
            ("err_nest", () -> nest_join(Frame(k = Union{Missing, Int}[1, missing]); by = :k, na_matches = :never, unmatched = :error)(Frame(k = Union{Missing, Int}[1, missing])), "nest_join(tibble::tibble(k = c(1L, NA)), tibble::tibble(k = c(1L, NA)), by = 'k', na_matches = 'never', unmatched = 'error')"),
        ]

        rcode = """
            suppressPackageStartupMessages({ library(dplyr); library(tidyr) })
            stopifnot(packageVersion("dplyr") == "1.2.0", packageVersion("tidyr") == "1.3.1")
            fmt <- function(v) {
              if (is.logical(v)) return(ifelse(is.na(v), "NA", ifelse(v, "TRUE", "FALSE")))
              if (is.numeric(v)) { v <- as.double(v); return(ifelse(is.nan(v), "NaN", ifelse(is.na(v), "NA", sprintf("%.17g", v)))) }
              ifelse(is.na(v), "NA", as.character(v))
            }
            emit <- function(name, r) {
              cat("CASE\\t", name, "\\t", nrow(r), "\\t", paste(group_vars(r), collapse = ","), "\\n", sep = "")
              for (nm in names(r)) cat("COL\\t", nm, "\\t", paste(fmt(r[[nm]]), collapse = "|"), "\\n", sep = "")
            }
            emiterr <- function(name, expr) {
              msg <- tryCatch({ force(expr); "NO ERROR" }, error = function(e) conditionMessage(e))
              lines <- strsplit(gsub("\\033\\\\[[0-9;]*m", "", msg), "\\n")[[1]]
              cat("ERR\\t", name, "\\t", paste(lines, collapse = "\\r"), "\\n", sep = "")
            }
            $rdata
            """ * join(["emit($(repr(nm)), $(rx))" for (nm, _, rx) in cases], "\n") * "\n" *
            join(["emiterr($(repr(nm)), $(rx))" for (nm, _, rx) in errcases], "\n")
        dir = mktempdir()
        rfile = joinpath(dir, "cases.R")
        write(rfile, rcode)
        out = read(`$rscript --vanilla $rfile`, String)

        parseval(s) = s == "NA" ? missing : s == "NaN" ? NaN : s == "TRUE" ? true : s == "FALSE" ? false :
            (x = tryparse(Float64, s); x === nothing ? s : x)
        rres = Dict{String, Any}()
        rerr = Dict{String, String}()
        cur = ""
        for line in split(out, '\n'; keepempty = false)
            f = split(line, '\t')
            if f[1] == "CASE"
                cur = String(f[2])
                rres[cur] = (n = parse(Int, f[3]), groups = filter(!isempty, split(f[4], ',')), cols = Pair{String, Vector{Any}}[])
            elseif f[1] == "COL"
                vals = length(f) < 3 || isempty(f[3]) ? Any[] : Any[parseval(String(s)) for s in split(f[3], '|')]
                push!(rres[cur].cols, String(f[2]) => vals)
            elseif f[1] == "ERR"
                rerr[String(f[2])] = String(f[3])
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
            okn || @info "differential mismatch (names)" case = nm julia = first.(jcols) dplyr = first.(r.cols)
            @test okn
            okall = okn
            for ((jk, jv), (rk, rv)) in zip(jcols, r.cols)
                ok = length(jv) == length(rv) && all(same(a, b) for (a, b) in zip(jv, rv))
                ok || @info "differential mismatch" case = nm column = jk julia = jv dplyr = rv
                @test ok
                okall &= ok
            end
            okg = string.(groupcols(jl)) == r.groups
            okg || @info "differential mismatch (groups)" case = nm julia = groupcols(jl) dplyr = r.groups
            @test okg
            return okall && okg
        end
        passed = 0
        for (nm, thunk, _) in cases
            @test haskey(rres, nm)
            haskey(rres, nm) || continue
            jl = thunk()
            jl isa Frame || (jl = Frame(jl))
            passed += compare(nm, jl, rres[nm])
        end
        for (nm, thunk, _) in errcases
            @test haskey(rerr, nm)
            haskey(rerr, nm) || continue
            jmsg = try
                thunk()
                "NO ERROR"
            catch e
                e isa ArgumentError ? e.msg : sprint(showerror, e)
            end
            rlines = [strip(replace(l, r"^[!✖ℹ•]\s*" => "")) for l in split(rerr[nm], '\r')]
            ok = all(l -> isempty(l) || occursin(l, jmsg), rlines)
            ok || @info "differential mismatch (error)" case = nm julia = jmsg dplyr = rlines
            @test ok
            passed += ok
        end
        @info "differential: $(passed)/$(length(cases) + length(errcases)) join cases agree with dplyr 1.2.0"
        return nothing
    end
    run_differential()
end
