# Parity matrix: tidyr

**Question.** For every exported tidyr function, what is the proposed ChuiFrames spelling, its
status, the brief phase that delivers it, and the planned test? Which names does Julia force us to
change (CF-009)?

- **Date:** 2026-10-20.
- **Versions:** tidyr 1.3.1, tidyselect 1.2.1 (R 4.4.2); Julia 1.13.2 and 1.10.12 (LTS).
- **Method:** `getNamespaceExports("tidyr")` (70 names, PR-01); lifecycle from the first
  `lifecycle-*` badge in each Rd description (PR-01), cross-checked against the tidyr reference
  index via Context7 (PR-02); proposed names checked against Base, Core and 19 stdlibs on both
  Julia versions (PR-03); behaviours that matter for parity run in R and Julia (PR-04, PR-05).
- **Scope of rows:** every export that is not superseded or deprecated has its own row; the
  superseded/deprecated ones are grouped in the last table. Proposed spellings are proposals for
  the expression-grammar ADR (the verb set is PROVISIONAL in `chui-frames.md`).

**Status counts** (rows): prototype 2, planned 31, adapted 6, base 7, skip 5
(51 rows covering all 70 exports; 3 of the skip rows group 22 superseded/deprecated names).
Coverage checked by script (PR-06).

## Julia constraints found

1. **Base-exported names** among tidyr exports (PR-03): `fill` and `chop`, plus the re-exported
   `contains`/`startswith`-style helpers covered in parity-dplyr.md. No collision for `nest`,
   `unnest`, `pack`, `unpack`, `expand`, `complete`, `crossing`, `nesting`, `unite`, `uncount`,
   `hoist`, `separate_*`, `pivot_*`, `replace_na`, `drop_na`, `full_seq`.
2. **`fill`:** tidyr's `fill(data, x, .direction)` takes column names. `fill(:x)` (a `Symbol`) would
   be piracy on Base `fill`; CF-009 already names the fix: `fill(c.x; direction=:down)` takes an
   owned node. Note that Base's one-argument `fill(5)` returns a 0-dimensional array (PR-05);
   the node method only changes behaviour for node arguments.
3. **`chop`:** Base `chop(s)` drops the last character of a string (PR-05). `chop(c.x)` would be
   legal (owned node) but ambiguous with the elementwise string `chop.(c.s)` and with CF-004
   ("plain call = whole-column operation"). Proposal: a distinct name, `chop_cols(:x)`;
   `unchop` has no collision.
4. **Grid order:** `expand_grid(x = 1:2, y = c("a","b"))` varies the *first* argument slowest
   (`1a 1b 2a 2b`); Julia's `Iterators.product(1:2, ["a","b"])` varies the first fastest
   (`1a 2a 1b 2b`) (PR-04, PR-05). Implementations must not lean on `Iterators.product` order.
5. **Lazy pivots:** `pivot_wider`'s output columns depend on the data. A lazy plan must either
   scan the key column first or take a spec (`pivot_wider_spec`); the lazy-engine ADR decides.
6. **`stack` is a Base export** (Julia 1.9+, PR-05): do not use it as a reshaping verb name
   (pandas/data.table spelling); keep `pivot_longer`.

## 1. Pivoting

