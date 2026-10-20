# Parity matrix: dplyr

**Question.** For every exported dplyr function, what is the proposed ChuiFrames spelling, its
status, the brief phase that delivers it, and the test that will check it? Which names does Julia
force us to change (CF-009: no collision with Base/stdlib exports, no piracy)?

- **Date:** 2026-10-20.
- **Versions:** dplyr 1.2.0, tidyselect 1.2.1, rlang 1.1.7 (R 4.4.2); Julia 1.13.2 and 1.10.12 (LTS).
- **Method:** `getNamespaceExports("dplyr")` (283 names, PR-01); lifecycle stage read from the
  first `lifecycle-*` badge in each Rd topic's description (PR-02), cross-checked with the dplyr
  1.2.0 NEWS via Context7 (PR-03); every proposed Julia name checked against the exports of Base,
  Core and 19 stdlibs on both Julia versions (PR-05); every "base" mapping run in Julia (PR-07).
- **Scope of rows:** every export that is not superseded, deprecated or defunct has its own row,
  except the 18 `db_*` and 8 `sql_*` dbplyr backend generics, which share one row each (identical
  treatment). Superseded/deprecated/defunct exports are grouped in the last table.
- **Proposed spellings are proposals.** Final names belong to the expression-grammar ADR and the
  verb-set item that `chui-frames.md` lists as PROVISIONAL.

**Status counts** (187 rows covering all 283 exports; a shared row counts once): prototype 16,
planned 90, adapted 16, base 13, skip 52. Of the skip rows, 9 are the grouped
superseded/deprecated/defunct rows covering 81 names (42 superseded, 6 deprecated, 33 defunct);
2 are the shared `db_*`/`sql_*` rows. Coverage checked by script (PR-10).

## Julia constraints found (all families)

1. **Base-exported names among dplyr verbs/helpers** (PR-05, identical on 1.13.2 and 1.10.12):
   `filter count first last coalesce union intersect setdiff symdiff collect contains`.
   `n`, `select`, `rename`, `tail`, `between`, `nth`, `desc`, `lag`, `lead`, `where` are **not**
   exported by Base or any stdlib (`Base.rename`, `Base.tail`, `Base.between` exist but are
   internal, PR-05/PR-08; `Base.Iterators.nth` exists on 1.13 only and is not a Base export).
2. **What CF-009 then forces:**
   - `filter(c.x .> 1)`, `first(c.x)`, `last(c.x)`, `collect(q)` are methods of the Base function
     on a ChuiFrames-owned argument (expression node, lazy frame): allowed, already in the prototype.
   - The dplyr **`count` verb** cannot be `count(c.g)`: that signature is already the Base
     `count` reduction on a node (prototype bug 4, `CountTrue`). Proposal: `count_by(:g)`.
   - **`first(3)`/`last(3)` for rows** take an `Int` (not owned): use `head(3)` / `slice_tail(3)`.
   - **Set operations** `union/intersect/setdiff/symdiff(a::Frame, b::Frame)` are legal
     methods (owned args). A one-argument step form `union(b)` would be legal too, but it reuses
     Base's one-argument `union(x)` ("unique elements of x") for a different meaning. Flag for
     the grammar ADR: keep the two-frame eager form; pick the step form there.
   - **`n()`** cannot be exported: CF-009 makes `c` the only single-letter export. Proposal
     `nrow()` (zero-argument node) or `length(c.x)` (prototype).
3. **tidyselect without macros** (PR-07): Base's curried string predicates already return
   functions: `startswith("x")`, `endswith("_id")`, `contains("a")`, `contains(r"^x\d")` are
   `Base.Fix2` values, and `in([:a, :b])` likewise. Proposal: `select` (an owned function) treats
   any `Function` argument as a column-name predicate, so no new exports are needed. Trap:
   `occursin("x3")` curries the *haystack*, not the needle, so `occursin(r"...")` is wrong here;
   use `contains(r"...")`. `where` is usable as a function name (PR-08: `where(x) = ...` parses and
   runs), so `where(Number)` (element type `<: Number`) is a valid proposal.
4. **NSE has no macro-free equivalent; plain values replace it:** `{{ x }}` → pass the node `c.x`
   (or a `Symbol`) as an ordinary argument; `.data$x` / `.data[[v]]` → `c.x` / `c[v]` (the indexing
   form is PROVISIONAL in `chui-frames.md`); `!!sym(v)` → `c[v]`; `.env$x` → the Julia variable `x`.
