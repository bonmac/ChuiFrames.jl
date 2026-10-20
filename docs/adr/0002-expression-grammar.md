# ADR-0002: The expression grammar stays macro-free: `c.x` nodes, dots for elementwise, plain calls for whole columns

- **Status:** Accepted (2026-10-20, user at the ChuiFrames phase-1 ★)
- **Date:** 2026-10-20
- **Deciders:** the user, at the phase-1 ★ checkpoint
- **Scope:** ChuiFrames.jl

## Context

The brief keeps the prototype's macro-free design "unless an ADR shows a better one". The frame
contract already makes its core stable:
- `c.x` is deferred (CF-002);
- dotted calls are elementwise (CF-003);
- plain reduction calls reduce the whole column (CF-004);
- plain operators are not overloaded, and `==` on nodes is structural and returns a `Bool`
  (CF-005);
- `c.x |> f` applies `f` to the whole column (CF-006);
- verbs are values composed with `⨟` (CF-007);
- every verb accepts any Tables.jl source (CF-001);
- `c` is a plain export (CF-010).

This ADR settles what the contract leaves PROVISIONAL: selection, `across`, helpers, windows,
`missing`/NaN semantics, set verbs, verb options and coexistence with other packages.

Facts ([grammar.md](../research/grammar.md); [lane-checks.md](../research/lane-checks.md)):

**The capture mechanism** (all checked on Julia 1.10.12 and 1.13.2):
- It works for dotted operators and calls, `@.`, `ifelse.`, `in.(…, Ref(set))`, `.!`,
  parenthesised `.&`, `sum`/`mean`, `c.x .- mean(c.x)`, string and Dates functions, and
  `coalesce.`/`ismissing.` (GR-01). `.^` needs the `literal_pow` rule (GR-02).
- `c.x == missing` returns `missing`. The narrow `==(::Node, ::Missing)` fixes that with no
  ambiguity, and so does the mirror `==(::Missing, ::Node)`; a broad `==(::Node, ::Any)` creates
  ambiguities (GR-04, GR-13; critic probe, `detect_ambiguities` = 0).
- `sum(skipmissing(c.x))` fails at build time (GR-05).
- `cumsum.(c.x)` silently builds 0-dimensional arrays (GR-14).
- Plain Base calls on a node silently return constants. `coalesce(c.x, 0) === c.x`,
  `ismissing(c.x) == false`, and `something`/`isnothing` behave the same way (critic run, both
  versions).

**Names and coexistence:**
- A new exported binding of a Base name hides Base's function (LC-01).
- With DataFrames 1.8.2, `Cols`/`Between`/`All` (DataAPI) and `Not` (InvertedIndices) are the
  **same bindings**, so re-exporting them coexists. `select` and `rename` are DataFrames' own
  bindings and collide. DataAPI owns `innerjoin`/`leftjoin`/…, `groupby`, `describe`,
  `rownumber`, `nrow` and `ncol`. ShiftedArrays 2.0.0 does not export `lag`/`lead` (LC-08).
- TidierData exports `desc across where n lag lead row_number if_else case_when`
  ([parity-julia-frames.md](../research/parity-julia-frames.md) PJ-01).
- Base exports these dplyr/tidyr names: `filter count first last coalesce union intersect
  setdiff symdiff collect contains fill chop`
  ([parity-dplyr.md](../research/parity-dplyr.md), [parity-tidyr.md](../research/parity-tidyr.md)).
- `union((x=[1,2],), (x=[2,3],))` reaches Base's `union` (LC-07).
- Keyword order is preserved. Positional and keyword arguments arrive separately, so their
  relative order is lost (GR-15; critic probe).

**dplyr 1.2.0 semantics** (LC-07, GR-09 to GR-12):
- `filter` drops NA and NaN rows, including for `!=`.
- A non-logical predicate is an error.
- `arrange` treats NaN and NA as **one tie class**, last in both directions and in input order.
- It ties `0` and `-0`.

## Decision

**Capture and equality**
1. **Capture.** Keep the prototype mechanism:
   - `c` is a singleton whose `getproperty`/`getindex` build `Col` nodes;
   - a custom `BroadcastStyle` turns broadcasting over nodes into elementwise `Call` nodes, with
     the `literal_pow` → `^` rule;
   - plain calls of the whole-column functions build whole-column nodes.

   No macro is part of the grammar.
2. **Equality (CF-005).** `==`, `isequal` and `hash` on nodes are structural. ChuiFrames adds
   only three `==` methods: `==(::Node, ::Node)`, and `==(::Node, ::Missing)` and
   `==(::Missing, ::Node)`, which both return `false`. It **must not** add `==(::Node, ::Any)`.
