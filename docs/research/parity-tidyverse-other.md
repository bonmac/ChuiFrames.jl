# Parity matrices: readr, haven, stringr, lubridate, forcats, purrr, tibble

**Question.** For each export of these seven packages, what is the Julia equivalent (Base/stdlib
used elementwise, or a proposed ChuiFrames spelling), its status, phase and planned test?

- **Date:** 2026-10-20.
- **Versions:** readr 2.1.6, haven 2.5.5, stringr 1.6.0, lubridate 1.9.4, forcats 1.0.1,
  purrr 1.2.0, tibble 3.3.0 (R 4.4.2); Julia 1.13.2 and 1.10.12 (LTS).
- **Method:** `getNamespaceExports` per package (PR-01) and the Rd `lifecycle-*` badges (PR-01);
  proposed and Base names checked against the exports of Base, Core and 19 stdlibs on both Julia
  versions (PR-02); 45 Base/Dates/Unicode mappings run in Julia and compared with R where the
  semantics differ (PR-03 to PR-07).
- **Row granularity:** one row per export for stringr, forcats, haven and tibble; **family rows**
  (several exports in the first cell) for readr, lubridate and purrr. Every export appears in
  some row (checked by script, PR-08). Superseded/deprecated exports are grouped per package.
- **Status `base`** means "Julia Base or a stdlib already does it, applied elementwise with dots";
  ChuiFrames writes no code. CF-009 then **forbids** ChuiFrames from exporting its own binding of
  those names (`year`, `uppercase`, `replace`, …): the binding must be the stdlib's.
- **Package choices** (CSV reader, ReadStat wrapper, categorical type, time zones) are **not
  decided here**: "see dependency ADRs".

**Status counts** (rows):

| Package | Exports | Rows | prototype | planned | adapted | base | skip |
|---|---|---|---|---|---|---|---|
| readr | 115 | 22 | 0 | 12 | 0 | 5 | 5 |
| haven | 28 | 28 | 0 | 24 | 0 | 1 | 3 |
| stringr | 63 | 63 | 0 | 14 | 1 | 42 | 6 |
| lubridate | 162 | 25 | 0 | 8 | 1 | 12 | 4 |
| forcats | 39 | 39 | 0 | 34 | 0 | 4 | 1 |
| purrr | 184 | 21 | 0 | 1 | 0 | 15 | 5 |
| tibble | 45 | 34 | 1 | 20 | 0 | 5 | 8 |

(Counted by script, PR-08. The extra purrr-section row "rows over a frame" is not an R export
and is not counted.)

## Julia constraints found

1. **Name collisions with stdlibs** (PR-02): Dates exports `year month day hour minute second week
   today now Date DateTime Time` and the Period types; Base exports `uppercase lowercase titlecase
   uppercasefirst strip lstrip rstrip lpad rpad repeat chop chomp occursin contains startswith
   endswith split replace join length textwidth eachmatch match parse tryparse read write readlines
   floor ceil round reverse sort unique map reduce accumulate filter`; `view`, `show`, `display`,
   `summary`, `stack` are Base; `shuffle` is Random; `pmap` is Distributed; `clipboard` is
   InteractiveUtils; `isoyear` is a Dates export on 1.13.2 but **not** on 1.10.12.
   ChuiFrames must use these bindings, never redefine them.
2. **Argument order:** `str_detect(string, pattern)` ↔ `occursin(pattern, string)` (needle first)
   but `contains(string, pattern)` (haystack first, like stringr). Prefer `contains.` (PR-03).
3. **String indices are bytes:** `"é1"[1:2]` throws `StringIndexError` (PR-03). `str_sub` must use
   character-safe operations (`first`, `last`, `nextind`), so it is `planned`, not `base`.
4. **Interpolation is not elementwise:** `"x=$(v)"` prints the whole vector (PR-03), so
   `str_glue("x={x}")` becomes `string.("x=", c.x)`.
5. **Weekday numbering:** lubridate `wday()` is Sunday = 1 (2024-02-29 → 5); `Dates.dayofweek` is
   Monday = 1 (→ 4) (PR-05). Month arithmetic: R `ymd("2024-01-31") + months(1)` is `NA`, while
   Julia `Date(2024,1,31) + Month(1)` clamps to 2024-02-29, i.e. lubridate's `%m+%` (PR-05).
6. **Time zones:** the Dates stdlib has `TimeZone` with a single subtype, `UTC` (PR-05).
   `with_tz`/`force_tz` need a time-zone package (TimeZones.jl is the obvious candidate: see
   dependency ADRs).
7. **No categorical type in Base or the stdlibs** (PR-02: `levels`, `droplevels`, `categorical`
   are not exported anywhere): forcats needs the dictionary-encoded column type from the storage
   ADR (Arrow `DictEncoded` or CategoricalArrays.jl: see dependency ADRs).
8. **`missing` has no tags:** haven's `tagged_na()` (SPSS/Stata user-missing codes) has no Julia
   counterpart; it needs a value-label metadata design.

## readr (family rows)