5. **Plain `==` is not overloaded on nodes (CF-005)**, so `join_by(a == b)` cannot be spelled
   `join_by(c.a == c.b)` (it returns a `Bool`). Proposal: key pairs `on = [:a => :b]`; inequality
   and rolling joins via dotted nodes on explicit sides (design in the joins ADR).
6. **Semantics differences to test, not spelling** (PR-09): R `NA` vs Julia `missing`/`NaN`;
   `near()` uses an absolute tolerance, `isapprox` a relative one; ranking ties.

## 1. Single-table row verbs

| R function | Julia equivalent (proposed ChuiFrames spelling) | Status | Phase | Notes | Test |
|---|---|---|---|---|---|
| `filter` | `filter(c.x .> 1, c.y .== "a")` | prototype | 2 | Base name; owned node argument (CF-009 OK). Several conditions are ANDed. | `differential:dplyr`, `lazy==eager` |
| `filter_out` | `filter_out(cond...)` | planned | 2 | New in dplyr 1.2.0 (PR-03); drops rows where cond is TRUE, keeps NA rows. | `differential:dplyr` (missing) |
| `arrange` | `arrange(c.x, desc(c.y); by_group=false)` | prototype | 2 | `.by_group`, `.locale` keywords planned. | `differential:dplyr`, `lazy==eager` |
| `distinct` | `distinct(:a, :b; keep_all=false)` | planned | 2 | Not in prototype (DESIGN §6). Does not reuse Base `unique`. | `differential:dplyr` |
| `slice` | `slice(1:3)` | planned | 2 | Range argument; negative R indices → `slice(Not(1:3))` (proposal). | `differential:dplyr` |
| `slice_head` | `head(n)`; `slice_head(n=, prop=)` | prototype | 2 | `head(n)` exists; `first(3)` impossible (Int arg, CF-009). | `lazy==eager` |
| `slice_tail` | `slice_tail(n=, prop=)` | planned | 2 | `Base.tail` is internal, so a `tail` export is legal, but keep dplyr's name. | `differential:dplyr` |
| `slice_min` | `slice_min(c.x; n=1, with_ties=true)` | planned | 2 |  | `differential:dplyr` |
| `slice_max` | `slice_max(c.x; n=1, with_ties=true)` | planned | 2 |  | `differential:dplyr` |
| `slice_sample` | `slice_sample(; n=, prop=, rng=)` | planned | 2 | Random stream differs from R: test properties, not values. | `property` |

## 2. Column verbs

| R function | Julia equivalent | Status | Phase | Notes | Test |
|---|---|---|---|---|---|
| `select` | `select(:a, :b, startswith("x"))` | prototype | 2 | Prototype takes Symbols; predicates/ranges are planned (constraint 3). | `differential:dplyr`, `lazy==eager` |
| `rename` | `rename(new = :old)` | planned | 2 | Keywords keep dplyr's `new = old` order. `Base.rename` is internal (file rename), not exported. | `differential:dplyr` |
| `rename_with` | `rename_with(uppercase, cols)` | planned | 2 | Function first, as in R. | `differential:dplyr` |
| `relocate` | `relocate(:x; before=:y, after=nothing)` | planned | 2 |  | `differential:dplyr` |
| `mutate` | `mutate(r = c.a ./ c.b)` | prototype | 2 | Keywords apply in order (DESIGN §3.3). `.by`, `.keep`, `.before` planned. | `differential:dplyr`, `lazy==eager` |
| `pull` | `pull(:x)` / `pull(c.x)` | planned | 2 | Returns the column vector. | `unit` |

## 3. Summaries and counts

| R function | Julia equivalent | Status | Phase | Notes | Test |
|---|---|---|---|---|---|
| `summarise` | `summarise(m = mean(c.x))` | prototype | 2 | Monoid aggregation (DESIGN §3.6). `.groups` keyword planned. | `differential:dplyr`, `lazy==eager` |
| `summarize` | `summarize` (alias) | planned | 2 | Same value as `summarise`. | `unit` |
| `reframe` | `reframe(q = quantile(c.x, [0.25, 0.75]))` | planned | 2 | Any number of rows per group. | `differential:dplyr` |
| `count` | `count_by(:g; wt=nothing, sort=false, name=:n)` | adapted | 2 | `count(c.g)` is the Base `count` reduction on a node already (constraint 2). | `differential:dplyr`, `CF-009` |
| `tally` | `tally(; wt=nothing, sort=false)` | planned | 2 | Not a Base name. | `differential:dplyr` |
| `add_count` | `add_count(:g)` | planned | 2 |  | `differential:dplyr` |
| `add_tally` | `add_tally()` | planned | 2 |  | `differential:dplyr` |