3. **Silent-constant guards (narrow).** Only `coalesce(::Node, ::Any, ::Any...)` and
   `something(::Node, ::Any, ::Any...)` (node first, two or more arguments) **must** throw an
   `ArgumentError` naming the dotted form (`coalesce.(c.x, 0)`).
   - `ismissing`, `isnothing` and the single-argument and node-last forms are **not** guarded.
     Guarding them broke ordinary code such as `skipmissing(Any[c.x, missing])` and keyword
     defaults like `isnothing(get(kw, :d, nothing))` (critic probe `p7.jl`).
   - Rule 8 (constant results in `across`/`if_any`/`if_all`) and rule 17 (the Bool lint) catch
     some other plain calls. Not all of them: `mutate(s = string(c.x))` and
     `mutate(h = hash(c.x))` still make a constant column, because constants are legal values
     (`mutate(z = 1)`, as in dplyr). The docs list this as part of CF-005's known cost.

**Names**
4. **Base and stdlib names (CF-009).** A verb or helper that shares a Base or stdlib name is a
   method of that function, taking a ChuiFrames-owned argument: `filter(c.x .> 1)`,
   `first(c.x)`, `count(c.flag)` (a Bool column, as Base requires), `fill(c.x; direction = :down)`.
   - A verb whose natural arguments are only tables or plain values **must** get a distinct
     name, because plain Tables.jl inputs would reach Base (CF-001 forbids that).
   - So the set verbs are `union_rows`, `intersect_rows`, `setdiff_rows`, `symdiff_rows` (and
     `union_all`); the row slices are `head`/`tail`; dplyr's `count` verb is `count_by`; tidyr's
     `chop` is `chop_cols`.
   - `Base.tail` is `public` on 1.13 but not exported, so exporting `tail` is allowed.
   - The names marked here as placeholders are confirmed by the phase-2 parity work.
   - ChuiFrames **must never** export a new binding of a Base, Core or stdlib name.
5. **DataAPI generics.**
   - Where DataAPI owns a generic function (`innerjoin`, `leftjoin`, …, `groupby`, `describe`,
     `nrow`, `ncol`), ChuiFrames never defines a same-named function.
   - Methods it adds to those functions are **interop methods**: each requires at least one
     ChuiFrames frame argument, and none is an exported ChuiFrames verb. `DataAPI.innerjoin` on
     two plain NamedTuples stays a `MethodError` (critic `p6.jl`).
   - The exported verbs are dplyr's names (`inner_join`, `left_join`, `group_by`, …), and CF-001
     applies to them.
   - Whether CF-001 also covers interop methods is a contract reading the lead confirms.
6. **Accepted collisions.**
   - DataFrames' `select` and `rename`, and TidierData's `desc`, `across`, `where`, `lag`,
     `lead`, `row_number`, `if_else` and `case_when`, are different bindings from ChuiFrames'.
     Users who load both qualify them.
   - ChuiCore's conflict banner (brief) lists them on interactive load. Until the banner is
     released (it is PROVISIONAL), the coexistence docs page is the only notice.
   - The docs carry a coexistence page. ChuiFrames does not rename its dplyr verbs to avoid
     another package.

**Selection and helpers**
7. **Selection.** A `Selector` value chooses columns and never rows. Selector forms:
   - a `Symbol`, a string, a `Vector` of them, or a regex;
   - name predicates: any `Function` applied to the name string (`startswith("x")`);
   - `where(T)` / `where(pred)` on element types;
   - `Cols(…)`, `Between(…)`, `All()`, `Not(…)`.

   `c[:a]` and `c.a` are **nodes** (CF-002). In `select`, a bare node or `Symbol` keeps that
   column, and a computed node needs a name (`select(:z => c.a .+ 1)`). `select(:a => :b)`
   (Symbol to Symbol) is an `ArgumentError`, because DataFrames users read it as old → new.
   The error points to `select(:new => c.old)` or `rename`. `c[sel]` with a
   selector argument builds a selector. ChuiFrames re-exports `DataAPI.Cols`,
   `DataAPI.Between`, `DataAPI.All` and `InvertedIndices.Not`, and **must not** define its own.
8. **`across`, `if_any`, `if_all`.**
   - `across(sel, f)` and `across(sel, f1, f2; names = "{col}_{fn}")` work in
     `mutate`/`summarise`.
   - `f` receives a whole-column **node**, so it is written over columns:
     `across(where(Number), v -> round.(v))`.
   - `each(f)` returns an `Each` wrapper, not a `Function`, so it is never taken for a name
     predicate. It applies `f` elementwise: `across(where(Number), each(round))`. In selector
     position it is an `ArgumentError`.
   - `if_any(sel, pred)` / `if_all(sel, pred)` fold `pred(col)` with `.|` / `.&`.
   - In `across`, `if_any` and `if_all`, a function whose result for a column is not a node (a
     constant such as `string(c.x)` or `isequal(c.x, 0)`) is an `ArgumentError`.