| R function(s) | Julia equivalent | Status | Phase | Notes | Test |
|---|---|---|---|---|---|
| `read_csv` `read_csv2` `read_tsv` `read_delim` | `read_csv(path; col_types=, delim=, locale=)` → frame; `scan_csv` lazy | planned | 2 | Built-in CSV source (brief). Reader package: see dependency ADRs. | `differential:readr`, `lazy==eager` |
| `read_table` `read_fwf` `fwf_empty` `fwf_widths` `fwf_positions` `fwf_cols` | `read_fwf(path; widths=)` | planned | 6 | Fixed-width I/O extension. | `differential:readr` |
| `read_log` `read_builtin` `readr_example` | — | skip | — | Web logs, R datasets and examples: no frame value. | — |
| `read_csv_chunked` `read_csv2_chunked` `read_delim_chunked` `read_tsv_chunked` `read_lines_chunked` `read_lines_raw_chunked` `melt_csv_chunked` `melt_csv2_chunked` `melt_delim_chunked` `melt_tsv_chunked` `AccumulateCallback` `ChunkCallback` `DataFrameCallback` `ListCallback` `SideEffectChunkCallback` | lazy scan with partitions (`scan_csv` + verbs) | planned | 3 | Callbacks become partitions of the source interface (DESIGN §3.8). | `lazy==eager` |
| `read_lines` `read_lines_raw` `read_file` `read_file_raw` | `readlines(path)`, `read(path)`, `read(path, String)` | base | 2 | Base exports (PR-02). | `unit` |
| `write_lines` `write_file` | `write(io, s)`, `foreach(l -> println(io, l), v)` | base | 2 | Base. | `unit` |
| `write_csv` `write_csv2` `write_tsv` `write_delim` `write_excel_csv` `write_excel_csv2` | `write_csv(path, t; delim=, bom=false)` | planned | 2 | Excel variants add a UTF-8 BOM. | `differential:readr` |
| `format_csv` `format_csv2` `format_tsv` `format_delim` | `sprint(io -> write_csv(io, t))` | planned | 2 | Writer to an `IOBuffer`. | `unit` |
| `read_rds` `write_rds` | — | skip | — | R serialization format; Arrow IPC is the native format. | — |
| `cols` `cols_only` `cols_condense` `col_character` `col_date` `col_datetime` `col_double` `col_factor` `col_guess` `col_integer` `col_logical` `col_number` `col_skip` `col_time` `as.col_spec` | `col_types = (a = Int, b = String, c = Date)` | planned | 2 | Julia types replace `col_*` specs; `col_skip` → `select=`. | `unit` |
| `spec` `spec_csv` `spec_csv2` `spec_delim` `spec_table` `spec_tsv` | `schema(source)` | planned | 2 | Prototype source function `schema` (DESIGN §3.8). | `unit` |
| `parse_integer` `parse_double` `parse_logical` `parse_character` `parse_vector` | `parse.(Int, c.s)`, `tryparse.(Float64, c.s)` | base | 2 | Verified (PR-07); `tryparse` gives `nothing`, map to `missing`. | `differential:readr` |
| `parse_number` | `parse_number.(c.s)` | planned | 2 | Strips grouping marks/currency; no Base equivalent. | `differential:readr` |
| `parse_date` `parse_datetime` `parse_time` | `Date.(c.s, dateformat"y-m-d")` | base | 2 | Dates stdlib (PR-05). | `differential:readr` |
| `parse_factor` `parse_guess` `guess_parser` `type_convert` | `type_convert(t)` | planned | 2 | Type inference shared with the CSV reader. | `differential:readr` |
| `locale` `default_locale` `date_names` `date_names_lang` `date_names_langs` | `locale = (decimal_mark=',', ...)` | planned | 2 | Dates has `DateLocale` for month names. | `unit` |
| `problems` `stop_for_problems` | `problems(t)` | planned | 2 | Parse problems kept as frame metadata. | `unit` |
| `tokenize` `tokenizer_csv` `tokenizer_delim` `tokenizer_fwf` `tokenizer_line` `tokenizer_log` `tokenizer_tsv` `tokenizer_ws` `count_fields` `datasource` | — | skip | — | Reader internals. | — |
| `edition_get` `local_edition` `with_edition` `should_read_lazy` `should_show_types` `show_progress` `readr_threads` `output_column` | reader keywords (`threads=`, `progress=`) | planned | 2 | Options, not functions. | `unit` |
| `clipboard` | `InteractiveUtils.clipboard()` | base | — | stdlib export (PR-02). | — |
| `guess_encoding` | — | skip | — | Julia strings are UTF-8; transcoding is out of scope (UNVERIFIED need). | — |
| `melt_csv` `melt_csv2` `melt_delim` `melt_fwf` `melt_table` `melt_table2` `melt_tsv` `read_table2` | — | skip | — | skip: superseded/deprecated (meltr package; `read_table`). | — |

## haven (one row per export)

| R function | Julia equivalent | Status | Phase | Notes | Test |
|---|---|---|---|---|---|
| `read_dta` | `read_dta(path)` | planned | 6 | ReadStat-based extension; package: see dependency ADRs. | `differential:haven` |
| `read_stata` | alias of `read_dta` | planned | 6 |  | `unit` |
| `read_sav` | `read_sav(path; user_na=false)` | planned | 6 |  | `differential:haven` |
| `read_por` | `read_por(path)` | planned | 6 |  | `differential:haven` |
| `read_spss` | dispatch on extension | planned | 6 |  | `unit` |
| `read_sas` | `read_sas(path; catalog=)` | planned | 6 |  | `differential:haven` |
| `read_xpt` | `read_xpt(path)` | planned | 6 |  | `differential:haven` |
| `write_dta` | `write_dta(path, t)` | planned | 6 | Write support in the Julia wrapper is UNVERIFIED. | `differential:haven` (round trip) |
| `write_sav` | `write_sav(path, t)` | planned | 6 | As above. | `differential:haven` |
| `write_xpt` | `write_xpt(path, t)` | planned | 6 | As above. | `differential:haven` |
| `labelled` | `labelled(v, labels)` column type | planned | 6 | Value labels as column metadata (constraint 8). | `unit` |
| `labelled_spss` | `labelled(v, labels; na_values=, na_range=)` | planned | 6 |  | `unit` |
| `is.labelled` | `v isa Labelled` | base | 6 | Plain `isa` once the type exists. | `unit` |
| `as_factor` | `as_factor(c.x; levels=:default)` | planned | 6 | Labelled → categorical (forcats type). | `differential:haven` |
| `print_labels` | `show` method | planned | 6 | Printing. | `snapshot` |
| `zap_labels` | `zap_labels(c.x)` | planned | 6 |  | `unit` |
| `zap_label` | `zap_label(c.x)` | planned | 6 | Variable label (column metadata). | `unit` |
| `zap_formats` | `zap_formats(c.x)` | planned | 6 |  | `unit` |
| `zap_widths` | `zap_widths(c.x)` | planned | 6 |  | `unit` |
| `zap_missing` | `zap_missing(c.x)` | planned | 6 |  | `unit` |
| `zap_empty` | `ifelse.(c.s .== "", missing, c.s)` | planned | 6 | Base form works today; named helper for parity. | `unit` |
| `tagged_na` | — | planned | 6 | Constraint 8: design needed. | `unit` |
| `na_tag` | — | planned | 6 | As above. | `unit` |
| `is_tagged_na` | — | planned | 6 | As above. | `unit` |
| `format_tagged_na` | — | skip | — | Printing of R's NaN-payload trick; follows the tag design. | — |
| `print_tagged_na` | — | skip | — | As above. | — |
| `vec_arith.haven_labelled` | arithmetic on `Labelled` | planned | 6 | vctrs method; Julia uses dispatch. | `unit` |
| `write_sas` | — | skip | — | skip: deprecated in haven 2.5.5 (PR-01). | — |