## 4. Grouping

| R function | Julia equivalent | Status | Phase | Notes | Test |
|---|---|---|---|---|---|
| `group_by` | `group_by(:g; add=false, drop=true)` | prototype | 2 | Fast typed/radix group-by is phase 4. | `differential:dplyr`, `lazy==eager` |
| `ungroup` | `ungroup()` | prototype | 2 |  | `unit` |
| `rowwise` | `rowwise(:id)` | planned | 2 | Equivalent to grouping by row; `c_across` pairs with it. | `differential:dplyr` |
| `group_data` | `group_data(t)` | planned | 4 | Keys plus row indices. | `unit` |
| `group_indices` | `group_indices(t)` | planned | 4 | Prototype has an internal `groupindices`. | `differential:dplyr` |
| `group_keys` | `group_keys(t)` | planned | 4 |  | `differential:dplyr` |
| `group_rows` | `group_rows(t)` | planned | 4 |  | `unit` |
| `group_size` | `group_size(t)` | planned | 4 |  | `differential:dplyr` |
| `group_vars` | `groupcols(t)` | adapted | 2 | `chui-frames.md` Definitions name the accessor `groupcols` (PROVISIONAL). | `unit` |
| `groups` | `groupcols(t)` | adapted | 2 | Same accessor; R returns symbols, so does Julia. | `unit` |
| `n_groups` | `n_groups(t)` | planned | 4 |  | `unit` |
| `group_map` | `group_map(f, t)` | planned | 4 | Experimental in R. `f(group_frame, key)`. | `unit` |
| `group_modify` | `group_modify(f, t)` | planned | 4 | Experimental in R. | `unit` |
| `group_walk` | `group_walk(f, t)` | planned | 4 | Experimental; returns `t` (like `foreach`). | `unit` |
| `group_nest` | `group_by(:g) ⨟ nest()` | prototype | 2 | Experimental in R; prototype `nest` on a grouped table. | `differential:dplyr` |
| `group_split` | `group_split(t)` | planned | 4 | Experimental in R. | `unit` |
| `group_trim` | `group_trim(t)` | planned | 6 | Needs the categorical type (forcats, phase 6). | `unit` |
| `nest_by` | `nest_by(:g)` | planned | 2 | Experimental in R. | `differential:dplyr` |
| `group_by_drop_default` | `drop` keyword default of `group_by` | skip | — | R internal default helper; the keyword covers it. | — |
| `group_by_prepare` | — | skip | — | Internal helper for backends. | — |
| `grouped_df` | grouped frame constructor | skip | — | Grouping lives in the frame (`groups` field, DESIGN §3.3); no separate class. | — |
| `new_grouped_df` | — | skip | — | S3 constructor for extenders; Julia uses dispatch on the frame type. | — |
| `validate_grouped_df` | — | skip | — | As above. | — |
| `is_grouped_df` | `isgrouped(t)` | planned | 2 | `!isempty(groupcols(t))`. | `unit` |
| `is.grouped_df` | `isgrouped(t)` | planned | 2 | Same as `is_grouped_df`. | `unit` |
| `new_rowwise_df` | — | skip | — | S3 constructor for extenders. | — |
| `validate_rowwise_df` | — | skip | — | As above. | — |
| `tbl_nongroup_vars` | `setdiff(propertynames(t), groupcols(t))` | base | 2 | Base `setdiff` on vectors of Symbols. | `unit` |

## 5. Context functions and column-wise operations

| R function | Julia equivalent | Status | Phase | Notes | Test |
|---|---|---|---|---|---|
| `n` | `nrow()` or `length(c.x)` | adapted | 2 | Single-letter export forbidden (CF-009: only `c`). `length(c.x)` works in the prototype. | `differential:dplyr`, `CF-009` |
| `cur_group` | `cur_group()` | planned | 4 | One-row frame of the current key. | `unit` |
| `cur_group_id` | `cur_group_id()` | planned | 4 |  | `differential:dplyr` |
| `cur_group_rows` | `cur_group_rows()` | planned | 4 |  | `unit` |
| `cur_column` | function `(x, name) -> …` inside `across` | adapted | 2 | No dynamic context; `across` passes the name when `f` takes two arguments (proposal). | `unit` |
| `pick` | `pick(:a, :b)` | planned | 2 | Node yielding a sub-frame. | `differential:dplyr` |
| `across` | `across(where(Number), mean; names="{col}_{fn}")` | planned | 2 | Not in prototype (DESIGN §6). Pairs `:a => f` and NamedTuples of functions. | `differential:dplyr`, `lazy==eager` |
| `c_across` | `c_across(startswith("x"))` | planned | 2 | Rowwise only. | `differential:dplyr` |
| `if_any` | `if_any(cols, pred)` | planned | 2 |  | `differential:dplyr` |
| `if_all` | `if_all(cols, pred)` | planned | 2 |  | `differential:dplyr` |
| `when_any` | `when_any(a, b, ...)` (= `a .\| b`) | planned | 2 | New in 1.2.0 (PR-03). `.\|` works today but needs parentheses (DESIGN §3.1). | `differential:dplyr` |
| `when_all` | `when_all(a, b, ...)` (= `a .& b`) | planned | 2 | New in 1.2.0. | `differential:dplyr` |