| R function | Julia equivalent (proposed ChuiFrames spelling) | Status | Phase | Notes | Test |
|---|---|---|---|---|---|
| `pivot_longer` | `pivot_longer(startswith("x"); names_to=:name, values_to=:value, names_sep=, names_pattern=, values_drop_na=false)` | planned | 2 | Not in prototype (DESIGN §6). | `differential:dplyr` (tidyr), `lazy==eager` |
| `pivot_wider` | `pivot_wider(; names_from=:k, values_from=:v, values_fill=, values_fn=)` | planned | 2 | R golden: `k=a,b; v=1,2` → one row `a=1 b=2` (PR-04). Lazy needs constraint 5. | `differential:dplyr` (tidyr) |
| `pivot_longer_spec` | `pivot_longer_spec(spec)` | planned | 2 | Spec is a frame, as in R. | `unit` |
| `pivot_wider_spec` | `pivot_wider_spec(spec)` | planned | 2 | Fixes the output schema; enables the lazy form. | `lazy==eager` |
| `build_longer_spec` | `build_longer_spec(t, cols; ...)` | planned | 2 |  | `differential:dplyr` (tidyr) |
| `build_wider_spec` | `build_wider_spec(t; names_from, values_from)` | planned | 2 |  | `differential:dplyr` (tidyr) |
| `check_pivot_spec` | `check_pivot_spec(spec)` | planned | 2 | Validation helper. | `unit` |

## 2. Rectangling (list columns)

| R function | Julia equivalent | Status | Phase | Notes | Test |
|---|---|---|---|---|---|
| `unnest_longer` | `unnest_longer(:x; values_to=, indices_to=)` | planned | 2 | Arrow list columns. | `differential:dplyr` (tidyr) |
| `unnest_wider` | `unnest_wider(:x; names_sep=)` | planned | 2 | NamedTuple/struct elements → columns. | `differential:dplyr` (tidyr) |
| `unnest_auto` | `unnest_auto(:x)` | planned | 2 | Picks longer or wider by inspecting elements. | `unit` |
| `hoist` | `hoist(:x, a = ["path", 1])` | planned | 2 | Path elements: keys or indices. | `unit` |

## 3. Nesting, chopping, packing

| R function | Julia equivalent | Status | Phase | Notes | Test |
|---|---|---|---|---|---|
| `nest` | `nest(data = [:a, :b])` | prototype | 2 | Prototype `nest`; grouped input nests per group. | `differential:dplyr` (tidyr) |
| `unnest` | `unnest(:data)` | prototype | 2 | Keep prototype bug 6 (empty table keeps keys) as a regression test. | `unit`, `lazy==eager` |
| `chop` | `chop_cols(:x)` | adapted | 2 | Base `chop` (constraint 3). | `differential:dplyr` (tidyr), `CF-009` |
| `unchop` | `unchop(:x; keep_empty=false)` | planned | 2 |  | `differential:dplyr` (tidyr) |
| `pack` | `pack(xy = [:x, :y])` | planned | 2 | Struct column (Arrow struct / NamedTuple elements). | `unit` |
| `unpack` | `unpack(:xy; names_sep=)` | planned | 2 |  | `unit` |

## 4. Character columns: splitting and combining

| R function | Julia equivalent | Status | Phase | Notes | Test |
|---|---|---|---|---|---|
| `separate_wider_delim` | `separate_wider_delim(:x, ","; names=[:a, :b], too_few=, too_many=)` | planned | 2 | Experimental in R. Base `split` does the per-string work (see parity-tidyverse-other.md). | `differential:dplyr` (tidyr) |
| `separate_wider_position` | `separate_wider_position(:x; widths = (a=2, b=3))` | planned | 2 | Experimental in R. | `differential:dplyr` (tidyr) |
| `separate_wider_regex` | `separate_wider_regex(:x; patterns = (a = r"\d+", b = r"\w+"))` | planned | 2 | Experimental; replaces `extract`. Julia `Regex` literals, no string escaping. | `differential:dplyr` (tidyr) |
| `separate_longer_delim` | `separate_longer_delim(:x, ",")` | planned | 2 | Experimental; replaces `separate_rows`. | `differential:dplyr` (tidyr) |
| `separate_longer_position` | `separate_longer_position(:x, width)` | planned | 2 | Experimental in R. | `differential:dplyr` (tidyr) |
| `unite` | `unite(:ab, :a, :b; sep="_", remove=true, na_rm=false)` | planned | 2 | Elementwise core is `string.(c.a, "_", c.b)` (base). | `differential:dplyr` (tidyr) |