## stringr (one row per export; all base rows use dots on `c.s`)

| R function | Julia equivalent | Status | Phase | Notes | Test |
|---|---|---|---|---|---|
| `str_detect` | `contains.(c.s, pat)` / `occursin.(pat, c.s)` | base | 6 | Constraint 2. Verified (PR-03). | `differential:stringr` |
| `str_starts` | `startswith.(c.s, pat)` | base | 6 | Verified. | `differential:stringr` |
| `str_ends` | `endswith.(c.s, pat)` | base | 6 |  | `differential:stringr` |
| `str_count` | `count.(pat, c.s)` | base | 6 | Verified `[0, 3, 0]` = R `0 3` (PR-03, PR-04). | `differential:stringr` |
| `str_length` | `length.(c.s)` | base | 6 | Code points in both: `"héllo"` → 5 (PR-03, PR-04). | `differential:stringr` |
| `str_width` | `textwidth.(c.s)` | base | 6 | Verified `textwidth("日本")` → 4. | `differential:stringr` |
| `str_to_upper` | `uppercase.(c.s)` | base | 6 | Verified. `locale` argument: not supported. | `differential:stringr` |
| `str_to_lower` | `lowercase.(c.s)` | base | 6 | Verified. | `differential:stringr` |
| `str_to_title` | `titlecase.(c.s)` | base | 6 | Verified. | `differential:stringr` |
| `str_to_sentence` | `uppercasefirst.(lowercase.(c.s))` | base | 6 | Verified `"Hello world"` both sides. | `differential:stringr` |
| `str_to_camel` | `str_to_camel.(c.s)` | planned | 6 | New in stringr 1.6.0. | `differential:stringr` |
| `str_to_snake` | `str_to_snake.(c.s)` | planned | 6 | New in 1.6.0. | `differential:stringr` |
| `str_to_kebab` | `str_to_kebab.(c.s)` | planned | 6 | New in 1.6.0. | `differential:stringr` |
| `str_trim` | `strip.(c.s)` / `lstrip.` / `rstrip.` | base | 6 | Verified; returns `SubString`. | `differential:stringr` |
| `str_squish` | `replace.(strip.(c.s), r"\s+" => " ")` | base | 6 | Verified. | `differential:stringr` |
| `str_pad` | `lpad.(c.s, n, '0')` / `rpad.` | base | 6 | Verified; `side = "both"` needs a helper. | `differential:stringr` |
| `str_trunc` | `str_trunc.(c.s, n)` | planned | 6 | `Base.truncate` is file truncation. | `differential:stringr` |
| `str_wrap` | `str_wrap.(c.s, width)` | planned | 6 | No Base text wrapper. | `differential:stringr` |
| `str_dup` | `repeat.(c.s, n)` | base | 6 | Verified. | `differential:stringr` |
| `str_c` | `string.(c.a, "-", c.b)` | base | 6 | Verified. R `NA` propagation vs Julia `missing` → test. | `differential:stringr` |
| `str_flatten` | `join(c.s, sep)` (whole-column plain call) | base | 6 | Verified. | `differential:stringr` |
| `str_flatten_comma` | `join(c.s, ", ", " and ")` | base | 6 | Verified (`"a, b and c"`); R default has no "and". | `differential:stringr` |
| `str_glue` | `string.("x=", c.x)` | adapted | 6 | Constraint 4. | `unit` |
| `str_glue_data` | as `str_glue` | base | 6 | Columns are already in scope via `c`. | `unit` |
| `str_sub` | `str_sub.(c.s, i, j)` | planned | 6 | Constraint 3; negative indices like R (`str_sub("banana",-3,-1)` = `"ana"`, PR-04). | `differential:stringr` |
| `str_sub_all` | `str_sub_all.(c.s, ranges)` | planned | 6 |  | `unit` |
| `str_sub<-` | `mutate(s = …)` | skip | — | R replacement function; values are rebuilt. | — |
| `str_replace` | `replace.(c.s, pat => rep; count=1)` | base | 6 | Verified. Backrefs: `s"\1"`. | `differential:stringr` |
| `str_replace_all` | `replace.(c.s, pat => rep)` | base | 6 | Verified. | `differential:stringr` |
| `str_remove` | `replace.(c.s, pat => ""; count=1)` | base | 6 |  | `differential:stringr` |
| `str_remove_all` | `replace.(c.s, pat => "")` | base | 6 |  | `differential:stringr` |
| `str_replace_na` | `coalesce.(c.s, "NA")` | base | 6 | Verified. | `differential:stringr` |
| `str_extract` | `str_extract.(c.s, re)`; Base `match(re, s)` | planned | 6 | `match` returns `nothing` on no match (PR-03); helper maps to `missing`. | `differential:stringr` |
| `str_extract_all` | `[m.match for m in eachmatch(re, s)]` | base | 6 | Verified; list column. | `differential:stringr` |
| `str_match` | `match(re, s).captures` | base | 6 | Verified; `nothing` handling as above. | `differential:stringr` |
| `str_match_all` | `[m.captures for m in eachmatch(re, s)]` | base | 6 |  | `differential:stringr` |
| `str_locate` | `findfirst.(pat, c.s)` | base | 6 | Verified (`3:4`); byte ranges, not char (constraint 3). | `differential:stringr` |
| `str_locate_all` | `findall.(pat, c.s)` | base | 6 | Verified. | `differential:stringr` |
| `str_split` | `split.(c.s, pat)` | base | 6 | Verified; list column. | `differential:stringr` |
| `str_split_1` | `split(s, pat)` | base | 6 |  | `unit` |
| `str_split_i` | `getindex.(split.(c.s, pat), i)` | base | 6 | Verified; R returns `NA` for short rows, Julia throws → helper. | `differential:stringr` |
| `str_split_fixed` | `separate_wider_delim` (tidyr) | planned | 6 | See parity-tidyr.md §4. | `differential:stringr` |
| `str_subset` | `filter(contains(pat), v)` | base | 6 | Verified. | `differential:stringr` |
| `str_which` | `findall(contains(pat), v)` | base | 6 | Verified (1-based, as R). | `differential:stringr` |
| `str_sort` | `sort(v)` | base | 6 | Verified; code-point order, not ICU locale. | `differential:stringr` |
| `str_order` | `sortperm(v)` | base | 6 | Verified. | `differential:stringr` |
| `str_rank` | `invperm(sortperm(v))` | base | 6 | Ties differ: test. | `differential:stringr` |
| `str_unique` | `unique(v)` | base | 6 | Verified. | `differential:stringr` |
| `str_equal` | `Unicode.normalize.(a) .== Unicode.normalize.(b)` | base | 6 | Verified NFC equality. | `unit` |
| `str_like` | `str_like.(c.s, "a%")` | planned | 6 | SQL LIKE; push-down candidate for SQL sources. | `differential:stringr` |
| `str_ilike` | `str_ilike.(c.s, "a%")` | planned | 6 | As above. | `differential:stringr` |
| `str_escape` | `str_escape(s)` | planned | 6 | No exported Base regex-escape (`escape_string` is C-style). | `unit` |
| `str_conv` | — | skip | — | Julia strings are UTF-8. | — |
| `str_view` | — | skip | — | Interactive HTML viewer. | — |
| `str_view_all` | — | skip | — | As above. | — |
| `word` | `word.(c.s, i)` | planned | 6 | `split(s)[i]` covers the simple case. | `differential:stringr` |
| `regex` | `Regex(p, "i")` / `r"…"i` | base | 6 |  | `unit` |
| `fixed` | a plain `String` pattern | base | 6 | Base treats `String` patterns literally. | `unit` |
| `coll` | — | skip | — | ICU collation: no stdlib. | — |
| `boundary` | — | planned | 6 | Word/sentence boundaries; `Unicode.graphemes` covers characters. | `unit` |
| `invert_match` | `invert_match(locs)` | base | 6 | Complement of ranges; a few lines of Base. | `unit` |
| `%>%` | `\|>` | base | — |  | — |
| `str_interp` | `string.(…)` | skip | — | skip: superseded by `str_glue`. | — |

