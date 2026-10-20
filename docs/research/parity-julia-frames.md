# Parity matrix: Julia data-frame packages

**Question.** What do DataFrames.jl, DataFramesMeta.jl and TidierData.jl offer (verbs, syntax,
missing handling, printing), which of their exported names would clash with ChuiFrames, and what
should ChuiFrames match, adapt or skip?

**Date.** 2026-10-20.

**Versions.** Julia 1.13.2; DataFrames 1.8.2; DataFramesMeta 0.15.6; TidierData 0.17.2; Chain 0.6.0
(held back by compat). Docs: Context7 `/juliadata/dataframes.jl` (manual, "split-apply-combine",
"working with data frames"), read 2026-10-20.

**Method.** A scratch environment outside the repo:

```sh
S=<scratchpad>/eng-parity
julia --startup-file=no --project=$S/env -e 'using Pkg; Pkg.add(["DataFrames","DataFramesMeta","TidierData","Chain"])'
julia --startup-file=no --project=$S/env jl_probe.jl     # verbs, missing, printing, exports
julia --startup-file=no --project=$S/env jl_probe2.jl    # full export list, Base-clash behaviour
```

**Status legend.** `prototype` = works in the prototype; `planned` = in the brief's phases, not
built; `adapted` = idea taken, surface changed; `skip` = not planned.

**Summary counts (39 feature rows).** prototype 8 · planned 17 · adapted 8 · skip 6. The
name-clash table (16 rows) has no status column.

**Headline.**

1. **Name clashes are real and Julia makes them errors, not warnings.** A module exporting its own
   `filter` (not a method of `Base.filter`) makes `filter` undefined in `Main`, even for
   `filter(iseven, 1:4)` (PJ-08). So ChuiFrames must **extend Base functions** (`Base.filter`,
   `Base.first`, `Base.unique`, `Base.collect`, `Base.count`, `Base.stack`, …) with methods on its
   own types, and **extend DataFrames' generics only through a package extension** if it wants to
   share `select`/`transform`/`combine`/`subset`/`rename`. Otherwise `using DataFrames, ChuiFrames`
   leaves those names unusable.
2. **The `src => fun => dst` minilanguage is DataFrames' expression grammar.** It is macro-free like
   ChuiFrames but positional and pair-based; `ByRow` marks elementwise work, which ChuiFrames
   expresses with dots. ChuiFrames' `c.x` grammar is more compact; keep it, and accept pairs only
   as an interop form (ADR question).
3. **Missing handling differs from Polars.** DataFrames propagates `missing` (group `b` sum is
   `missing`, PJ-03) and `subset` throws on `missing` unless `skipmissing=true` (PJ-03). Tidier
   auto-vectorizes but does not skip missing (`mean(x)` → `missing`, PJ-05). ChuiFrames should
   follow Julia/R (propagate, `na_rm`/`skipmissing` opt-in), not Polars.

## Name clashes