9. **Helpers.**
   - `n_rows()` stands for dplyr's `n()`; `n` would break the single-letter rule.
   - `row_number()` is a special node evaluated per group.
   - `lag(c.x, k)`, `lead(c.x, k)` and the running operations (`cumsum(c.x)`, `cumprod`,
     `accumulate`) are plain calls that return **one value per row**, evaluated per group. That
     is a stated exception to ADR-0009 §2's "plain calls are reductions": plain calls are
     *whole-column* calls (CF-004/CF-006).
   - `desc(c.x)` is valid wherever an ordering is consumed: `arrange`, the ranking functions
     (`row_number(desc(c.x))`, `min_rank`, …) and `slice_min`/`slice_max`.
10. **`missing`.**
    - `skipmissing(c.x)` is a node, valid only as the argument of a reduction
      (`sum(skipmissing(c.x))`). Anywhere else it is an `ArgumentError`.
    - Reductions otherwise propagate `missing`, as Base does.
    - `case_when(cond => value, …; default = missing)` takes plain `Pair`s. The first `true`
      wins, and a `missing` condition counts as not true.
    - *Note (2026-10-20, user at the ChuiFrames phase-2c ★):* `var` and `std` of fewer than two
      values return `missing` (with `corrected = false`: of no values), where
      `Statistics.var` gives NaN. This matches dplyr's NA and the null of Polars and DuckDB.

**Semantics**
11. **`filter`.**
    - **Plan time.** The predicate's element type is inferred from the **declared schema**
      (ADR-0001 rule 1), never from the data. If it is concrete and not a subtype of
      `Union{Bool,Missing}`, `filter` raises an `ArgumentError` once, at plan time, on both paths.
      This matches dplyr's error for non-logical vectors (LC-07).
    - **Abstract predicate type.** This comes from object columns, and from **every**
      `c.x |> f` result unless the user declares its element type (spelling settled in phase 2).
      Julia's own inference (`Base.promote_op`) is never consulted, because Base documents it as
      fragile and version-dependent (critic `p10.jl`). For such predicates:
      - each value is checked row by row: `true` keeps, `false` or `missing` drops, anything
        else is an `ArgumentError`;
      - an empty chunk never raises;
      - no early stop (limit) may cut a scan below such a filter (ADR-0003 rule 6);
      - the filter is an optimizer barrier: no splitting, reordering, sibling-driven pruning or
        pushdown (ADR-0003 rule 4).

      So eager and lazy see the same rows and raise identically. Broadcasting over `Any` narrows its result
        type from the values (critic `p8.jl`), which is why the schema, not the chunk, decides.
    - A row is kept if its predicate is `true`, and dropped if it is `false` or `missing`.
12. **Documented NaN divergence from dplyr.** Julia comparisons follow IEEE: `NaN .> 1` is
    `false` and `NaN .!= 1` is `true`. So a predicate that is true on NaN keeps the NaN row
    (negations and `.!=`), where dplyr drops it. The differential suites encode this whole
    family. Statistics-based pruning respects it (ADR-0003, "Testing").
13. **`arrange`**, matching dplyr (LC-07):
    - non-NaN, non-`missing` values come first, in stable order, with `-0.0` and `0.0` **tied**;
    - then NaN and `missing` together, as one tie class in input order;
    - this holds in both directions;
    - `desc` reverses only the first part, and it **must not** be implemented as
      `sort(…; rev = true)`.

    The group-key order of a grouped summary stays CF-008's `isless` order, with NaN before
    `missing`. That matches dplyr's `group_by`, which also merges `0` and `-0` into one group, as
    ADR-0003 rule 8 does (critic `r4.R`: 4 groups from `0, -0, NA, NaN, 1, NaN, NA`). So
    `arrange` (NaN and `missing` tied) and group order (NaN, then `missing`) differ on purpose,
    as in dplyr, and the docs say so.
14. **Verb arguments.**
    - In `mutate`/`summarise`, keyword arguments are output columns, applied in order: later
      ones see earlier ones.
    - Positional arguments (`across(…)`, `"a b" => expr`, `:new => c.old`) are allowed **only
      when the call has no output keywords**. Mixing them throws an `ArgumentError`, because Julia
      loses their relative order (GR-15).
    - Each verb's option keywords are **reserved**, and listed per verb in the contract:
      `mutate` reserves `by`, `keep`, `before` and `after`; `summarise` reserves `by` and
      `groups`. Adding a reserved name later is a breaking change.
    - A column with a reserved name is created with a Pair (`"keep" => expr`). A reserved
      keyword given a node value is an `ArgumentError` pointing to the Pair form.
    - The mixing error for `summarise(across(…), n = n_rows())` suggests
      `summarise(across(…), :n => n_rows())`.