## lubridate (family rows)

| R function(s) | Julia equivalent | Status | Phase | Notes | Test |
|---|---|---|---|---|---|
| `ymd` `ydm` `mdy` `myd` `dmy` `dym` `ym` `my` `yq` | `Date.(c.s, dateformat"y-m-d")` (fixed format); `ymd.(c.s)` (guessing) | planned | 6 | Base works for one known format (PR-05); R guesses separators. | `differential:lubridate` |
| `ymd_h` `ymd_hm` `ymd_hms` `ydm_h` `ydm_hm` `ydm_hms` `mdy_h` `mdy_hm` `mdy_hms` `dmy_h` `dmy_hm` `dmy_hms` `hm` `ms` `hms` | `DateTime.(c.s, dateformat"y-m-d H:M:S")`; named guessers | planned | 6 | As above. | `differential:lubridate` |
| `parse_date_time` `parse_date_time2` `guess_formats` | `parse_date_time.(c.s, orders)` | planned | 6 |  | `differential:lubridate` |
| `fast_strptime` | `DateTime.(c.s, DateFormat(fmt))` | base | 6 | Dates stdlib. | `differential:lubridate` |
| `year` `month` `day` `mday` `hour` `minute` `second` `week` `date` | `year.(c.d)` … `week.(c.d)`, `Date.(c.dt)` | base | 6 | Dates exports (PR-02); verified (PR-05). `week` = ISO week (R `week` differs: 1 + (yday-1)÷7). | `differential:lubridate` |
| `wday` `yday` `qday` `quarter` `leap_year` `days_in_month` `isoweek` `isoyear` | `dayofweek.` `dayofyear.` `dayofquarter.` `quarterofyear.` `isleapyear.` `daysinmonth.` `week.` `Dates.isoyear.` | base | 6 | Verified; `wday` numbering (constraint 5); `isoyear` exported only on 1.13. | `differential:lubridate` |
| `epiweek` `epiyear` `semester` `am` `pm` | `hour.(c.t) .< 12` for `am`; named helpers | planned | 6 | No stdlib `epiweek` (PR-05). | `differential:lubridate` |
| `year<-` `month<-` `day<-` `mday<-` `wday<-` `yday<-` `qday<-` `hour<-` `minute<-` `second<-` `week<-` `date<-` | rebuild with `Date(y, m, d)` in `mutate` | skip | — | R replacement functions. | — |
| `floor_date` `ceiling_date` `round_date` | `floor.(c.t, Month)`, `ceil.(…, Hour)`, `round.(…, Day)` | base | 6 | Verified; R `round_date(…, "day")` = Julia (`2024-03-01`, PR-05). | `differential:lubridate` |
| `rollback` `rollbackward` `rollforward` | `lastdayofmonth.(c.d .- Month(1))`, `firstdayofmonth.(c.d .+ Month(1))` | base | 6 | Verified (`2024-01-31`). | `differential:lubridate` |
| `%m+%` `%m-%` `add_with_rollback` | `c.d .+ Month(1)` | base | 6 | Julia clamps like `%m+%` (constraint 5). | `differential:lubridate` |
| `years` `weeks` `days` `hours` `minutes` `seconds` `milliseconds` `microseconds` `nanoseconds` `period` `as.period` `is.period` `period_to_seconds` `seconds_to_period` | `Year(1)`, `Month(1)`, …, `Dates.canonicalize` | base | 6 | Verified `canonicalize(Minute(130))` → `2 hours, 10 minutes`. | `differential:lubridate` |
| `picoseconds` `dpicoseconds` | — | skip | — | Dates resolution stops at `Nanosecond`. | — |
| `duration` `as.duration` `is.duration` `dyears` `dmonths` `dweeks` `ddays` `dhours` `dminutes` `dseconds` `dmilliseconds` `dmicroseconds` `dnanoseconds` `make_difftime` `as.difftime` `is.difftime` `time_length` | `Millisecond(Day(1))`; `Duration` type for `dyears`/`dmonths` | adapted | 6 | Fixed periods exist; lubridate `dyears(1)` = 365.25 days has no stdlib value. | `differential:lubridate` |
| `interval` `%--%` `as.interval` `is.interval` `int_start` `int_end` `int_start<-` `int_end<-` `int_length` `int_flip` `int_shift` `int_overlaps` `int_aligns` `int_standardize` `int_diff` `%within%` `intersect` `union` `setdiff` | `interval(a, b)` type; set ops as methods on it | planned | 6 | No stdlib interval. `intersect`/`union`/`setdiff` are Base names: methods on the owned interval type are legal (CF-009). | `differential:lubridate` |
| `with_tz` `force_tz` `force_tzs` `tz` `tz<-` `local_time` `dst` | time-zone package | planned | 6 | Constraint 6; see dependency ADRs. | `differential:lubridate` |
| `make_date` `make_datetime` `as_date` `as_datetime` `Date` `POSIXct` | `Date.(c.y, c.m, c.d)`, `DateTime(…)`, `Date(dt)` | base | 6 | Verified. | `differential:lubridate` |
| `now` `today` | `Dates.now()`, `Dates.today()` | base | 6 | Dates exports; `now(tz)` needs constraint 6. | `unit` |
| `origin` `NA_Date_` `NA_POSIXct_` | `unix2datetime(0)`, `missing` | base | 6 | Verified. | `unit` |
| `decimal_date` `date_decimal` | `decimal_date.(c.d)` | planned | 6 | No stdlib function (PR-05). | `differential:lubridate` |
| `stamp` `stamp_date` `stamp_time` `format_ISO8601` | `Dates.format.(c.d, "dd u yyyy")` | base | 6 | Verified. `stamp` infers format from an example: not supported. | `unit` |
| `pretty_dates` | — | skip | — | Axis labels; plotting package. | — |
| `is.Date` `is.POSIXct` `is.POSIXlt` `is.POSIXt` `is.instant` `is.timepoint` `is.timespan` | `x isa Date`, `x isa Dates.TimeType` | base | 6 |  | `unit` |
| `fit_to_timeline` `reclass_date` `reclass_timespan` `cyclic_encoding` | — | planned | 6 | `fit_to_timeline` follows time zones; `cyclic_encoding` (sin/cos features) is a few dotted calls. | `unit` |
| `Arith` `Compare` `show` | — | skip | — | S4 method-group internals. | — |

