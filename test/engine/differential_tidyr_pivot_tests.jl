# Differential tests of the pivots, separate_* and unite against tidyr 1.3.1 through `Rscript`
# (tag :differential, excluded from the default run: `julia scripts/ci.jl test -- differential`).
# Each case runs one R expression and the Julia pipeline it mirrors on the same fixed data
# (with missing values, empty strings and empty results). Documented divergences are encoded as
# expected differences, each with its reason, so a change on either side is caught.

@testitem "differential: tidyr pivot" tags = [:differential] begin
    using Tables
    const ⨟ = ChuiFrames.Upstream.:⨟

    function run_differential()
        rscript = Sys.which("Rscript")
        if rscript === nothing
            @info "differential: Rscript not found on PATH; skipping the tidyr comparison"
            @test_skip false
            return
        end

        # ---- fixed data (Julia values; the R tibbles are generated from them) --------------------
        S = Union{Missing, String}
        F = Union{Missing, Float64}
        I = Union{Missing, Int}
        data = Dict{String, Any}(
            "w" => (id = [1, 2, 3, 4], x_1 = F[1.5, missing, 3.0, -2.0], x_2 = F[4.0, 5.0, missing, missing], y = S["a", missing, "c", "d"]),
            "d2" => (id = [1, 2], a_1 = [1, 2], a_2 = [3, 4], b_1 = ["p", "q"]),
            "mix" => (id = [1], a = [1.0], b = ["x"]),
            "lg" => (id = I[2, 1, 2, 1, 3, missing], k = S["b", "a", "a", "c", "b", missing], v = F[1.0, 2.0, 3.0, missing, 5.0, 6.0], w = ["p", "q", "r", "s", "t", "u"]),
            "dd" => (id = [1, 1, 2], k = ["a", "a", "b"], v = [1, 2, 3]),
            "num" => (id = [1, 1], k = [2.5, 10.0], v = [1, 2]),
            "sp" => (id = [1, 2, 3, 4, 5, 6], x = S["a-b-c", "d-e", missing, "f-g-h-i", "", "j"]),
            "pos" => (id = [1, 2, 3, 4], x = S["abcde", "ab", missing, "abcdefg"]),
            "rx" => (id = [1, 2, 3, 4], x = S["x12-ab", "y3-c", missing, "nope"]),
            "ld" => (id = [1, 2, 3, 4], x = S["a,b", missing, "", "c,,d"], y = S["p,q", "r", "s", "t,u,v"]),
            "lp" => (id = [1, 2, 3, 4], x = ["abcde", "", "a", "abcd"]),
            "lpna" => (id = [1, 2], x = S["abc", missing]),
            "u" => (a = S["x", missing, "z"], b = I[1, 2, missing], c = S["p", "q", missing], dbl = F[1.0, 2.5, missing]),
        )
        rval(v::Missing) = "NA"
        rval(v::AbstractString) = repr(String(v))
        rval(v::Integer) = string(v, "L")
        rval(v::AbstractFloat) = isnan(v) ? "NaN" : repr(v)
        rcol(name, v) = "$name = " * (eltype(v) <: Union{Missing, AbstractString} && all(ismissing, v) ? "NA_character_" : "c($(join(rval.(v), ", ")))")
        rdata = join(["$k <- tibble::tibble($(join([rcol(n, collect(Tables.getcolumn(t, n))) for n in keys(t)], ", ")))" for (k, t) in data], "\n")

        # ---- cases: (name, data, Julia step, R expression on `.d`, kind) --------------------------
        # kind :exact; :both_error (both sides refuse the input); or a divergence key below
        cases = [
            # pivot_longer
            ("pl_basic", "w", pivot_longer(startswith("x")), "pivot_longer(.d, starts_with('x'))", :exact),
            ("pl_drop_na", "w", pivot_longer(r"^x"; values_drop_na = true), "pivot_longer(.d, starts_with('x'), values_drop_na = TRUE)", :exact),
            ("pl_sep", "w", pivot_longer(r"^x"; names_to = [:v, :n], names_sep = "_"), "pivot_longer(.d, starts_with('x'), names_to = c('v', 'n'), names_sep = '_')", :exact),
            ("pl_pattern", "w", pivot_longer(r"^x"; names_to = [:a, :b], names_pattern = r"(.)_(.)"), "pivot_longer(.d, starts_with('x'), names_to = c('a', 'b'), names_pattern = '(.)_(.)')", :exact),
            ("pl_prefix", "w", pivot_longer([:x_2, :x_1]; names_prefix = "x_", values_to = "val"), "pivot_longer(.d, c(x_2, x_1), names_prefix = 'x_', values_to = 'val')", :exact),
            ("pl_value", "w", pivot_longer(r"^x"; names_to = [".value", "n"], names_sep = "_"), "pivot_longer(.d, starts_with('x'), names_to = c('.value', 'n'), names_sep = '_')", :exact),
            ("pl_value_absent", "d2", pivot_longer(Not(:id); names_to = [".value", "k"], names_sep = "_"), "pivot_longer(.d, -id, names_to = c('.value', 'k'), names_sep = '_')", :exact),
            ("pl_empty", "w", filter(c.id .> 100) ⨟ pivot_longer(r"^x"), "dplyr::filter(.d, id > 100) |> pivot_longer(starts_with('x'))", :exact),
            ("pl_grouped", "w", group_by(:y) ⨟ pivot_longer(r"^x"), "dplyr::group_by(.d, y) |> pivot_longer(starts_with('x'))", :exact),
            ("pl_mixed_types", "mix", pivot_longer([:a, :b]), "pivot_longer(.d, c(a, b))", :mixed_types),
            # pivot_wider
            ("pw_basic", "lg", pivot_wider(names_from = :k, values_from = :v, id_cols = :id), "pivot_wider(.d, id_cols = id, names_from = k, values_from = v)", :exact),
            ("pw_default_ids", "lg", pivot_wider(names_from = :k, values_from = :v), "pivot_wider(.d, names_from = k, values_from = v)", :exact),
            ("pw_multi_values", "lg", pivot_wider(names_from = :k, values_from = [:v, :w], id_cols = :id, names_prefix = "P"), "pivot_wider(.d, id_cols = id, names_from = k, values_from = c(v, w), names_prefix = 'P')", :exact),
            ("pw_multi_names", "lg", pivot_wider(names_from = [:k, :w], values_from = :v, id_cols = :id, names_sep = "."), "pivot_wider(.d, id_cols = id, names_from = c(k, w), values_from = v, names_sep = '.')", :exact),
            ("pw_fill", "lg", pivot_wider(names_from = :k, values_from = [:v, :w], id_cols = :id, values_fill = (v = 0.0,)), "pivot_wider(.d, id_cols = id, names_from = k, values_from = c(v, w), values_fill = list(v = 0))", :exact),
            ("pw_sort", "lg", pivot_wider(names_from = :k, values_from = :v, id_cols = :id, names_sort = true), "pivot_wider(.d, id_cols = id, names_from = k, values_from = v, names_sort = TRUE)", :exact),
            ("pw_values_fn", "dd", pivot_wider(names_from = :k, values_from = :v, values_fn = sum, values_fill = 0), "pivot_wider(.d, names_from = k, values_from = v, values_fn = sum, values_fill = 0L)", :exact),
            ("pw_empty", "lg", filter(c.v .> 100) ⨟ pivot_wider(names_from = :k, values_from = :v, id_cols = :id), "dplyr::filter(.d, v > 100) |> pivot_wider(id_cols = id, names_from = k, values_from = v)", :exact),
            ("pw_grouped", "lg", group_by(:id) ⨟ pivot_wider(names_from = :k, values_from = :v, id_cols = :id), "dplyr::group_by(.d, id) |> pivot_wider(id_cols = id, names_from = k, values_from = v)", :exact),
            ("pw_duplicates", "dd", pivot_wider(names_from = :k, values_from = :v), "pivot_wider(.d, names_from = k, values_from = v)", :duplicates),
            ("pw_numeric_names", "num", pivot_wider(names_from = :k, values_from = :v), "pivot_wider(.d, names_from = k, values_from = v)", :numeric_names),
            # separate_wider_delim
            ("swd_start_drop", "sp", separate_wider_delim(:x, "-"; names = [:p, :q, :r], too_few = :align_start, too_many = :drop), "separate_wider_delim(.d, x, '-', names = c('p', 'q', 'r'), too_few = 'align_start', too_many = 'drop')", :exact),
            ("swd_end_merge", "sp", separate_wider_delim(:x, "-"; names = [:p, :q, :r], too_few = :align_end, too_many = :merge), "separate_wider_delim(.d, x, '-', names = c('p', 'q', 'r'), too_few = 'align_end', too_many = 'merge')", :exact),
            ("swd_skip_keep", "sp", separate_wider_delim(:x, "-"; names = [:p, nothing], too_few = :align_start, too_many = :drop, cols_remove = false), "separate_wider_delim(.d, x, '-', names = c('p', NA), too_few = 'align_start', too_many = 'drop', cols_remove = FALSE)", :exact),
            ("swd_names_sep", "sp", separate_wider_delim(:x, "-"; names_sep = "_", too_few = :align_start), "separate_wider_delim(.d, x, '-', names_sep = '_', too_few = 'align_start')", :exact),
            ("swd_error", "sp", separate_wider_delim(:x, "-"; names = [:p, :q]), "separate_wider_delim(.d, x, '-', names = c('p', 'q'))", :both_error),
            ("swd_empty", "sp", filter(c.id .> 100) ⨟ separate_wider_delim(:x, "-"; names = [:p, :q]), "dplyr::filter(.d, id > 100) |> separate_wider_delim(x, '-', names = c('p', 'q'))", :exact),
            ("swd_grouped", "sp", group_by(:id) ⨟ separate_wider_delim(:x, "-"; names = [:p, :q], too_few = :align_start, too_many = :merge), "dplyr::group_by(.d, id) |> separate_wider_delim(x, '-', names = c('p', 'q'), too_few = 'align_start', too_many = 'merge')", :exact),
            # separate_wider_position
            ("swp_start_drop", "pos", separate_wider_position(:x; widths = [:a => 2, nothing => 1, :b => 2], too_few = :align_start, too_many = :drop), "separate_wider_position(.d, x, widths = c(a = 2, 1, b = 2), too_few = 'align_start', too_many = 'drop')", :exact),
            ("swp_exact_keep", "pos", filter(c.id .== 1) ⨟ separate_wider_position(:x; widths = (a = 2, b = 3), cols_remove = false), "dplyr::filter(.d, id == 1) |> separate_wider_position(x, widths = c(a = 2, b = 3), cols_remove = FALSE)", :exact),
            ("swp_error", "pos", separate_wider_position(:x; widths = (a = 2, b = 3)), "separate_wider_position(.d, x, widths = c(a = 2, b = 3))", :both_error),
            ("swp_empty", "pos", filter(c.id .> 100) ⨟ separate_wider_position(:x; widths = (a = 2, b = 3)), "dplyr::filter(.d, id > 100) |> separate_wider_position(x, widths = c(a = 2, b = 3))", :exact),
            # separate_wider_regex
            ("swr_start", "rx", separate_wider_regex(:x; patterns = [:l => "[a-z]", :n => "[0-9]+", nothing => "-", :s => "[a-z]+"], too_few = :align_start), "separate_wider_regex(.d, x, patterns = c(l = '[a-z]', n = '[0-9]+', '-', s = '[a-z]+'), too_few = 'align_start')", :exact),
            ("swr_exact_keep", "rx", filter(c.id .<= 2) ⨟ separate_wider_regex(:x; patterns = (l = r"[a-z]", n = r"\d+", s = r"-[a-z]+"), cols_remove = false), "dplyr::filter(.d, id <= 2) |> separate_wider_regex(x, patterns = c(l = '[a-z]', n = '\\\\d+', s = '-[a-z]+'), cols_remove = FALSE)", :exact),
            ("swr_error", "rx", separate_wider_regex(:x; patterns = [:l => "[a-z]", :n => "[0-9]+"]), "separate_wider_regex(.d, x, patterns = c(l = '[a-z]', n = '[0-9]+'))", :both_error),
            ("swr_empty", "rx", filter(c.id .> 100) ⨟ separate_wider_regex(:x; patterns = [:l => "[a-z]"]), "dplyr::filter(.d, id > 100) |> separate_wider_regex(x, patterns = c(l = '[a-z]'))", :exact),
            # separate_longer_delim
            ("sld_basic", "ld", separate_longer_delim(:x, ","), "separate_longer_delim(.d, x, ',')", :exact),
            ("sld_regex", "ld", separate_longer_delim(:y, r",+"), "separate_longer_delim(.d, y, stringr::regex(',+'))", :exact),
            ("sld_grouped", "ld", group_by(:id) ⨟ separate_longer_delim(:x, ","), "dplyr::group_by(.d, id) |> separate_longer_delim(x, ',')", :exact),
            ("sld_empty", "ld", filter(c.id .> 100) ⨟ separate_longer_delim(:x, ","), "dplyr::filter(.d, id > 100) |> separate_longer_delim(x, ',')", :exact),
            # separate_longer_position
            ("slp_basic", "lp", separate_longer_position(:x, 2), "separate_longer_position(.d, x, 2)", :exact),
            ("slp_keep_empty", "lp", separate_longer_position(:x, 3; keep_empty = true), "separate_longer_position(.d, x, 3, keep_empty = TRUE)", :exact),
            ("slp_missing", "lpna", separate_longer_position(:x, 2), "separate_longer_position(.d, x, 2)", :longer_position_na),
            # unite
            ("unite_basic", "u", unite(:ab, :a, :b), "unite(.d, 'ab', a, b)", :exact),
            ("unite_na_rm", "u", unite(:ab, :a, :b, :c; na_rm = true), "unite(.d, 'ab', a, b, c, na.rm = TRUE)", :exact),
            ("unite_keep", "u", unite("bc", :b, :c; sep = "", remove = false), "unite(.d, 'bc', b, c, sep = '', remove = FALSE)", :exact),
            ("unite_order", "u", unite(:ca, :c, :a), "unite(.d, 'ca', c, a)", :exact),
            ("unite_grouped", "u", group_by(:c) ⨟ unite(:ab, :a, :b), "dplyr::group_by(.d, c) |> unite('ab', a, b)", :exact),
            ("unite_empty", "u", filter(c.b .> 100) ⨟ unite(:ab, :a, :b), "dplyr::filter(.d, b > 100) |> unite('ab', a, b)", :exact),
            ("unite_double", "u", unite(:ad, :a, :dbl), "unite(.d, 'ad', a, dbl)", :float_text),
        ]

        # Divergences: the reason, and what the Julia result must be given R's.
        divergences = Dict(
            :mixed_types => "tidyr errors on incompatible value types; ChuiFrames keeps both losslessly (ADR-0001 rule 12)",
            :duplicates => "tidyr warns and builds a list-column for duplicate cells; ChuiFrames raises an ArgumentError pointing to values_fn",
            :numeric_names => "numeric names_from values are written with Julia's `string` (10.0), R writes 10",
            :longer_position_na => "tidyr 1.3.1 errors on NA in separate_longer_position; ChuiFrames gives one missing row",
            :float_text => "unite writes non-strings with Julia's `string` (1.0), R writes 1",
        )

        # ---- run R once -------------------------------------------------------------------------
        rcode = """
            suppressPackageStartupMessages({library(tidyr); library(dplyr)})
            stopifnot(packageVersion("tidyr") == "1.3.1")
            fmt <- function(v) {
              if (is.list(v)) return(rep("<LIST>", length(v)))
              if (is.logical(v)) return(ifelse(is.na(v), "NA", ifelse(v, "TRUE", "FALSE")))
              if (is.numeric(v)) { v <- as.double(v); return(ifelse(is.nan(v), "NaN", ifelse(is.na(v), "NA", sprintf("%.17g", v)))) }
              ifelse(is.na(v), "<NA>", as.character(v))
            }
            kind <- function(v) if (is.list(v)) "list" else if (is.numeric(v)) "num" else if (is.logical(v)) "lgl" else "chr"
            emit <- function(name, f) {
              warned <- FALSE
              r <- tryCatch(withCallingHandlers(f(), warning = function(w) { warned <<- TRUE; invokeRestart("muffleWarning") }),
                            error = function(e) { cat("ERROR\\t", name, "\\n", sep = ""); NULL })
              if (is.null(r)) return(invisible())
              cat("CASE\\t", name, "\\t", nrow(r), "\\t", paste(group_vars(r), collapse = ","), "\\t", warned, "\\n", sep = "")
              for (nm in names(r)) cat("COL\\t", nm, "\\t", kind(r[[nm]]), "\\t", paste(fmt(r[[nm]]), collapse = "|"), "\\n", sep = "")
            }
            $rdata
            """ * join(["emit($(repr(nm)), function() { .d <- $d; $(rx) })" for (nm, d, _, rx, _) in cases], "\n")
        dir = mktempdir()
        rfile = joinpath(dir, "cases.R")
        write(rfile, rcode)
        out = read(`$rscript --vanilla $rfile`, String)

        # ---- parse R output -----------------------------------------------------------------------
        parsenum(s) = s == "NA" ? missing : s == "NaN" ? NaN : parse(Float64, s)
        parselgl(s) = s == "NA" ? missing : s == "TRUE"
        rres = Dict{String, Any}()
        rerr = Set{String}()
        cur = ""
        for line in split(out, '\n'; keepempty = false)
            fs = split(line, '\t')
            if fs[1] == "ERROR"
                push!(rerr, String(fs[2]))
            elseif fs[1] == "CASE"
                cur = String(fs[2])
                rres[cur] = (n = parse(Int, fs[3]), groups = String.(filter(!isempty, split(fs[4], ','))), warned = fs[5] == "TRUE", cols = Pair{String, Vector{Any}}[])
            elseif fs[1] == "COL"
                n = rres[cur].n
                raw = n == 0 ? String[] : String.(split(length(fs) < 4 ? "" : fs[4], '|'))
                k = fs[3]
                vals = k == "num" ? Any[parsenum(s) for s in raw] : k == "lgl" ? Any[parselgl(s) for s in raw] :
                    Any[s == "<NA>" ? missing : s for s in raw]
                push!(rres[cur].cols, String(fs[2]) => vals)
            end
        end

        same(a, b) = (ismissing(a) && ismissing(b)) || (
            !ismissing(a) && !ismissing(b) && (
                (a isa Number && b isa Number && isequal(Float64(a), Float64(b))) ||
                    (a isa AbstractString && b isa AbstractString && String(a) == String(b))
            )
        )
        # String(x): a StrView in a log message hits a StringViews `write` ambiguity on 1.13
        jcols(jl) = Pair{String, Vector{Any}}[string(k) => Any[x isa AbstractString ? String(x) : x for x in Tables.getcolumn(jl, k)] for k in Tables.columnnames(jl)]
        function compare(nm, jl, r)
            jc = jcols(jl)
            ok = [first(p) for p in jc] == [first(p) for p in r.cols]
            ok || @info "differential: column names differ" case = nm julia = first.(jc) tidyr = first.(r.cols)
            @test ok
            for ((jk, jv), (_, rv)) in zip(jc, r.cols)
                good = length(jv) == length(rv) && all(same(a, b) for (a, b) in zip(jv, rv))
                good || @info "differential mismatch" case = nm column = jk julia = jv tidyr = rv
                @test good
                ok &= good
            end
            @test string.(groupcols(jl)) == r.groups
            return ok
        end

        passed = 0
        for (nm, d, step, _, kind) in cases
            input = data[d]
            if kind === :exact
                @test haskey(rres, nm)
                haskey(rres, nm) || continue
                passed += compare(nm, step(input), rres[nm])
            elseif kind === :both_error
                @test nm in rerr
                @test_throws ArgumentError step(input)
                passed += 1
            elseif kind === :mixed_types
                @test nm in rerr                                    # tidyr refuses ...
                jl = step(input)                                    # ... ChuiFrames keeps both
                @test isequal(collect(Tables.getcolumn(jl, :value)), Any[1.0, "x"])
                passed += 1
            elseif kind === :duplicates
                @test haskey(rres, nm) && rres[nm].warned           # tidyr warns, makes a list-column
                @test any(p -> all(==("<LIST>"), last(p)), rres[nm].cols)
                @test_throws ArgumentError step(input)
                passed += 1
            elseif kind === :numeric_names
                r = rres[nm]
                @test first.(r.cols) == ["id", "2.5", "10"]
                jl = step(input)
                @test string.(Tables.columnnames(jl)) == ["id", "2.5", "10.0"]
                # the values agree once the names are aligned
                @test all(all(same(a, b) for (a, b) in zip(last(jp), last(rp))) for (jp, rp) in zip(jcols(jl), r.cols))
                passed += 1
            elseif kind === :longer_position_na
                @test nm in rerr
                jl = step(input)
                @test isequal(collect(Tables.getcolumn(jl, :id)), [1, 1, 2])
                @test isequal(collect(Tables.getcolumn(jl, :x)), ["ab", "c", missing])
                passed += 1
            elseif kind === :float_text
                r = rres[nm]
                rv = last(only(filter(p -> first(p) == "ad", r.cols)))
                @test isequal(rv, Any["x_1", "NA_2.5", "z_NA"])
                jl = step(input)
                @test isequal(collect(Tables.getcolumn(jl, :ad)), ["x_1.0", "NA_2.5", "z_NA"])
                # every other column agrees
                @test compare(nm, select(Not(:ad))(jl), (; r..., cols = filter(p -> first(p) != "ad", r.cols)))
                passed += 1
            else
                error("unknown kind $kind")
            end
        end
        ndiv = count(x -> x[5] in keys(divergences), cases)
        @info "differential: $(passed)/$(length(cases)) tidyr 1.3.1 cases agree ($(count(x -> x[5] === :both_error, cases)) both refuse; $ndiv encoded divergences)" divergences
        return nothing
    end
    run_differential()
end