## 5. Missing values

| R function | Julia equivalent | Status | Phase | Notes | Test |
|---|---|---|---|---|---|
| `fill` | `fill(c.x; direction=:down)` | adapted | 2 | Base name; owned node arg (constraint 2, CF-009 example). R golden on ungrouped `v = NA,3,NA` → `NA,3,3` (PR-04); grouped fill stays inside groups. | `differential:dplyr` (tidyr), `CF-009` |
| `replace_na` | `mutate(x = coalesce.(c.x, 0))` | base | 2 | Base `coalesce` (parity-dplyr.md PR-07). A frame-level `replace_na(x = 0)` convenience is optional. | `differential:dplyr` (tidyr) |
| `drop_na` | `drop_na(:x, :y)` / `filter(.!ismissing.(c.x))` | planned | 2 | Base form works today via dots. | `differential:dplyr` (tidyr) |
| `complete` | `complete(:a, :b; fill = (x = 0,))` | planned | 2 | Built on `expand` + left join (phase 4 join engine; eager version earlier). | `differential:dplyr` (tidyr) |
| `full_seq` | `full_seq(c.x, period)` | planned | 2 | Scan-style plain call returning a new length. | `unit` |

## 6. Grids and counts

| R function | Julia equivalent | Status | Phase | Notes | Test |
|---|---|---|---|---|---|
| `expand` | `expand(:a, :b)` / `expand(nesting(:a, :b), :c)` | planned | 2 |  | `differential:dplyr` (tidyr) |
| `expand_grid` | `expand_grid(x = 1:2, y = ["a", "b"])` | planned | 2 | Order: first argument slowest (constraint 4). | `differential:dplyr` (tidyr) |
| `crossing` | `crossing(x = ..., y = ...)` | planned | 2 | `expand_grid` + dedupe + sort. | `differential:dplyr` (tidyr) |
| `nesting` | `nesting(:a, :b)` | planned | 2 | Only combinations present in the data. | `differential:dplyr` (tidyr) |
| `uncount` | `uncount(c.n; id=nothing)` | planned | 2 | Weights column repeats rows. | `differential:dplyr` (tidyr) |

## 7. Re-exports and helpers

| R function | Julia equivalent | Status | Phase | Notes | Test |
|---|---|---|---|---|---|
| `%>%` | `\|>`, `⨟` | base | 2 | As parity-dplyr.md §10. | `CF-007` |
| `all_of` | `[:a, :b]` | base | 2 | As parity-dplyr.md §9. | `unit` |
| `any_of` | `any_of([:a, :z])` | planned | 2 | As parity-dplyr.md §9. | `unit` |
| `contains` | `contains("a")` | adapted | 2 | Base curried predicate interpreted by `select` (parity-dplyr.md constraint 3). | `unit` |
| `starts_with` | `startswith("x")` | adapted | 2 | As above. | `unit` |
| `ends_with` | `endswith("_y")` | adapted | 2 | As above. | `unit` |
| `matches` | `contains(r"re")` | adapted | 2 | As above. | `unit` |
| `everything` | `everything()` | planned | 2 | Shared with dplyr. | `unit` |
| `last_col` | `last_col()` | planned | 2 | Shared with dplyr. | `unit` |
| `num_range` | `Symbol.("x", 1:3)` | base | 2 | Base broadcast already builds the names. | `unit` |
| `one_of` | — | skip | — | Superseded in tidyselect 1.2.1 (parity-dplyr.md PR-02). | — |
| `tibble` | `Tbl(...)` | base | 2 | Same constructor as parity-dplyr.md §10 (prototype). | `unit` |
| `tribble` | `tribble(...)` | base | 2 | Same as dplyr row (planned there). | `unit` |
| `as_tibble` | `Tbl(table)` | base | 2 | Same as dplyr row (CF-001). | `CF-001` |
| `tidyr_legacy` | — | skip | — | R name-repair compatibility shim; no Julia equivalent needed. | — |