Export counts from `length(names(M))` (includes the module's own name): DataFrames **86**,
DataFramesMeta **148** (re-exports DataFrames), TidierData **93** (PJ-01).

| Likely ChuiFrames export | DataFrames 1.8.2 | DataFramesMeta 0.15.6 | TidierData 0.17.2 | Proposed ChuiFrames handling |
|---|---|---|---|---|
| `filter` | extends `Base.filter` (not exported) | same | `@filter` macro | add methods to `Base.filter`; never a new `filter` (PJ-08) |
| `select` | **exports** | re-exports | re-exports the DataFrames function (`===`, PJ-08) | conflict; extension method or qualified use |
| `transform` | **exports** | re-exports; `@transform` | - | ChuiFrames uses `mutate`; do not export `transform` |
| `combine` | **exports** | re-exports; `@combine` | - | do not export; prototype uses `summarise` |
| `subset` | **exports** | re-exports; `@subset`, `@rsubset` | - | do not export; `filter` covers it |
| `rename` | **exports** (`rename`, `rename!`) | re-exports; `@rename` | `@rename` macro | conflict on `rename`; extension method |
| `groupby` / `group_by` | `groupby` | `groupby`, `@groupby` | `@group_by` | `group_by` (no clash with `groupby`) |
| `mutate`, `summarise`, `summarize`, `arrange`, `ungroup`, `distinct`, `slice`, `count`, `nest` | - | `@distinct` | `@mutate @summarise @summarize @arrange @ungroup @distinct @slice @count @nest` macros | functions vs macros: no binding clash (`@mutate` ≠ `mutate`) |
| `desc`, `across`, `where`, `n`, `lag`, `lead`, `row_number`, `if_else`, `case_when` | - | `@where` macro | **exports these functions** | clash with TidierData when both loaded; same names are dplyr parity targets |
| `describe` | **exports** | re-exports | re-exports DataFrames' (`===`, PJ-08) | ChuiFrames uses `glimpse`/`summary`; avoid `describe` |
| `stack`/`unstack` | extends `Base.stack`; exports `unstack` | same | - | ChuiFrames uses `pivot_longer`/`pivot_wider` |
| `flatten` | **exports** | re-exports | - | ChuiFrames uses `unnest_longer` |
| `leftjoin` … `antijoin`, `crossjoin` | **exports** | re-exports | `@left_join` etc. | ChuiFrames uses `left_join` (underscore): no clash |
| `nrow`, `ncol` | **exports** | re-exports | re-exports `nrow` | extend `DataFrames.nrow`? Prefer `Tables`/`Base.size` |
| `c` | - | - | - | free (but users commonly name variables `c`; documented in the prototype) |
| `head`, `lazy`, `collect`, `explain` | - | - | `@head` | `collect`, `first`, `last` are Base: extend them |

Full DataFrames export list (PJ-08): AbstractDataFrame All AsTable Between ByRow Cols DataFrame
DataFrameRow GroupedDataFrame InvertedIndex Not SubDataFrame allcombinations allowmissing antijoin
coalesce colmetadata columnindex combine completecases crossjoin delete! describe disallowmissing
dropmissing emptymissing fillcombinations flatten groupby groupcols groupindices innerjoin insertcols
leftjoin levels mapcols metadata missing ncol nonmissingtype nonunique nrow order outerjoin
passmissing proprow rename rightjoin rownumber select semijoin skipmissings subset transform unique!
unstack valuecols (plus `!` variants and re-exported modules).

## Feature matrix

| Feature (package) | ChuiFrames equivalent (proposed) | Status | Phase | Notes | Source |
|---|---|---|---|---|---|
| `select(df, :a, :b => f => :c)` (DF) | `select(:a, c = f(c.b))` | prototype | 1 | Pair grammar is positional; ChuiFrames uses keywords + `c.x`. | Context7 `/juliadata/dataframes.jl`; DESIGN §2 |
| `transform(df, ...)` (DF) | `mutate(...)` | prototype | 1 | | PJ-02 |
| `combine(groupby(df,:g), :x => sum => :s, nrow => :n)` (DF) | `group_by(:g) ⨟ summarise(s = sum(c.x), n = n())` | prototype | 1 | Ran: `s=[4,0,4]` with `skipmissing`, `n=[2,1,1]`. | PJ-02 |
| `ByRow(f)` (DF) | `f.(c.x, c.y)` | adapted | 1 | Dots replace `ByRow`. | PJ-02 |
| `AsTable(cols) => f` (DF) | `pick(...)`/`across` returning a NamedTuple | planned | 2 | Multi-column inputs; dplyr `pick`. | Context7 `/juliadata/dataframes.jl` |
| `cols => f => [:lo, :hi]` multi-column output (DF) | NamedTuple-valued expression unpacked by `mutate`/`summarise` | planned | 2 | dplyr: data-frame-valued `summarise` results unpack. | Context7 `/juliadata/dataframes.jl` |
| column-independent ops `nrow`, `proprow`, `eachindex`, `groupindices` (DF) | `n()`, `n() ./ sum(n())`, `row_number()`, `cur_group_id()` | planned | 2 | Same set as dplyr context functions. | Context7 `/juliadata/dataframes.jl` |
| column selectors `Not`, `Between`, `Cols`, `All`, regex (DF) | tidyselect helpers | planned | 2 | DataFrames' `Not`/`Between` are exported types: names clash if ChuiFrames exports the same (prefer `!`, `:a:z`-style range helper). | PJ-08 |
| `groupby` + `GroupedDataFrame` (DF) | `group_by` marks groups on the table | prototype | 1 | Prototype stores `groups::Vector{Symbol}`; DF materialises group indices. | DESIGN §3.3 |
| `subset(df, :x => ByRow(>(1)); skipmissing=true)` (DF) | `filter(c.x .> 1)` dropping `missing` rows as dplyr does | adapted | 2 | DF throws on `missing` by default (PJ-03); dplyr drops. Follow dplyr. | PJ-03 |
| in-place `!` variants (`transform!`, `select!`, `subset!`) (DF) | none in the public API; immutable `Tbl` | skip | - | ChuiFrames tables are immutable values; data.table-style by-reference is a separate question (parity-others). | DESIGN §3.3 |
| joins `innerjoin/leftjoin/rightjoin/outerjoin/semijoin/antijoin/crossjoin` (DF) | `inner_join` … `cross_join` | planned | 4 | Ran: semijoin 2, antijoin 1, crossjoin 9 rows. | PJ-07 |
| `leftjoin!` (DF, in place) | none | skip | - | Immutable tables. | PJ-08 |
| `stack` / `unstack` (DF) | `pivot_longer` / `pivot_wider` | planned | 2 | Ran: `stack` → `(8,3)` with `variable`,`value`. | PJ-07 |
| `flatten` (DF) | `unnest_longer` | prototype | 1 | Prototype `unnest`. | PJ-08; DESIGN §2 |
| `dropmissing`, `completecases`, `allowmissing` (DF) | `drop_na`; Arrow validity handles allow/disallow | planned | 2 | `allowmissing` is a storage concern Arrow bitmaps make cheap. | PJ-08 |
| `passmissing(f)` (DF / Missings) | lift elementwise functions over `missing` automatically for Arrow nulls | adapted | 2 | Ran: `passmissing(sqrt).([4, missing])` → `[2.0, missing]`. Decide in the grammar ADR whether `f.(c.x)` lifts automatically. | PJ-04 |
| `skipmissing` inside reductions (Base) | `sum(c.x; na_rm=true)` or `sum(skipmissing(c.x))` | planned | 2 | Both should work; `skipmissing` already works if nodes broadcast through it. | PJ-02, PJ-03 |
| metadata (`metadata!`, `colmetadata!`) (DF) | column labels (haven `label`) | planned | 6 | haven parity needs variable labels. | PJ-08 |
| `describe(df)` (DF) | `glimpse`, `summary` | planned | 2 | Avoid the `describe` name. | PJ-08 |
| GroupedDataFrame printing (DF) | tibble style: one table plus `# Groups: g [3]` header | adapted | 2 | DF prints each group as its own table (PJ-06); tibble prints one table with a groups line. | PJ-06 |
| column type row under headers (DF) | type row under headers, abbreviated (`<dbl>`) | adapted | 2 | DF prints full types (`Int64?`, `String`); tibble abbreviates. | PJ-02 |
| `@chain` (Chain.jl) | `\|>` and `⨟` | adapted | 1 | ChuiFrames verbs are values, so plain `\|>` works without a macro. | PJ-05; DESIGN §3.4 |
| `@rtransform(:z = :y * 2)` / `@rsubset` (DFMeta) | `mutate(z = c.y .* 2)` | adapted | 1 | `:col` symbols inside macros; `r` prefix = row-wise. ChuiFrames: `c.y` and dots, no macros. | PJ-04 |
| `@by(:g, :m = mean(:z))` (DFMeta) | `group_by(:g) ⨟ summarise(m = mean(c.z))` | prototype | 1 | Ran: `m = [4,6,8]`. | PJ-04 |
| `@passmissing` (DFMeta) | automatic null lifting (see `passmissing`) | adapted | 2 | | PJ-08 (macro list) |
| `@astable` (DFMeta) | NamedTuple-valued expressions | planned | 2 | | PJ-08 (macro list) |
| `@orderby` / `@rorderby` (DFMeta) | `arrange` | prototype | 1 | | PJ-08 (macro list) |
| `@select`/`@transform` with `$col` interpolation (DFMeta) | `c[name]` with a runtime `Symbol` | planned | 2 | Programmatic column names without macros. | UNVERIFIED (`$` syntax not run) |
| Tidier `@filter/@mutate/@summarize` with bare names (`y > 1`) | `filter(c.y .> 1)` | adapted | 1 | Tidier auto-vectorizes (`x + 1` works elementwise, PJ-05); ChuiFrames requires dots by design. | PJ-05 |
| Tidier auto-vectorization rules (which functions are scalar) | explicit: dot = elementwise, plain = reduction | skip | - | ChuiFrames' explicit rule avoids Tidier's function lists. | PJ-05 |
| Tidier `@group_by` + `@summarize` | `group_by` ⨟ `summarise` | prototype | 1 | Ran; `mean(z)` → `[4,6,8]`. Group order `b,a,c` = order of first appearance (PJ-05), dplyr sorts keys. | PJ-05 |
| Tidier `across`, `where`, `starts_with`, `everything` | tidyselect helpers | planned | 2 | Same target (tidyselect). | PJ-01 |
| Tidier `@pivot_longer/@pivot_wider` | `pivot_longer`/`pivot_wider` | planned | 2 | Ran `@pivot_longer(df, (x, y))` → `(8,3)`. | PJ-07 |
| Tidier `@separate`, `@unite`, `@fill_missing`, `@drop_missing` | tidyr `separate`, `unite`, `fill`, `drop_na` | planned | 2 | | PJ-01 |
| Tidier `@slice_*`, `@count`, `@tally`, `@relocate`, `@pull`, `@bind_rows` | same dplyr verbs as functions | planned | 2 | | PJ-01 |
| Tidier `@clean_names` (janitor) | none | skip | - | janitor is out of the parity scope. | PJ-01 |
| Tidier `@unnest_longer/@unnest_wider` | `unnest_longer`/`unnest_wider` | planned | 2 | | PJ-01 |
| Tidier grouped printing | tibble style | skip | - | Tidier prints the DataFrames `GroupedDataFrame` unchanged (PJ-06); nothing to borrow. | PJ-06 |
| lazy evaluation / query plans (any of the three) | `lazy`, `explain` | skip | - | None of the three has a lazy engine or optimizer; ChuiFrames' differentiator. (TidierDB is a separate package; not studied here.) | PJ-08 (no such exports) |

## UNVERIFIED

- DataFramesMeta `$col` interpolation syntax: from memory; not run.
- Whether TidierData's exported `mean`, `median`, `std`, `var`, `quantile` are the `Statistics`
  functions (identity not checked).
- TidierDB (lazy SQL backend for Tidier) capabilities: not installed, not studied.

## Evidence

- **PJ-01** `jl_probe.jl`: `DataFrames v1.8.2 exports 86`, `DataFramesMeta v0.15.6 exports 148`,
  `TidierData v0.17.2 exports 93`. TidierData names include `@filter @mutate @summarise @summarize
  @arrange @group_by @ungroup @rename @select @slice @count @distinct @pivot_longer @pivot_wider
  @left_join … @anti_join @separate @unite @drop_missing @fill_missing @clean_names @unnest_longer
  @unnest_wider across where n desc lag lead row_number if_else case_when select describe mean median`.
- **PJ-02** `combine(groupby(df, :g), :x => (v -> sum(skipmissing(v))) => :s, nrow => :n)`:

  ```text
   Row │ g       s      n
       │ String  Int64  Int64
  ─────┼──────────────────────
     1 │ a           4      2
     2 │ b           0      1
     3 │ c           4      1
  ```

  `transform(df, [:x, :y] => ByRow((a, b) -> a + b) => :xy)` gave `xy = [2.0, missing, 6.0, 8.0]`.
- **PJ-03** missing: `combine(groupby(df, :g), :x => sum => :s)` → `s = [4, missing, 4]` (type `Int64?`).
  `subset(df, :x => ByRow(>(1)))` throws `ArgumentError: missing was returned in condition number 1
  but only true or false are allowed; pass skipmissing=true to skip missing values`.
- **PJ-04** `passmissing(sqrt).([4, missing])` → `Union{Missing, Float64}[2.0, missing]`.
  DataFramesMeta `@chain df begin @rsubset(:y > 1); @rtransform(:z = :y * 2); @by(:g, :m = mean(:z)) end`
  → `g = [b, a, c]`, `m = [4.0, 6.0, 8.0]`.
- **PJ-05** TidierData `@chain df begin @filter(y > 1); @mutate(z = y * 2); @group_by(g);
  @summarize(m = mean(z), s = sum(skipmissing(x))) end` → `g = [b, a, c]`, `m = [4,6,8]`, `s = [0,3,4]`.
  `@summarize(df, m = mean(x))` → `missing`. `@mutate(df, x2 = x + 1)` → `[2, missing, 4, 5]`.
- **PJ-06** grouped printing, DataFrames and TidierData identical:

  ```text
  GroupedDataFrame with 3 groups based on key: g
  Group 1 (2 rows): g = "a"
   Row │ g       x       y
       │ String  Int64?  Float64
  ─────┼─────────────────────────
     1 │ a            1      1.0
     2 │ a            3      3.0
  Group 2 (1 row): g = "b"
  ...
  ```

- **PJ-07** `semijoin` 2 rows, `antijoin` 1, `crossjoin` 9; `stack(df, [:x, :y], :g)` size `(8, 3)`,
  names `["g", "variable", "value"]`; `unstack` names `["id", "a", "b"]`; Tidier `@pivot_longer` `(8, 3)`.
- **PJ-08** `jl_probe2.jl`: full DataFrames export list (above). `TidierData.select === DataFrames.select`
  → `true`; `TidierData.describe === DataFrames.describe` → `true`. A test module exporting its own
  `filter` and `select`, loaded with `using DataFrames, TidierData, .M`:

  ```text
  new filter vs Base.filter in Main: error: UndefVarError: `filter` not defined in `Main`
  Hint: It looks like two or more modules export different bindings with this name, resulting in ambiguity.
  M.select vs DataFrames.select: error: UndefVarError: `select` not defined in `Main`
  filter on vector still works? error: UndefVarError: `filter` not defined in `Main`
  ```

  `DataFrames.filter === Base.filter` → `true` (PJ-01 run).