## forcats (one row per export; categorical type: see dependency ADRs, constraint 7)

| R function | Julia equivalent | Status | Phase | Notes | Test |
|---|---|---|---|---|---|
| `fct` | `categorical(v; levels=)` | planned | 6 |  | `differential:forcats` |
| `as_factor` | `categorical(v)` (levels in appearance order) | planned | 6 |  | `differential:forcats` |
| `fct_inorder` | `fct_inorder(c.f)` | planned | 6 |  | `differential:forcats` |
| `fct_infreq` | `fct_infreq(c.f)` | planned | 6 |  | `differential:forcats` |
| `fct_inseq` | `fct_inseq(c.f)` | planned | 6 |  | `differential:forcats` |
| `fct_relevel` | `fct_relevel(c.f, "b", "a")` | planned | 6 |  | `differential:forcats` |
| `fct_reorder` | `fct_reorder(c.f, c.x, median)` | planned | 6 |  | `differential:forcats` |
| `fct_reorder2` | `fct_reorder2(c.f, c.x, c.y)` | planned | 6 |  | `differential:forcats` |
| `first2` | `first2(x, y)` | planned | 6 | Helper for `fct_reorder2`. | `unit` |
| `last2` | `last2(x, y)` | planned | 6 | Helper for `fct_reorder2`. | `unit` |
| `fct_rev` | `fct_rev(c.f)` | planned | 6 | Base `reverse` reverses values, not levels. | `differential:forcats` |
| `fct_shift` | `fct_shift(c.f, n)` | planned | 6 |  | `differential:forcats` |
| `fct_shuffle` | `fct_shuffle(c.f; rng=)` | planned | 6 | `Random.shuffle` is a stdlib export: keep the `fct_` name. | `property` |
| `fct_recode` | `fct_recode(c.f, "new" => "old")` | planned | 6 | Pair direction to fix in the grammar ADR (R is `new = old`). | `differential:forcats` |
| `fct_relabel` | `fct_relabel(c.f, uppercase)` | planned | 6 |  | `differential:forcats` |
| `fct_collapse` | `fct_collapse(c.f, "ab" => ["a", "b"])` | planned | 6 |  | `differential:forcats` |
| `fct_other` | `fct_other(c.f; keep=)` | planned | 6 |  | `differential:forcats` |
| `fct_lump` | `fct_lump_n` etc. | planned | 6 | R recommends the specific `fct_lump_*` variants. | `differential:forcats` |
| `fct_lump_n` | `fct_lump_n(c.f, n)` | planned | 6 |  | `differential:forcats` |
| `fct_lump_prop` | `fct_lump_prop(c.f, p)` | planned | 6 |  | `differential:forcats` |
| `fct_lump_min` | `fct_lump_min(c.f, k)` | planned | 6 |  | `differential:forcats` |
| `fct_lump_lowfreq` | `fct_lump_lowfreq(c.f)` | planned | 6 |  | `differential:forcats` |
| `fct_anon` | `fct_anon(c.f)` | planned | 6 |  | `property` |
| `fct_drop` | `fct_drop(c.f)` | planned | 6 | Unused levels; also `group_trim`. | `differential:forcats` |
| `fct_expand` | `fct_expand(c.f, "z")` | planned | 6 |  | `differential:forcats` |
| `fct_na_value_to_level` | `fct_na_value_to_level(c.f)` | planned | 6 |  | `differential:forcats` |
| `fct_na_level_to_value` | `fct_na_level_to_value(c.f)` | planned | 6 |  | `differential:forcats` |
| `fct_c` | `vcat` on categorical vectors | planned | 6 | Level union semantics from the chosen type. | `differential:forcats` |
| `fct_unify` | `fct_unify(fs)` | planned | 6 |  | `unit` |
| `fct_cross` | `fct_cross(c.a, c.b; sep=":")` | planned | 6 |  | `differential:forcats` |
| `fct_count` | `count_by(:f)` | base | 6 | dplyr `count` row (adapted there). | `differential:forcats` |
| `fct_match` | `in.(c.f, Ref(["a", "b"]))` | base | 6 | Base `in` with `Ref`. | `unit` |
| `fct_unique` | `unique(c.f)` | base | 6 | Level order depends on the type. | `unit` |
| `lvls_reorder` | `lvls_reorder(c.f, idx)` | planned | 6 | Low-level. | `unit` |
| `lvls_revalue` | `lvls_revalue(c.f, new)` | planned | 6 |  | `unit` |
| `lvls_expand` | `lvls_expand(c.f, new)` | planned | 6 |  | `unit` |
| `lvls_union` | `lvls_union(fs)` | planned | 6 |  | `unit` |
| `%>%` | `\|>` | base | — |  | — |
| `fct_explicit_na` | `fct_na_value_to_level` | skip | — | skip: deprecated (PR-01). | — |