## 6. Two-table verbs

| R function | Julia equivalent | Status | Phase | Notes | Test |
|---|---|---|---|---|---|
| `inner_join` | `inner_join(y; on=:id)` | planned | 4 | Hash join; not in prototype. | `differential:dplyr`, `lazy==eager` |
| `left_join` | `left_join(y; on=[:a => :b])` | planned | 4 |  | `differential:dplyr`, `lazy==eager` |
| `right_join` | `right_join(y; on=)` | planned | 4 |  | `differential:dplyr` |
| `full_join` | `full_join(y; on=)` | planned | 4 |  | `differential:dplyr` |
| `semi_join` | `semi_join(y; on=)` | planned | 4 |  | `differential:dplyr` |
| `anti_join` | `anti_join(y; on=)` | planned | 4 |  | `differential:dplyr` |
| `nest_join` | `nest_join(y; on=, name=:y)` | planned | 4 |  | `differential:dplyr` |
| `cross_join` | `cross_join(y)` | planned | 4 |  | `differential:dplyr` |
| `join_by` | `join_by(:a => :b)`; inequality form TBD | adapted | 4 | `c.a == c.b` returns `Bool` (CF-005), so R's `a == b` form cannot be copied (constraint 5). | `differential:dplyr` |
| `common_by` | — | skip | — | Internal helper for backends. | — |
| `bind_rows` | `bind_rows(t1, t2; id=nothing)`; `vcat(t1, t2)` | planned | 2 | `vcat` method on owned frames is legal. | `differential:dplyr` |
| `bind_cols` | `bind_cols(t1, t2)`; `hcat` | planned | 2 |  | `differential:dplyr` |
| `rows_insert` | `rows_insert(y; by=:id)` | planned | 4 |  | `differential:dplyr` |
| `rows_append` | `rows_append(y)` | planned | 4 |  | `differential:dplyr` |
| `rows_update` | `rows_update(y; by=)` | planned | 4 |  | `differential:dplyr` |
| `rows_patch` | `rows_patch(y; by=)` | planned | 4 |  | `differential:dplyr` |
| `rows_upsert` | `rows_upsert(y; by=)` | planned | 4 |  | `differential:dplyr` |
| `rows_delete` | `rows_delete(y; by=)` | planned | 4 |  | `differential:dplyr` |
| `union` | `union(a, b)` (two frames) | adapted | 4 | Base name; legal on owned frames; step form for `⨟` decided in grammar ADR (constraint 2). | `differential:dplyr`, `CF-009` |
| `union_all` | `union_all(a, b)` / `vcat` | planned | 4 |  | `differential:dplyr` |
| `intersect` | `intersect(a, b)` | adapted | 4 | As `union`. | `differential:dplyr`, `CF-009` |
| `setdiff` | `setdiff(a, b)` | adapted | 4 | As `union`. | `differential:dplyr`, `CF-009` |
| `setequal` | `issetequal(a, b)` | adapted | 4 | Base spells it `issetequal` (exported, PR-08); method on owned frames. | `unit` |
| `symdiff` | `symdiff(a, b)` | adapted | 4 | As `union`. | `differential:dplyr`, `CF-009` |
| `auto_copy` | — | skip | — | Remote-source plumbing; sources are copied via the source/sink interface. | — |
| `same_src` | — | skip | — | As above. | — |

## 7. Vector helpers