15. **Renaming** uses dplyr's direction, output first: `rename(new = :old)`, or
    `rename(:new => :old)` for non-identifier names. This matches `select(:new => c.old)` and
    the keyword forms, and it is the opposite of DataFrames' `rename(df, :old => :new)`. The docs
    call this out.
16. **Joins** take keys as `on = :k` or `on = [:a => :b]` (left `=>` right), not a
    `join_by(a == b)` expression, because `==` on nodes is structural (CF-005).
17. **Lints** (warnings that can be silenced):
    - At build time:
      - the GR-03 chained-comparison shape (`a .> 1 .& b .< 2`);
      - a dotted `.==`/`.!=` against a literal `missing`;
      - a bare `Bool` passed to `mutate`/`summarise`, silenced by writing `lit(true)`.
    - At evaluation time, when element types are known: `cumsum`/`cumprod`/`accumulate`
      dotted over a column whose element type is not an `AbstractVector`.
    - A bitmask such as `c.flags .& 0x04` is not linted.
    - `filter(false)` is Base's curried method and cannot be linted. CF-005 documents that
      cost.
18. **Printing** round-trips: a non-identifier column prints as `c.var"my col"`.

## Alternatives rejected

| Alternative | Why rejected |
|---|---|
| Macros (`@mutate`, `@transform`), as TidierData and DataFramesMeta | The user asked for plain Julia (DESIGN §3.1, §8), and CF-002–CF-007 are already stable. |
| DataFrames' `src => fun => dst` minilanguage as the primary form | Verbose, and the optimizer cannot see inside `fun`. Still reachable through `c.x \|> f`. |
| Overloading plain operators (as Polars does) | Breaks CF-005 and the "a column behaves like a Vector" rule. |
| `==(::Node, ::Any)` | Method ambiguities (GR-13). |
| Own `Cols`/`Not`/`Between` bindings | Would collide with DataFrames' (LC-08). |
| Methods on Base `union`/`intersect`/… for frames | Plain Tables.jl inputs would reach Base's methods, against CF-001 (LC-07). |
| Positional arguments before keywords (an earlier draft) | Silently reorders `mutate(y = …, across(…))` against dplyr (critic: `y = [4, 6]` vs dplyr `3 5`). |
| `filter` keeping only `=== true` and dropping everything else | Silently drops every row of a 0/1 Int predicate; dplyr errors (LC-07). |
| "NaN then `missing`" in `arrange` (an earlier draft) | Not what dplyr does: NaN and NA tie (LC-07). |
| Treating NaN as missing in comparisons, to match dplyr | Changes Base semantics for every float expression. |
| Renaming verbs to avoid DataFrames/Tidier collisions | Gives up dplyr parity, the brief's first goal. The banner and qualification handle coexistence. |
| `n()` / `nrow()` with no argument | Breaks ADR-0009 §6; `nrow()` would be piracy on `DataAPI.nrow`. |
| `join_by(a == b)` | Needs `==` to build a node, which CF-005 forbids. |

## Consequences

- **The parity matrices** are the checklist for names. Their "adapted" rows follow rules 4–16,
  and their placeholder names are settled in phase 2.
- **New dependency:** InvertedIndices (ADR-0008).
- **CF-005's contract test** gains the `== missing` cases.
- **Coordinator contract changes, once accepted (via the lead):**
  - the PROVISIONAL `c[...]`, selector and lint items in `chui-frames.md` can get IDs;
  - CF-008 should note that `arrange` order (rule 13) differs from group-key order;
  - ordered-factor sort order (ADR-0001 rule 5) is still open.
- **Differential suites** encode rule 12's NaN family, rule 13's ties, and `missing` join keys
  (ADR-0003 rule 11).

## Verification

- GR-01 to GR-16 in [grammar.md](../research/grammar.md).
- LC-01, LC-07 and LC-08 in [lane-checks.md](../research/lane-checks.md).
- PJ-01 and PJ-08 in [parity-julia-frames.md](../research/parity-julia-frames.md).
- The collision checks in [parity-dplyr.md](../research/parity-dplyr.md) and
  [parity-tidyr.md](../research/parity-tidyr.md).
- The grammar critic's stand-in probes on both Julia versions: `detect_ambiguities` = 0 for the
  rule-2 methods, and the silent constants of rule 3.

UNVERIFIED:
- that `select` can take `Function` predicates next to `Symbol`s and nodes without method
  ambiguity;
- the `each` and `lit` names (placeholders);
- the 1.10.12 half of LC-08, which was run by the critic only.

## Revisit when

- Julia adds a capture feature that makes macro-free lambdas shorter.
- A phase-2 parity row cannot be expressed under these rules.
- DataFrames or TidierData moves `select`/`rename` or the helpers into DataAPI (then extend
  them instead).
