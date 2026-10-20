# Research: the expression grammar (`c.x`, selection, missing semantics)

- **Date:** 2026-10-20. **Lane:** phase1-research (researcher). **Status:** evidence for the
  grammar ADR; nothing here is a decision. Proposals are labelled **Proposal**.
- **Question.** (1) Does the prototype's macro-free capture (a `Col` node, a singleton `c`, a
  custom `BroadcastStyle`) work on Julia 1.10 and 1.13 for the forms users will write, and which
  forms fail or need special handling? (2) How should the known gaps be designed (column selection,
  `across`, `if_any`/`if_all`, `n()`/`row_number()`, windows, `case_when`, indexing forms of `c`,
  `desc`, renaming, ordering of `mutate` arguments)? (3) How do the alternatives capture
  expressions? (4) What are the `missing`/`NaN` semantics of `filter` and `arrange`?
- **Inputs.** The contract `chui-frames.md` (coordinator `contracts/`, CF-002 to CF-007 and its
  PROVISIONAL section), ecosystem ADR-0009 §2 and §6, prototype DESIGN §2/§3.1 and its Tidy.jl
  (read only; not run), coordinator evidence E-04, E-23, E-24, E-37.

## Versions

| Tool | Version |
|---|---|
| Julia | 1.13.2 (`julia --startup-file=no`) and 1.10.12 (`julia +lts --startup-file=no`) |
| DataAPI.jl | 1.16.0 |
| InvertedIndices.jl | 1.3.1 |
| Statistics, Dates, Test | standard libraries of each Julia |
| R / dplyr / tidyselect | R 4.4.2, dplyr 1.2.0, tidyselect 1.2.1 (`Rscript`) |
| Polars (Python) | 2.0.0 (`uv run --python 3.13 --with polars`) |

## Method

A minimal re-implementation of the prototype's capture (about 40 lines: `Node`, `Col`, `Lit`,
`Call{f, args, whole}`, singleton `c` with `getproperty`/`getindex`, `NodeStyle` with the
prototype's `literal_pow` rule, reductions as plain methods, `|>` as whole-column) was written in
the session scratchpad (`grammar/probe.jl`, `probe2.jl`, `probe3.jl`, `probe4.jl`) and run on both
Julia versions. Each probe prints the built node and its evaluation on a fixed NamedTuple table
`t = (x = [1, -2, 3, missing], y = [0.5, 1.5, 2.5, 3.5], s = ["ab","cd","xa","q"], d = Dates,
b = Bools, z = [1,2,3,4])`. dplyr and Polars semantics were run, not read. The prototype itself
was not run. **Every Julia claim below held identically on 1.10.12 and 1.13.2** (outputs diffed;
only error-message wording and one parse path differ, noted where relevant).

## Findings

### A1. The capture mechanism (GR-01 to GR-06)

Works unchanged (node built, evaluation equals the broadcast on the raw vectors) on both versions:

| Form | Node built | Evaluated |
|---|---|---|
| `c.z .+ 1`, `(+).(c.z, 1)` | `+.(c.z, 1)` | `[2, 3, 4, 5]` |
| `@. c.z * 2 + c.y` | `+.(*.(c.z, 2), c.y)` | `[2.5, 5.5, 8.5, 11.5]` |
| `ifelse.(c.z .> 2, c.z, 0)` | nested | `[0, 0, 3, 4]` |
| `in.(c.z, Ref(Set([1,2])))`, `c.z .∈ Ref(...)` | `in.(c.z, Ref(Set(...)))` | `[1, 1, 0, 0]` |
| `c.z .^ 2` (with the `literal_pow` rule) | `^.(c.z, 2)` | `[1, 4, 9, 16]` |
| `.!c.b` | `!.(c.b)` | `[0, 1, 0, 1]` |
| `(c.z .> 1) .& (c.y .< 2)` | `&.(>.(...), <.(...))` | `[0, 1, 0, 0]` |
| `sum(c.z)`, `mean(c.y)`, `c.y .- mean(c.y)` | whole / mixed | `10`, `2.0`, `[-1.5, -0.5, 0.5, 1.5]` |
| `c.z \|> cumsum` | whole | `[1, 3, 6, 10]` |
| `uppercase.(c.s)`, `occursin.("a", c.s)`, `startswith.(c.s, "x")` | elementwise; string scalars arrive as `Ref("a")` | as on vectors |
| `year.(c.d)`, `c.d .+ Day(1)` | elementwise; `Day(1)` arrives as `Ref` | as on vectors |
| `coalesce.(c.x, 0)`, `ismissing.(c.x)`, `isequal.(c.x, missing)` | elementwise | `[1,-2,3,0]`, `[0,0,0,1]`, `[0,0,0,1]` |
| `c.z .+ [10,20,30,40]` and `[10,...] .+ c.z` | vector becomes a `Lit` | `[11, 22, 33, 44]` |
| `(v -> v + 1).(c.z)`, `string.(c.s, "_", c.z)` | elementwise | as on vectors |