| R function | Julia equivalent | Status | Phase | Notes | Test |
|---|---|---|---|---|---|
| `if_else` | `ifelse.(cond, a, b)` | base | 2 | Verified (PR-07). R's `missing=` argument: wrap with `coalesce.`. R is type-strict; Julia promotes. | `differential:dplyr` |
| `case_when` | `case_when(c.x .< 0 => "neg", true => "pos")` | planned | 2 | `Pair` of node and value; `=>` is not overloaded, so no CF-005 issue. | `differential:dplyr` |
| `replace_when` | `replace_when(c.x, cond => v, ...)` | planned | 2 | New in 1.2.0 (PR-03). | `differential:dplyr` |
| `recode_values` | `recode_values(c.x, "a" => 1, ...; default=, unmatched=)` | planned | 2 | New in 1.2.0; replaces `case_match`. `from`/`to` keywords too. | `differential:dplyr` |
| `replace_values` | `c.x \|> x -> replace(x, "a" => "b")` | base | 2 | Base `replace(v, old => new)` verified (`replace([1,missing], missing=>0)` → `[1, 0]`, PR-08). Named form `replace_values` optional. | `differential:dplyr` |
| `coalesce` | `coalesce.(c.x, 0)` | base | 2 | Base export; dotted use builds a node (PR-07). Test `NaN` (not replaced in either). | `differential:dplyr` (missing, NaN) |
| `consecutive_id` | `consecutive_id(c.x)` | planned | 2 | Scan-style plain call. | `differential:dplyr` |
| `cumall` | `accumulate(&, c.x)` | base | 2 | Verified on vectors (PR-07); prototype supports `accumulate` scans. NA semantics differ: test. | `differential:dplyr` (missing) |
| `cumany` | `accumulate(\|, c.x)` | base | 2 | As above. | `differential:dplyr` (missing) |
| `cummean` | `cummean(c.x)` | planned | 2 | `cumsum(x) ./ (1:n)` needs `n`; a named scan is clearer. R: `1 1.5 2` (PR-09). | `differential:dplyr` |
| `desc` | `desc(c.x)` | prototype | 2 | Regression test for prototype bug 3 (`desc(:sym)`). | `unit` |
| `first` | `first(c.x)` | prototype | 2 | Base name, owned node arg. `default`, `order_by`, `na_rm` keywords planned; `first(c.x, n)` not supported (DESIGN §6). | `differential:dplyr` |
| `last` | `last(c.x)` | prototype | 2 | As `first`. | `differential:dplyr` |
| `nth` | `nth(c.x, k)` | planned | 2 | Not a Base export; `Base.Iterators.nth` exists on 1.13 only (PR-08). | `differential:dplyr` |
| `lag` | `lag(c.x, 1; default=missing)` | planned | 2 | Scan-style plain call, like `cumsum` in the prototype. | `differential:dplyr`, `lazy==eager` |
| `lead` | `lead(c.x, 1; default=missing)` | planned | 2 |  | `differential:dplyr` |
| `n_distinct` | `n_distinct(c.x)`; `c.x \|> x -> length(unique(x))` | planned | 2 | Both count `NA`/`missing` as a value: R 3, Julia 3 on `(1,1,2,NA)` (PR-07, PR-09). | `differential:dplyr` |
| `na_if` | `na_if.(c.x, v)` | planned | 2 | Scalar function used with dots. | `differential:dplyr` |
| `near` | `isapprox.(a, b; atol=sqrt(eps()))` | base | 2 | R `near` uses absolute tol `.Machine$double.eps^0.5`; Julia default is relative: pass `atol` (PR-07). | `differential:dplyr` |
| `between` | `between.(c.x, lo, hi)` or `lo .<= c.x .<= hi` | planned | 2 | `Base.between` is internal and `Integer`-only (PR-08); a ChuiFrames export is legal. | `differential:dplyr` |
| `order_by` | `arrange` then `mutate` | skip | — | Rarely used window-order helper; covered by verbs. | — |
| `with_order` | — | skip | — | As `order_by`. | — |

## 8. Ranking (window functions)

| R function | Julia equivalent | Status | Phase | Notes | Test |
|---|---|---|---|---|---|
| `row_number` | `row_number()` / `row_number(c.x)` | planned | 2 | R `min_rank(c(30,10,10,20))` = `4 1 1 3`, `dense_rank` = `3 1 1 2` (PR-09): golden values. | `differential:dplyr` |
| `min_rank` | `min_rank(c.x)` | planned | 2 | StatsBase has `competerank`; dependency not decided (see dependency ADRs). | `differential:dplyr` |
| `dense_rank` | `dense_rank(c.x)` | planned | 2 |  | `differential:dplyr` |
| `percent_rank` | `percent_rank(c.x)` | planned | 2 |  | `differential:dplyr` |
| `cume_dist` | `cume_dist(c.x)` | planned | 2 |  | `differential:dplyr` |
| `ntile` | `ntile(c.x, k)` | planned | 2 |  | `differential:dplyr` |

## 9. Selection helpers (tidyselect re-exports)