Note: the `base` rows for `tibble`/`tribble`/`as_tibble`/`%>%` mean "nothing tidyr-specific to
build": the function is delivered once, by the row in parity-dplyr.md.

## 8. Superseded and deprecated (grouped)

| R functions | Replacement in R | Status | Phase | Notes | Test |
|---|---|---|---|---|---|
| `gather` `spread` `separate` `extract` `separate_rows` `nest_legacy` `unnest_legacy` | `pivot_longer`, `pivot_wider`, `separate_wider_*`, `separate_wider_regex`, `separate_longer_delim`, `nest`/`unnest` | skip | — | skip: superseded (PR-02). | — |
| `complete_` `crossing_` `drop_na_` `expand_` `extract_` `fill_` `gather_` `nest_` `nesting_` `separate_` `separate_rows_` `spread_` `unite_` `unnest_` | the non-underscore verbs | skip | — | skip: deprecated (lazyeval SE variants). | — |
| `extract_numeric` | `readr::parse_number` | skip | — | skip: deprecated; its body prints "extract_numeric() is deprecated: please use readr::parse_number() instead" (PR-01). | — |

## UNVERIFIED

- That `chop_cols` is the best distinct name; it is a placeholder for the grammar ADR.
- The lazy strategy for `pivot_wider` (constraint 5): no design yet.
- Arrow struct/list column support for `pack`/`unnest_*`: depends on the storage ADR.

## Evidence

- **PR-01** `Rscript exports2.R` (in `<scratchpad>/r-parity/`) →
  `tidyr 1.3.1 70 stages: (none) 44, deprecated 14, experimental 5, superseded 7`; per-name list in
  `<scratchpad>/r-parity/tidyr_exports.tsv`. `extract_numeric` has no badge;
  `print(body(extract_numeric))` shows the deprecation `message(...)` quoted above.
- **PR-02** Context7 `/websites/tidyr_tidyverse`, "Package index > Superseded": `extract()`,
  `separate()`, `separate_rows()`, `spread()`, `gather()`, `nest_legacy()`, `unnest_legacy()`;
  `extract()` superseded by `separate_wider_regex()`, `separate_rows()` by `separate_longer_delim()`.
- **PR-03** `julia collide.jl names.txt` on 1.13.2 and 1.10.12: `fill` → `Base`, `chop` → `Base`;
  no hit for the other tidyr names listed in constraint 1; `stack` → `Base` (names2.txt run).
- **PR-04** `Rscript` (tidyr 1.3.1): `expand_grid(x=1:2, y=c("a","b"))` rows `1 a / 1 b / 2 a / 2 b`;
  `fill(tibble(g=c(1,1,2), v=c(NA,3,NA)), v, .direction="down")` → `v = NA 3 3`;
  `pivot_wider(tibble(k=c("a","b"), v=1:2), names_from=k, values_from=v)` → `a=1 b=2`.
- **PR-05** `julia` 1.13.2: `repr(fill(5))` → `fill(5)` (0-dim array);
  `collect(Iterators.product(1:2, ["a","b"]))[:]` → `[(1, "a"), (2, "a"), (1, "b"), (2, "b")]`;
  `chop("abc")` → `"ab"`; `Base.isexported(Base, :stack)` → `true`,
  `stack(iter; dims) @ Base abstractarray.jl:2874`.
- **PR-06** coverage: `uv run --python 3.13 python -I cover.py parity-tidyr.md tidyr_exports.tsv`
  → `tidyr_exports.tsv 70 missing: []` (counts as in the summary).

`<scratchpad>` = /private/tmp/claude-501/-Users-bonmac-personal-projects-julia-data-analysis-ChuiFrames-jl--worktrees-phase1-research/ec2d6965-575b-4df9-88c8-fd3cf43e61fc/scratchpad