## purrr (family rows; mostly Base Julia)

| R function(s) | Julia equivalent | Status | Phase | Notes | Test |
|---|---|---|---|---|---|
| `map` `map_lgl` `map_int` `map_dbl` `map_chr` `map_vec` | `map(f, v)`; in a frame `f.(c.x)` | base | — | Element type is inferred; no typed variants needed. Verified (PR-06). | `unit` |
| `map2` `map2_lgl` `map2_int` `map2_dbl` `map2_chr` `map2_vec` `pmap` `pmap_lgl` `pmap_int` `pmap_dbl` `pmap_chr` `pmap_vec` | `map(f, x, y, …)`; `f.(c.x, c.y)` | base | — | Verified. Do not name it `pmap`: that is Distributed's parallel map (PR-02). | `unit` |
| `imap` `imap_lgl` `imap_int` `imap_dbl` `imap_chr` `imap_vec` `iwalk` | `map(f, eachindex(v), v)` | base | — | Verified; `map(f, pairs(v))` is an error (PR-06). | `unit` |
| `walk` `walk2` `pwalk` | `foreach(f, v…)` | base | — | Verified. | `unit` |
| `map_if` `map_at` `map_depth` `modify` `modify_if` `modify_at` `modify2` `modify_depth` `modify_tree` `imodify` `lmap` `lmap_at` `lmap_if` | comprehensions, `map!` | base | — | `[p(x) ? f(x) : x for x in v]`. | `unit` |
| `keep` `discard` `keep_at` `discard_at` `compact` | `filter(p, v)`, `filter(!p, v)`, `filter(!isnothing, v)` | base | — | Verified. | `unit` |
| `detect` `detect_index` `every` `some` `none` `has_element` `head_while` `tail_while` | `findfirst`, `all`, `any`, `in`, `Iterators.takewhile` | base | — | Verified. | `unit` |
| `reduce` `reduce2` `accumulate` `accumulate2` | `reduce`, `accumulate`, over `zip` for the `2` forms | base | — | Verified; Base exports. | `unit` |
| `compose` `partial` `negate` | `∘`, `Base.Fix1`/`Fix2` or closures, `!f` | base | — | Verified (`!iseven` is a `ComposedFunction`). | `unit` |
| `safely` `possibly` `quietly` `insistently` `slowly` `auto_browse` `rate_backoff` `rate_delay` `rate_reset` `rate_sleep` `is_rate` | `try`/`catch`, `retry(f; delays=)` | base | — | `retry` is a Base export (PR-06); effects may come from ChuiTypes. | `unit` |
| `pluck` `pluck_depth` `pluck_exists` `pluck<-` `chuck` `assign_in` `modify_in` | nested `getindex`, `get`, `haskey` | base | — | Verified. | `unit` |
| `list_c` `list_flatten` `list_simplify` `list_transpose` `list_assign` `list_modify` `list_merge` `set_names` `rep_along` `array_branch` `array_tree` `vec_depth` | `reduce(vcat, l)`, `Iterators.flatten`, `merge`, `NamedTuple`, `fill` | base | — | Verified for `vcat`/`flatten`/`fill`. | `unit` |
| `list_rbind` `list_cbind` | `bind_rows(frames…)`, `bind_cols(frames…)` | planned | 2 | Frame-level; parity-dplyr.md §6. | `differential:dplyr` |
| `exec` `as_mapper` `attr_getter` `done` `zap` `%\|\|%` | `f(args...)`, `something(x, y)` | base | — | Verified `something(nothing, 3)` → 3. | `unit` |
| `is_atomic` `is_bare_atomic` `is_bare_character` `is_bare_double` `is_bare_integer` `is_bare_list` `is_bare_logical` `is_bare_numeric` `is_bare_vector` `is_character` `is_double` `is_empty` `is_formula` `is_function` `is_integer` `is_list` `is_logical` `is_null` `is_scalar_atomic` `is_scalar_character` `is_scalar_double` `is_scalar_integer` `is_scalar_list` `is_scalar_logical` `is_scalar_vector` `is_vector` | `isa`, `isempty`, `isnothing` | base | — | rlang re-exports; R type tests. | — |
| `in_parallel` | `Threads.@spawn` / parallel engine | skip | — | Experimental in purrr 1.2.0; parallelism is the engine's job (phase 5). | — |
| `%>%` | `\|>` | base | — |  | — |
| `rows over a frame` (no R export) | `rows(t)` → NamedTuples | planned | 2 | Prototype has `rows(t)` (DESIGN §2); listed so `pmap(df, f)` users find it. | `unit` |
| `as_vector` `flatten` `flatten_chr` `flatten_dbl` `flatten_df` `flatten_dfc` `flatten_dfr` `flatten_int` `flatten_lgl` `simplify` `simplify_all` `transpose` | `list_*` functions | skip | — | skip: superseded (PR-01). | — |
| `map_df` `map_dfc` `map_dfr` `map2_df` `map2_dfc` `map2_dfr` `pmap_df` `pmap_dfc` `pmap_dfr` `imap_dfc` `imap_dfr` | `map` + `list_rbind` | skip | — | skip: superseded. | — |
| `cross` `cross2` `cross3` `cross_df` `invoke` `invoke_map` `invoke_map_chr` `invoke_map_dbl` `invoke_map_df` `invoke_map_dfc` `invoke_map_dfr` `invoke_map_int` `invoke_map_lgl` `invoke_map_raw` `lift` `lift_dl` `lift_dv` `lift_ld` `lift_lv` `lift_vd` `lift_vl` | `expand_grid`, `exec` | skip | — | skip: deprecated. | — |
| `flatten_raw` `imap_raw` `map_raw` `map2_raw` `pmap_raw` `list_along` `prepend` `rbernoulli` `rdunif` `rerun` `splice` `update_list` `when` | — | skip | — | skip: deprecated. | — |