| R function | Julia equivalent (proposal) | Status | Phase | Notes | Test |
|---|---|---|---|---|---|
| `starts_with` | `startswith("x")` | adapted | 2 | Base curried `Fix2` predicate (PR-07); `select` applies it to names. | `differential:dplyr` |
| `ends_with` | `endswith("_id")` | adapted | 2 | As above. | `differential:dplyr` |
| `contains` | `contains("a")` | adapted | 2 | Base export; ChuiFrames adds no method, only interprets the predicate. | `differential:dplyr` |
| `matches` | `contains(r"^x\d")` | adapted | 2 | Not `occursin(r"…")`: that curries the haystack (PR-07). | `differential:dplyr` |
| `all_of` | `[:a, :b]` | base | 2 | Plain vector of Symbols; error when one is missing. | `unit` |
| `any_of` | `any_of([:a, :z])` | planned | 2 | Ignores absent names. | `unit` |
| `everything` | `everything()` | planned | 2 |  | `unit` |
| `last_col` | `last_col(offset=0)` | planned | 2 |  | `unit` |
| `num_range` | `num_range("x", 1:3)` / `Symbol.("x", 1:3)` | planned | 2 | Base form already works. | `unit` |
| `where` | `where(Number)` (element type `<: Number`) or `where(f)` | planned | 2 | `where` is legal as a function name (PR-08). | `differential:dplyr` |
| `group_cols` | `group_cols()` | planned | 2 | Selects the grouping columns (dplyr selection helper). | `unit` |
| `one_of` | — | skip | — | Superseded in tidyselect 1.2.1 by `any_of`/`all_of` (PR-02). | — |

## 10. Non-standard evaluation and re-exports from rlang, magrittr, tibble

| R function | Julia equivalent | Status | Phase | Notes | Test |
|---|---|---|---|---|---|
| `%>%` | `\|>` and `⨟` | base | 2 | `⨟` composes verbs as values (CF-007). | `CF-007` |
| `enquo` | pass `c.x` as an argument | skip | — | NSE capture: nodes are already values (constraint 4). | — |
| `enquos` | pass nodes as varargs | skip | — | As above. | — |
| `enexpr` | — | skip | — | As above. | — |
| `enexprs` | — | skip | — | As above. | — |
| `ensym` | pass a `Symbol` | skip | — | As above. | — |
| `ensyms` | pass `Symbol`s | skip | — | As above. | — |
| `expr` | build nodes directly, e.g. `c.x .+ 1` | skip | — | As above. | — |
| `quo` | — | skip | — | As above. | — |
| `quos` | — | skip | — | As above. | — |
| `quo_name` | node label | skip | — | Nodes carry a printable `label` (DESIGN §3.1). | — |
| `as_label` | node label | skip | — | As above. | — |
| `sym` | `Symbol("x")`; `c[v]` | base | 2 | `c[v]` is PROVISIONAL (`chui-frames.md`). | `unit` |
| `syms` | `Symbol.(v)` | base | 2 |  | `unit` |
| `tibble` | `Tbl(a = [1, 2])` (prototype constructor; name PROVISIONAL) | prototype | 2 | See parity-tidyverse-other.md (tibble). | `snapshot` |
| `tribble` | `tribble((:a, :b), 1, "x", 2, "y")` | planned | 2 | Proposal. | `unit` |
| `as_tibble` | `Tbl(table)` from any Tables.jl source | planned | 2 | CF-001. | `CF-001` |
| `lst` | NamedTuple | skip | — | `(a = 1, b = a + 1)` needs `let`; no frame semantics. | — |
| `add_row` | `add_row(t; a = 1)` | planned | 2 |  | `unit` |
| `glimpse` | `glimpse(t)` | planned | 2 | Printing family. | `snapshot` |
| `type_sum` | `type_sum(x)` (printing hook) | planned | 2 | Short type labels under headers. | `snapshot` |
| `data_frame` | — | skip | — | Deprecated in tibble 3.3.0 (PR-02). | — |
| `as_data_frame` | — | skip | — | Deprecated in tibble 3.3.0. | — |

## 11. Lazy, remote and backend API