Needs special handling or fails:

1. **`literal_pow`** (GR-02). Without the prototype's extra `broadcasted` method, `c.z .^ 2`
   builds `literal_pow.(Ref(^), c.z, Ref(Val{2}()))`. It still evaluates correctly, but the node
   is unreadable and an optimizer or SQL lowering would not recognise `^`. Keep the rule.
2. **Unparenthesised `.&`/`.|`** (GR-03). `c.z .> 1 .& c.y .< 2` parses as the chained comparison
   `c.z .> (1 .& c.y) .< 2` and builds a node that fails only at evaluation:
   `MethodError: no method matching &(::Int64, ::Float64)`. Known (CF-005); the error is late and
   unhelpful. **Proposal:** a build-time lint for `&`/`|` nodes whose argument is a non-Bool
   literal, with a message pointing at the parentheses.
3. **Plain operators** (GR-04). `c.z > 1`, `!c.b`, `c.z + 1` raise `MethodError` at build time,
   as CF-005 requires. But two plain forms **do not error**:
   - `c.z == 1` returns `false` (Base's `===` fallback), so `filter(c.z == 1)` silently becomes
     `filter(false)`. This is CF-005's known "silent Bool" cost.
   - `c.x == missing` returns **`missing`** (Base's `==(::Any, ::Missing)`), not a Bool.
     CF-005 promises `==` on nodes always returns a Bool. Defining `==(::Node, ::Any)` to fix it
     creates method ambiguities (`==(::Node, ::Any)` vs Base's `==(::Missing...)` and
     `==(::Any, ::WeakRef)`, GR-13); the ambiguity-free fix is the two narrow methods
     `==(::Node, ::Node)` and `==(::Node, ::Missing)` (plus the mirrored `==(::Missing, ::Node)`;
     the mirror was **not** probed, UNVERIFIED).
4. **`c.x .== missing`** (GR-01) builds fine and evaluates to all-`missing`, so a `filter` on it
   drops every row under dplyr semantics (A4). It is almost always a bug for `ismissing.(c.x)`.
   **Proposal:** lint `==`/`!=` nodes with a literal `missing`.
5. **`skipmissing(c.x)`** (GR-05). `skipmissing(c.x)` returns a `Base.SkipMissing{Col}` (not a
   node), and `sum(skipmissing(c.x))` fails at build time with `no method matching iterate(::Col)`.
   **Needs design:** either `Base.skipmissing(::Node)` returning a node (a method of a Base
   function on an owned type, so no piracy), or a `skipmissing` keyword on reductions. dplyr's
   equivalent is `sum(x, na.rm = TRUE)`.
6. **Dotted scans are wrong silently** (GR-14). `cumsum.(c.g)` is elementwise and yields
   `[fill(1), fill(1), fill(2), fill(2)]` (0-dimensional arrays), not a running sum. Users who
   learn "dots mean elementwise" may still write it. **Proposal:** lint `cumsum`/`cumprod`/
   `accumulate` inside an elementwise node.
7. **Indexing a column** (`c.z[1]`) is a `MethodError` (no `getindex(::Col, ::Int)`). Fine for v0;
   `first(c.z)` covers the common case. Positional access (`nth`) is a parity-matrix item.
8. **`Pair` vs dotted `Pair`** (GR-14). `(c.z .> 2) => "big"` is a plain `Pair{Call,String}`
   holding a node (what `case_when` needs). `(c.z .> 2) .=> "big"` is captured as an elementwise
   `Pair.(…)` node that evaluates to a vector of `Pair`s. Document that `case_when` takes plain `=>`.
9. **Printing non-identifier names.** `c["name with spaces"]` and `c.var"my col"` print as
   `c.name with spaces` in the probe's naive `show`. The real `show` must print `c.var"my col"`
   (or `c["my col"]`) so printed expressions round-trip.

### A1b. Names, keywords and completion (GR-06)

- `c.:type`, `c.type`, `c.where`, `c.if`, `c.function`, `c.module` all reach `getproperty(c, :sym)`
  on both versions. `c.end` and `c.begin` also work: 1.13.2 parses `c.end` as `c.var"end"`,
  1.10.12 as `c.end`; both evaluate to `getproperty(c, :end)`.
- `c.var"my col"` and `c.var"x.y"` give `Symbol("my col")`, `Symbol("x.y")`.
- `c.true` fails differently: 1.13.2 `MethodError: getproperty(::D, ::Bool)`, 1.10.12
  `syntax: invalid syntax "c.(true)"`. `c.1x` is a `ParseError`. Such names need `c["1x"]`.
- `propertynames(c) == ()`. TAB completion therefore offers nothing after `c.`; completion of real
  column names needs a table in scope, which a deferred `c` does not have. (REPL completion was not
  exercised interactively: UNVERIFIED beyond `propertynames`.)

### A2. Designs for the gaps (GR-07, GR-08, GR-11, GR-14, GR-15)

Verified building blocks:

- **DataAPI 1.16.0 exports nothing but its module name.** It *defines* `Cols`, `Between`, `All`
  and `BroadcastedSelector`, and `nrow`, but not `Not`. `Not` lives in InvertedIndices 1.3.1
  (exports `InvertedIndex`, `InvertedIndices`, `Not`; `[1,2,3][Not(2)] == [1, 3]`). Tables 1.14.0
  already depends on DataAPI (`DataAPI = "1.1"` in its Project.toml), so reusing DataAPI's
  selectors costs no new dependency; `Not` would add InvertedIndices.
- `DataAPI.Cols(r"^x")`, `Cols(startswith("x"))` (a `Base.Fix2`) and `Between(:a, :b)` construct
  plain data values that a frame can interpret.
- **Re-exporting the same binding never conflicts.** Two modules that both re-export
  `DataAPI.Cols` and `InvertedIndices.Not` can be `using`-ed together: `Cols === DataAPI.Cols`.
  A *different* `Cols` conflicts (1.13.2: `UndefVarError` with an ambiguity hint; 1.10.12: a
  "conflicts with an existing identifier" warning). So ChuiFrames re-exporting DataAPI's selectors
  stays conflict-free next to DataFrames.jl; defining its own `Cols`/`Not` would not.
- `where` can be a function name: `where(T) = T` defines and `where(Number)` calls on both versions
  (the keyword is only special after a type expression).
- Pair forms are ordinary values: `Number => mean :: Pair{DataType,typeof(mean)}`,
  `r"^x" => mean`, `:new => c.old`, `"a b" => expr`, `(:a, :b) => (+)`.
- **Keyword order is preserved** (`keys(values(kw)) == (:z, :a, :m)` for `f(z=…, a=…, m=…)`), so
  `mutate(y = …, z = f(c.y))` can apply in order (dplyr does the same: `mutate(z = a*2, w = z+1)`
  gives `w = 3 5`, GR-11).
- **Positional Pairs and keywords cannot interleave.** `mutate("a b" => e1, :q => e2; y = e3)`
  receives the Pairs and the keywords separately; their relative order in the call is lost.
- `case_when((c.x .> 1) => "big", (c.x .<= 1) => "small"; default = "other")` as a plain function
  over Pairs builds one elementwise node and evaluates to `["big", "other", "other", "small"]` for
  `x = [3.0, NaN, missing, 0.5]` (missing and NaN fall through to the default; dplyr gives the
  same, GR-11).
- Zero-argument helpers work as special nodes (`NRow()`, `RowNumber()`) whose evaluation reads the
  row count of the table or group: `c.g ./ NRow()` gave `[0.25, 0.25, 0.5, 0.5]`.
- `c[:s]`, `c["s"]`, `c[Symbol(:s)]` and `getproperty(c, Symbol(:z))` all build the same `Col`.

**Proposals** (for the grammar ADR; not decisions):

| Gap | Proposal | Constraint found |
|---|---|---|
| Column selection | A `Selector` value distinct from `Node` (selection is about names, not rows). Reuse `DataAPI.Cols`, `Between`, `All` and `InvertedIndices.Not`, plus regexes, `startswith`-style predicates on names (`Cols(startswith("x"))`), and `where(T)` / `where(pred)` on element types. | `Not` needs InvertedIndices; own `Cols`/`Not` would clash with DataFrames (GR-07). |
| `across` | `across(sel, f)` and `across(sel, f1, f2; names = "{col}_{fn}")`, usable positionally in `mutate`/`summarise`; `f` gets a column *node*, so `across(where(Number), x -> x .- mean(x))` reuses the grammar. | Output naming template follows dplyr's `"{.col}_{.fn}"` (R docs, not run). |
| `if_any`/`if_all` | `if_any(sel, pred)` → an elementwise `.|` fold of `pred(col)` over the selected columns; `if_all` with `.&`. | dplyr: `filter(e, if_any(c(a, b), ~ .x > 2))` (GR-11). |
| `n()` | **Not `n`**: ADR-0009 §6/CF-009 allow no single-letter export but `c`. Candidates: `n_rows()` or `row_count()`; `nrow()` with no argument would be a method of `DataAPI.nrow` without an owned argument type (piracy). | GR-07 (`nrow` is DataAPI's). |
| `row_number()` | Zero-arg node, per group; `row_number(c.x)` = rank with ties by first occurrence, `missing` stays `missing` (dplyr: `row_number(x)` gives `NA` for `NA`, and ranks NaN as `NA` too, GR-11). | |
| Windows | `lag(c.x, k = 1; default = missing)`, `lead(...)`: whole-column nodes evaluated per group. Running ops stay plain calls (`cumsum(c.x)`), never dotted. | ShiftedArrays.jl also exports `lag`/`lead` (UNVERIFIED, not checked); a clash would need a shared function or distinct names. |
| `case_when` | `case_when(cond => value, …; default = missing)`, first true wins, `missing` condition = not true. | Verified (GR-14). |
| `c[...]` | Keep `c[:name]`, `c["name"]`, computed `c[Symbol("x", i)]`; `c[sel]` with a selector is a *selector*, not a node. | GR-01/GR-14. |
| `desc` | Keep `desc(c.x)` as a wrapper node valid only in `arrange`; ordering rules in A4. | |
| Renaming | `select(:new => c.old, …)` and `select(new = c.old)`; `rename(:new => :old)` follows dplyr's `new = old` direction. | |
| Non-identifier output names | `mutate("a b" => expr)`; document that Pair arguments are applied before keyword arguments. | GR-15. |

### A3. Alternatives (one verified line each)

- **DataFramesMeta.jl** (Context7 `/juliadata/dataframesmeta.jl`, docs on master, read
  2026-10-20): macros (`@transform df :c = :a .+ 1`) treat `:sym` in the expression as columns,
  `$var` escapes a variable column name, and `$(src => fun => dst)` passes DataFrames'
  minilanguage straight through.
- **TidierData.jl** (docs https://tidierorg.github.io/TidierData.jl/latest/, read 2026-10-20, no
  version on the page): macros capture bare names; "all other functions are automatically
  vectorized" except those in a lookup table, `~f()` opts out; `a = b - mean(b)` is rewritten as
  `:b => (b -> b .- mean(b)) => :a`.
- **DataFrames.jl minilanguage** (same TidierData page, and DataFramesMeta docs): `src => fun =>
  dst` Pairs; functions see whole columns. Not run here (DataFrames was not loaded): its
  behaviour is cited, not re-verified.
- **Polars** 2.0.0 (run, GR-12): `pl.col("x1") > 1` is an `Expr` built by **overloading plain
  operators**, the design CF-005 rejects. `pl.col("^x.*$")` selects by regex, `polars.selectors`
  by dtype (`cs.numeric()`), `pl.exclude("s")`, `pl.len()` for `n()`, `pl.when().then().otherwise()`
  for `case_when`.
- **Ibis `_`**: impossible in Julia; `_` is write-only (E-04, re-confirmed in ADR-0009 §2).
- **Query.jl**: not checked this session (UNVERIFIED); it is macro-based (`@from`, `@map` with
  `_.x` anonymous syntax) from memory only.

### A4. `missing` and `NaN` semantics (GR-09, GR-10, GR-11, GR-12)

- `c.x .> 0` on `[1, -2, 3, missing]` gives `[true, false, true, missing]` (three-valued logic).
  `missing & false == false`, `missing | true == true`, `missing & true === missing`.
- Base refuses `missing` in Boolean contexts: `filter(>(1), [1, missing, 3])` → `TypeError:
  non-boolean (Missing) used in boolean context`; `[1,2,3][[true, missing, true]]` →
  `ArgumentError: unable to check bounds for indices of type Missing`; `findall` likewise.
  `findall(isequal(true), mask)` gives `[1, 3]`.
- **dplyr 1.2.0** on `x = c(3, NaN, -Inf, Inf, NA, 1, -0, 0)`: `filter(x > 1)` keeps `3 Inf`
  (drops `NA` **and** `NaN`, since `NaN > 1` is `NA` in R); `filter(!(x > 1))` keeps
  `-Inf 1 0 0` (NaN dropped again). **Julia diverges here:** `NaN .> 1` is `false`, so
  `.!(c.x .> 1)` is `true` and keeps the NaN row. Differential tests must expect this or the
  grammar must treat NaN as missing in comparisons (not recommended: it changes Base semantics).
- **Sorting.** Base `sort` on `[3.0, NaN, -Inf, Inf, missing, 1.0, -0.0, 0.0]` gives
  `[-Inf, -0.0, 0.0, 1.0, 3.0, Inf, NaN, missing]`; `rev = true` gives
  `[missing, NaN, Inf, 3.0, 1.0, 0.0, -0.0, -Inf]` (missing and NaN **first**).
  `isless(-0.0, 0.0) == true`. Strings: `missing` last ascending, first with `rev = true`.
- dplyr: `arrange(x)` → `-Inf 0 0 1 3 Inf NaN NA`; `arrange(desc(x))` → `Inf 3 1 0 0 -Inf NaN NA`.
  NaN then NA stay **last in both directions**. (`cat` prints `-0` as `0`, so whether R keeps
  `-0`/`0` in input order was not observable here: UNVERIFIED.)
- Polars 2.0.0: `sort` puts nulls **first** by default in both directions, and NaN is the largest
  value (first when descending). A third, different convention.
- A custom `lt` puts `missing` last under descending order (verified):
  `[NaN, Inf, 3.0, …, -Inf, missing]` — NaN still first, so matching dplyr needs NaN handled too.

**Proposals:**
- `filter` keeps a row iff the predicate is `=== true` (missing ⇒ dropped), as dplyr; no error.
  Document the NaN divergence above.
- `arrange` orders non-NaN values (by `isless`, stable; `isless` puts `-0.0` before `0.0`), then
  NaN, then `missing`, **in both directions**; `desc` reverses only the non-NaN,
  non-missing part. It must not be implemented as `sort(...; rev = true)`.

## UNVERIFIED

- The mirrored method `==(::Missing, ::Node)` and whether it adds ambiguities (only
  `==(::Node, ::Missing)` was probed).
- ShiftedArrays.jl exporting `lag`/`lead` (not loaded).
- Query.jl's capture mechanism (not checked).
- DataFrames.jl minilanguage behaviour (cited from TidierData/DataFramesMeta docs, not run).
- dplyr's `across` naming template `"{.col}_{.fn}"` (not run; only `across(where(is.numeric), mean)`
  keeping names `a b` was run).
- REPL TAB completion behaviour beyond `propertynames(c) == ()`.
- Behaviour of the full prototype (not run; only a re-implementation of its capture was).
- Whether dplyr keeps `-0`/`0` in input order in `arrange` (not observable in the probe output).

## Evidence

All scripts are in the session scratchpad `grammar/` folder; outputs abbreviated. "Both" means the
1.13.2 and 1.10.12 outputs were diffed and agree apart from the noted lines.

- **GR-01 capture table.** `julia --startup-file=no probe.jl; julia +lts --startup-file=no probe.jl`
  (both). Sample: `@. c.z * 2 + c.y => +.(*.(c.z, 2), c.y) ==> [2.5, 5.5, 8.5, 11.5]`;
  `c.x .== missing => ==.(c.x, Ref(missing)) ==> [missing, missing, missing, missing]`;
  `occursin.("a", c.s) => occursin.(Ref("a"), c.s) ==> Bool[1, 0, 1, 0]`.
- **GR-02 literal_pow.** `LITPOW=0 julia … probe.jl` (both):
  `c.z .^ 2 => literal_pow.(Ref(^), c.z, Ref(Val{2}())) ==> [1, 4, 9, 16]`; lowered:
  `Base.broadcasted(Base.literal_pow, ^, getproperty(c, :z), Val{2}())`.
- **GR-03 precedence.** (both) `c.z .> 1 .& c.y .< 2 => &.(>.(c.z, &.(1, c.y)), <.(&.(1, c.y), 2))
  ==> EVAL ERROR MethodError: no method matching &(::Int64, ::Float64)`.
- **GR-04 plain operators.** (both) `c.x == missing => missing`; `c.z == 1 => false`;
  `c.z > 1 => MethodError: no method matching isless(::Int64, ::Col)`; `!c.b => no method matching
  !(::Col)`; `c.z + 1 => no method matching +(::Col, ::Int64)`.
- **GR-05 skipmissing.** (both) `sum(skipmissing(c.x)) => BUILD ERROR MethodError: no method
  matching iterate(::Col)`; `skipmissing(c.x) :: Base.SkipMissing{Col}`.
- **GR-06 names.** `probe.jl`, `probe2.jl` (both): `c.end => :end`, `c.begin => :begin`,
  `c.var"x.y" => Symbol("x.y")`, `propertynames(c) => ()`; `Meta.parse("c.end")` →
  1.13.2 `c.var"end"`, 1.10.12 `c.end`; `c.true` → 1.13.2 `MethodError … getproperty(::D, ::Bool)`,
  1.10.12 `syntax: invalid syntax "c.(true)"`; `c.1x` → `ParseError`.
- **GR-07 selectors.** `julia --project=<env> probe2.jl` (both, DataAPI 1.16.0,
  InvertedIndices 1.3.1): `DataAPI exported names: [:DataAPI]`; `Not defined=false`,
  `Cols/Between/All/BroadcastedSelector defined=true exported=false`;
  `InvertedIndices exports: [:InvertedIndex, :InvertedIndices, :Not]`;
  `Cols(startswith("x")) => DataAPI.Cols{Tuple{Base.Fix2{typeof(startswith), String}}}`.
  `probe4.jl` (both): `Cols === DataAPI.Cols -> true, Not -> true` when two modules re-export them;
  a third, different `Cols` → 1.13.2 `UndefVarError … two or more modules export`, 1.10.12
  `WARNING: using C2.Cols in module Main conflicts with an existing identifier`;
  `nrow in DataAPI: true`. Tables' Project.toml: `DataAPI = "1.1"`.
- **GR-08 where and Pairs.** `probe2.jl` (both): `define where(T) => defined ok`,
  `call where(Number) => Number`; `Number => mean :: Pair{DataType, typeof(mean)}`,
  `:new => c.old :: Pair{Symbol, Symbol}` (in this probe `c.old` returns a Symbol).
- **GR-09 missing in Base.** `probe2.jl` (both): `filter(>(1), [1,missing,3]) => ERR TypeError:
  non-boolean (Missing) used in boolean context`; `[1,2,3][[true,missing,true]] => ERR
  ArgumentError: unable to check bounds for indices of type Missing`;
  `findall(isequal(true), …) => [1, 3]`; `missing & false => false`; `missing & true => missing`.
- **GR-10 Julia sort.** `probe2.jl` (both): `sort: [-Inf, -0.0, 0.0, 1.0, 3.0, Inf, NaN, missing]`;
  `sort rev=true: [missing, NaN, Inf, 3.0, 1.0, 0.0, -0.0, -Inf]`; `isless(NaN,Inf)= false`;
  `sort lt=…, missing last on rev: [NaN, Inf, 3.0, 1.0, 0.0, -0.0, -Inf, missing]`.
- **GR-11 dplyr.** `Rscript dplyr.R` (dplyr 1.2.0): `filter(x > 1): 3 Inf`;
  `filter(!(x > 1)): -Inf 1 0 0`; `arrange(x): -Inf 0 0 1 3 Inf NaN NA`;
  `arrange(desc(x)): Inf 3 1 0 0 -Inf NaN NA`; `case_when: big other small big other small small
  small`; `row_number(x): 5 NA 1 6 NA 4 2 3`; `across(where(is.numeric), mean) names: a b`;
  `select(new = a) names: new s`; `if_any(c(a,b), ~ .x > 2): 2`; `mutate order: 3 5`.
- **GR-12 Polars.** `uv run --python 3.13 --with polars python -I polars_expr.py` (polars 2.0.0):
  `pl.col('x1') > 1 type: Expr`; `filter null: [3]  ~filter: [1]`;
  `regex col: ['x1', 'x2']  numeric selector: ['x1', 'x2']`; `len: 3`;
  `sort x2 asc: [-1.0, 1.5, nan]  desc: [nan, 1.5, -1.0]`;
  `sort x1 asc: [None, 1, 3]  desc: [None, 3, 1]`.
- **GR-13 ambiguities.** `probe3.jl` (both): with `==(::Node,::Any)` defined,
  `c.x == missing => ERR MethodError: ==(::Col, ::Missing) is ambiguous`; with
  `==(::Node,::Missing)` added → `false`. `Test.detect_ambiguities(Main)` (1.13.2) lists
  `Tuple{typeof(==), Node, Any} <> Tuple{typeof(==), Any, WeakRef}` and
  `BroadcastStyle(::NodeStyle, ::BroadcastStyle) <> BroadcastStyle(::S, ::Unknown)`; the second is
  why the prototype also defines `BroadcastStyle(::NodeStyle, ::Unknown)` (probe3 omitted it).
- **GR-14 helpers.** `probe3.jl` (both): `case_when build: Call  eval: ["big", "other", "other",
  "small"]`; `c.x ./ n: [0.25, 0.25, 0.5, 0.5]`; `row_number: [1, 2, 3, 4]`;
  `cumsum(c.g): [1, 2, 4, 6]`; `cumsum.(c.g): [fill(1), fill(1), fill(2), fill(2)]`;
  `probe.jl`: `(c.z .> 2) => "big" :: Pair{Call, String}`;
  `(c.z .> 2) .=> "big" => Pair.(>.(c.z, 2), Ref("big"))`.
- **GR-15 argument order.** `probe.jl`/`probe3.jl` (both): `kwargs order: (:b, :a, :c)` and
  `[:z, :a, :m]`; `mutate("a b" => e, y = e) split: (("a b", :q), [:y])`.
- **GR-16 macro packages.** Context7 `/juliadata/dataframesmeta.jl` query on `$` escaping and
  `$(src => fun => dst)`; WebFetch of the TidierData docs home page (quotes in A3).