## tibble (one row per export)

| R function | Julia equivalent | Status | Phase | Notes | Test |
|---|---|---|---|---|---|
| `tibble` | `Tbl(a = [1, 2], b = ["x", "y"])` | prototype | 2 | Constructor name PROVISIONAL. Scalars recycle (R recycles length 1 only). | `unit` |
| `tribble` | `tribble((:a, :b), 1, "x", 2, "y")` | planned | 2 | Proposal (row-wise literal). | `unit` |
| `tibble_row` | `tibble_row(a = 1)` | planned | 2 |  | `unit` |
| `as_tibble` | `Tbl(table)` (any Tables.jl source) | planned | 2 | CF-001. | `CF-001` |
| `as_tibble_row` | `Tbl([nt])` from a NamedTuple | planned | 2 |  | `unit` |
| `as_tibble_col` | `Tbl(value = v)` | planned | 2 |  | `unit` |
| `new_tibble` | inner constructor | skip | — | Extender API; Julia uses dispatch. | — |
| `validate_tibble` | constructor checks | skip | — | As above. | — |
| `is_tibble` | `t isa Tbl` | base | 2 |  | `unit` |
| `add_row` | `add_row(t; a = 1, before=)` | planned | 2 |  | `unit` |
| `add_case` | alias of `add_row` | planned | 2 |  | `unit` |
| `add_column` | `add_column(t; z = v, before=)` | planned | 2 | `mutate` + `relocate`. | `unit` |
| `enframe` | `enframe(v; name=:name, value=:value)` | planned | 2 |  | `unit` |
| `deframe` | `deframe(t)` → `Dict`/NamedTuple | planned | 2 |  | `unit` |
| `glimpse` | `glimpse(t)` | planned | 2 | Printing. | `snapshot` |
| `has_name` | `hasproperty(t, :x)` | base | 2 | Base. | `unit` |
| `has_rownames` | — | skip | — | Frames have no row names (tibble drops them too). | — |
| `remove_rownames` | — | skip | — | As above. | — |
| `column_to_rownames` | — | skip | — | As above. | — |
| `rownames_to_column` | — | skip | — | As above; Tables.jl inputs have none. | — |
| `rowid_to_column` | `mutate(rowid = row_number())` | planned | 2 | Via dplyr `row_number`. | `unit` |
| `lst` | NamedTuple | base | — |  | — |
| `frame_matrix` | `permutedims(reshape(...))` | base | — | Base matrix ops. | — |
| `char` | `set_char_opts` printing option | planned | 2 | Experimental; printing. | `snapshot` |
| `num` | `set_num_opts` printing option | planned | 2 | Experimental; significant-digit printing (brief). | `snapshot` |
| `set_char_opts` | column print options | planned | 2 | Experimental. | `snapshot` |
| `set_num_opts` | column print options | planned | 2 | Experimental. | `snapshot` |
| `obj_sum` | printing hook | planned | 2 |  | `snapshot` |
| `size_sum` | printing hook | planned | 2 |  | `snapshot` |
| `tbl_sum` | header line (`# A frame: 3 × 2`, groups) | planned | 2 | Group info in header (brief). | `snapshot` |
| `type_sum` | type labels under headers | planned | 2 |  | `snapshot` |
| `view` | — | skip | — | `view` is a Base export (array views): never shadow it. | — |
| `%>%` | `\|>` | base | — |  | — |
| `as_data_frame` `as.tibble` `data_frame` `data_frame_` `frame_data` `lst_` `tibble_` `trunc_mat` `is.tibble` `repair_names` `set_tidy_names` `tidy_names` | current names | skip | — | skip: deprecated/superseded (PR-01). | — |