| R function | Julia equivalent | Status | Phase | Notes | Test |
|---|---|---|---|---|---|
| `collect` | `collect(q)` | prototype | 3 | Base name; owned lazy-frame argument. | `lazy==eager` |
| `compute` | `compute(q)` | planned | 3 | Materialise but stay lazy (cache point). | `lazy==eager` |
| `collapse` | — | skip | — | Forces a SQL subquery in dbplyr; no meaning for our optimizer. | — |
| `explain` | `explain(q)` | prototype | 3 | Four-section plan print (DESIGN §3.9). | `snapshot` |
| `show_query` | `show_query(q)` (SQL backends) | planned | 6 | With the DBInterface extension. | `snapshot` |
| `copy_to` | `copy_to(db, t)` | planned | 6 | DBInterface extension. | `unit` |
| `tbl` | source constructors (`scan_parquet`, …) | adapted | 3 | Prototype has `scan_parquet`; names in the source/sink ADR. | `unit` |
| `src` | — | skip | — | dbplyr source object; replaced by the source/sink interface. | — |
| `src_tbls` | — | skip | — | As above. | — |
| `is.src` | — | skip | — | As above. | — |
| `is.tbl` | `t isa Tbl` | base | 2 | Plain `isa`. | — |
| `make_tbl` | — | skip | — | S3 class helper. | — |
| `ident` | — | skip | — | SQL identifier helper (dbplyr). | — |
| `sql` | — | skip | — | As above; SQL text input is a later extension (sqldf idea). | — |
| `sql_escape_ident` `sql_escape_string` `sql_join` `sql_select` `sql_semi_join` `sql_set_op` `sql_subquery` `sql_translate_env` | — | skip | — | dbplyr backend generics (one shared row). | — |
| `db_analyze` `db_begin` `db_commit` `db_create_index` `db_create_indexes` `db_create_table` `db_data_type` `db_desc` `db_drop_table` `db_explain` `db_has_table` `db_insert_into` `db_list_tables` `db_query_fields` `db_query_rows` `db_rollback` `db_save_query` `db_write_table` | — | skip | — | dbplyr backend generics (one shared row); DBInterface covers these. | — |
| `check_dbplyr` | — | skip | — | dbplyr version check. | — |
| `wrap_dbplyr_obj` | — | skip | — | dbplyr helper. | — |
| `tbl_ptype` | `schema(t)` | prototype | 3 | Prototype source function `schema(s)` (DESIGN §3.8). | `unit` |
| `tbl_vars` | `propertynames(t)` / `Tables.columnnames(t)` | base | 2 | CF-001 Tables.jl. | `CF-001` |
| `dim_desc` | printing header | planned | 2 | Part of tibble-style printing. | `snapshot` |
| `distinct_prepare` | — | skip | — | Internal helper. | — |
| `last_dplyr_warnings` | — | skip | — | Julia uses the logging system. | — |
| `dplyr_col_modify` | — | skip | — | Experimental S3 extension hook; Julia extends by dispatch. | — |
| `dplyr_reconstruct` | — | skip | — | As above. | — |
| `dplyr_row_slice` | — | skip | — | As above. | — |

## 12. Superseded, deprecated and defunct (grouped)

| R functions | Replacement in R | Status | Phase | Notes | Test |
|---|---|---|---|---|---|
| `filter_all` `filter_at` `filter_if` `mutate_all` `mutate_at` `mutate_if` `summarise_all` `summarise_at` `summarise_if` `summarize_all` `summarize_at` `summarize_if` `arrange_all` `arrange_at` `arrange_if` `group_by_all` `group_by_at` `group_by_if` `distinct_all` `distinct_at` `distinct_if` `select_all` `select_at` `select_if` `rename_all` `rename_at` `rename_if` `transmute_all` `transmute_at` `transmute_if` `all_vars` `any_vars` `vars` | `across`, `if_any`, `if_all` | skip | — | skip: superseded (scoped verbs). | — |
| `transmute` | `mutate(.keep = "none")` | skip | — | skip: superseded; `mutate(...; keep=:none)` planned. | — |
| `do` | `reframe`, `group_modify` | skip | — | skip: superseded. | — |
| `recode` `recode_factor` | `recode_values`, `case_when` | skip | — | skip: superseded. | — |
| `sample_n` `sample_frac` | `slice_sample` | skip | — | skip: superseded. | — |
| `top_n` `top_frac` | `slice_min`, `slice_max` | skip | — | skip: superseded. | — |
| `with_groups` | `.by` argument | skip | — | skip: superseded. | — |
| `case_match` `all_equal` `progress_estimated` `cur_data` `cur_data_all` `funs` | `recode_values`/`replace_values`, `all.equal`, `pick` | skip | — | skip: deprecated (`case_match` soft-deprecated in 1.2.0, PR-03). | — |
| `add_count_` `add_tally_` `arrange_` `count_` `distinct_` `do_` `filter_` `funs_` `group_by_` `group_indices_` `mutate_` `rename_` `select_` `slice_` `summarise_` `summarize_` `tally_` `transmute_` `mutate_each` `mutate_each_` `summarise_each` `summarise_each_` `summarize_each` `summarize_each_` `add_rownames` `as.tbl` `combine` `src_df` `src_local` `src_mysql` `src_postgres` `src_sqlite` `tbl_df` | modern verbs | skip | — | skip: defunct. | — |

## UNVERIFIED

- That `select` can accept `Base.Fix2` predicates without ambiguity against Symbol and range
  arguments: a design proposal, not built or run.
- The inequality/rolling form of `join_by`: no design exists yet.
- R `if_else` and `case_when` type-strictness versus Julia promotion: noted from dplyr docs
  knowledge, not run here.
- `coalesce` treatment of `NaN` in R vs Julia: to be checked by the differential test.
- That `cumall`/`cumany` NA semantics differ from `accumulate(&, …)` on `missing`: not run.

## Evidence

- **PR-01** exports: `Rscript exports2.R` in `<scratchpad>/r-parity/` →
  `dplyr 1.2.0 283 stages: (none) 192, defunct 33, deprecated 6, experimental 10, superseded 42`.
  List saved as `<scratchpad>/r-parity/dplyr_exports.tsv` (name, lifecycle, Rd topic).
- **PR-02** lifecycle: first `lifecycle-<stage>` match in each Rd `\description` (tools::Rd_db).
  tidyselect: `one_of.Rd` text: "one_of() is superseded in favour of the more precise any_of()
  and all_of() selectors" (tidyselect 1.2.1).
- **PR-03** Context7 `/tidyverse/dplyr/v1.2.0`, NEWS.md: "`case_match()` is soft-deprecated, and is
  fully replaced by `recode_values()` and `replace_values()`"; new `when_any()`/`when_all()`;
  `filter_out()`; `case_when()` family of 4 (`replace_when`, `recode_values`, `replace_values`).
- **PR-05** `julia --startup-file=no collide.jl names.txt` (Base, Core + 19 stdlibs; 1.13.2 and
  `julia +lts`, 1.10.12). Hits: `filter count first last coalesce union intersect setdiff symdiff
  collect contains startswith endswith occursin ifelse fill chop map reduce accumulate` → `Base`;
  `pmap` → `Distributed`. No hit: `select rename tail between nth n desc lag lead where mutate
  summarise arrange`. `tail`, `rename`, `between` flagged "(Base-internal)". Only diffs between
  versions: `transpose` also exported by LinearAlgebra on 1.10; `compact` internal on 1.10.
- **PR-07** `julia verify.jl`: `startswith("x")` → `Base.Fix2{typeof(startswith), String}`;
  `contains(r"^x\d")("x3")` → `true`; `occursin("x3")("x")` → `true` (haystack curried);
  `coalesce.([1,missing,3], 0)` → `[1, 0, 3]`; `ifelse.([true,false],1,2)` → `[1, 2]`;
  `isapprox.([1.0,2.0],[1.0+1e-12,2.1])` → `Bool[1, 0]`; `accumulate(&, [true,true,false,true])`
  → `Bool[1, 1, 0, 0]`; `length(unique([1,1,2,missing]))` → `3`.
- **PR-08** `verify2.jl`/`verify3.jl`: `where(x) = …; where(Number)` runs; `Iterators.nth`
  defined on 1.13.2, not on 1.10.12; `Base.between` has 1 method,
  `between(b::T, lo::T, hi::T) where T<:Integer @ Base strings/string.jl:30`;
  `Base.isexported(Base, :issetequal)` → `true`; `replace([1,missing], missing=>0)` → `[1, 0]`.
- **PR-09** `Rscript rsem.R`: `coalesce(c(1,NA,3),0)` → `1 0 3`; `n_distinct(c(1,1,2,NA))` → `3`;
  `min_rank(c(30,10,10,20))` → `4 1 1 3`; `dense_rank` → `3 1 1 2`; `cummean(1:3)` → `1 1.5 2`;
  `lag(1:3)` → `NA 1 2`.
- **PR-10** coverage: `uv run --python 3.13 python -I cover.py parity-dplyr.md dplyr_exports.tsv`
  → `{'prototype': 16, 'planned': 90, 'adapted': 16, 'skip': 52, 'base': 13} rows 187`,
  `dplyr_exports.tsv 283 missing: []`.

`<scratchpad>` = /private/tmp/claude-501/-Users-bonmac-personal-projects-julia-data-analysis-ChuiFrames-jl--worktrees-phase1-research/ec2d6965-575b-4df9-88c8-fd3cf43e61fc/scratchpad