## UNVERIFIED

- Whether the chosen ReadStat wrapper can **write** `.dta`/`.sav`/`.xpt` (haven `write_*` rows).
- Whether a regex-escape helper exists unexported in Base (only `escape_string` was checked).
- `str_rank` and `fct_*` tie and level-order semantics against R: no differential run yet.
- R `NA` propagation in `str_c` vs Julia `missing` in `string.`: not run.
- That `guess_encoding` users need transcoding (readr row).
- The `Duration` design for `dyears`/`dmonths`, intervals and tagged missing values: no design yet.

## Evidence

- **PR-01** `Rscript exports2.R` (in `<scratchpad>/r-parity/`) → `readr 2.1.6 115` (deprecated 1,
  superseded 7); `haven 2.5.5 28` (deprecated 1); `stringr 1.6.0 63` (superseded 1);
  `lubridate 1.9.4 162` (no badges; 3 S4 names without Rd alias: `Arith`, `Compare`, `show`);
  `forcats 1.0.1 39` (deprecated 1); `purrr 1.2.0 184` (deprecated 34, experimental 1,
  superseded 23); `tibble 3.3.0 45` (deprecated 8, experimental 5, soft-deprecated 1,
  superseded 3). Lists: `<scratchpad>/r-parity/<pkg>_exports.tsv`.
- **PR-02** `julia --startup-file=no collide.jl names.txt` and `names2.txt` on 1.13.2 and +lts
  1.10.12: hits as listed in constraint 1; `levels droplevels categorical relevel reorder` no hit;
  only version difference in this set: `isoyear` (Dates on 1.13.2, none on 1.10.12).
- **PR-03** `julia verify.jl` and `verify5.jl` (1.13.2), e.g. `occursin.(r"an", s)` →
  `Bool[0, 1, 0]`; `replace.(s, "a" => "A"; count = 1)` → `["Apple pie", "bAnana", " kiwi  "]`;
  `titlecase.(s)` → `["Apple Pie", "Banana", " Kiwi  "]`; `lpad.(["7"], 3, '0')` → `["007"]`;
  `join(["a","b","c"], ", ", " and ")` → `"a, b and c"`; `"é1"[1:2]` →
  `StringIndexError: invalid index [2]`; `"x=$([1,2])"` → `"x=[1, 2]"`; `match(r"z","a")` → `nothing`;
  `findfirst("na","banana")` → `3:4`.
- **PR-04** `Rscript` stringr 1.6.0: `str_length("héllo")` → `5`; `str_sub("banana",-3,-1)` → `ana`;
  `str_to_sentence("HELLO world")` → `Hello world`; `str_count(c("Apple pie","banana"), "a")` → `0 3`.
- **PR-05** `julia verify.jl` Dates part: `dayofweek(Date(2024,2,29))` → `4`;
  `quarterofyear` → `1`; `floor(dt, Month)` → `2024-02-01T00:00:00`; `round(dt, Day)` →
  `2024-03-01T00:00:00`; `Date(2024,1,31) + Month(1)` → `2024-02-29`;
  `Dates.canonicalize(CompoundPeriod(Minute(130)))` → `2 hours, 10 minutes`;
  `subtypes(Dates.TimeZone)` → `Any[UTC]`; `isdefined(Dates, :epiweek)` → `false`.
  `Rscript rsem.R` lubridate 1.9.4: `wday(ymd("2024-02-29"))` → `5`; `ymd("2024-01-31") + months(1)`
  → `NA`; `%m+%` → `2024-02-29`; `round_date(…13:45:10, "day")` → `2024-03-01`.
- **PR-06** `julia verify4.jl`: `filter(!iseven, 1:5)` → `[1, 3, 5]`; `map(+, [1,2], [10,20])` →
  `[11, 22]`; `map(identity, pairs([5]))` → `map is not defined on dictionaries`;
  `Base.isexported(Base, :retry)` → `true`; `something(nothing, 3)` → `3`.
- **PR-07** `julia verify4.jl`: `parse.(Int, ["1","2"])` → `[1, 2]`;
  `tryparse.(Float64, ["1.5","x"])` → `[1.5, nothing]`; `unix2datetime(0)` → `1970-01-01T00:00:00`.
- **PR-08** coverage: `uv run --python 3.13 python -I cover.py parity-tidyverse-other.md
  <pkg>_exports.tsv` for the seven packages → `missing: []` for each.

`<scratchpad>` = /private/tmp/claude-501/-Users-bonmac-personal-projects-julia-data-analysis-ChuiFrames-jl--worktrees-phase1-research/ec2d6965-575b-4df9-88c8-fd3cf43e61fc/scratchpad
