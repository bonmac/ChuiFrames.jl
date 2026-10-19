<!-- vendored contract: coordinator commit 275e879, contracts/chui-core.md, copied 2026-10-19 -->
# Contract: chui-core (v0)

> **DRAFT: not binding.** This contract becomes binding when ADR-0002, ADR-0004, ADR-0007,
> ADR-0009 and ADR-0010 are Accepted at the L0 ★. Until then no downstream relies on it and its
> entries may change without a contract ADR (see [README.md](README.md), "Drafts").

- **Owner:** ChuiCore. **Consumers:** ChuiTypes, ChuiFrames, and every future Chui package.
- **Contract version:** v0, describing ChuiCore 0.0.1 (unreleased).
- **Sources:** ADR-0002 (placement), ADR-0004 (versioning), ADR-0007 §2 (law kits),
  ADR-0009 §1, §5, §6 (vocabulary), ADR-0010 (format). Evidence: `research/ecosystem-verification.md`
  (E-NN).
- **Format:** see [README.md](README.md). Stable entries below; undecided items under
  [PROVISIONAL](#provisional), without IDs. CC-003, CC-008 and CC-009 were withdrawn before the
  contract became binding (`status=retired`); their IDs are not reused.
- **Qualified names.** Entries name the protocol functions and built-in aggregators qualified
  (`ChuiCore.partial`, `ChuiCore.Sum`). Contract tests use the qualified form. Which of these
  names are also *exported* is PROVISIONAL (see "Export list" below); `⨟` and `opcompose` are
  exported.

---

### CC-001 `⨟` composes left to right
`since=0.0.1 status=stable`

**Statement.**
- `ChuiCore` exports `⨟` (U+2A1F, typed `\bbsemi`) and its ASCII alias `opcompose`;
  `ChuiCore.opcompose === ChuiCore.:⨟`.
- **Behaviour, not structure:** for callables `f` and `g` and any arguments `x...`,
  `(f ⨟ g)(x...) == g(f(x...))`. What `f ⨟ g` *returns* is not promised: the generic fallback
  returns `g ∘ f`, but a downstream method may return its own type (ChuiFrames' `Step ⨟ Step`
  returns a `Pipeline`), so `(f ⨟ g) == (g ∘ f)` holds only for the fallback and is not part of
  this entry. `∘` (Base) stays available and keeps its right-to-left meaning.
- `⨟` is **binary, not n-ary**: methods take exactly two arguments, and `a ⨟ b ⨟ c` parses as the
  nested call `⨟(⨟(a, b), c)` (unlike `*`, which parses `a * b * c` as one 3-argument call; E-37).
- `⨟` is left-associative with precedence 12, the same as `∘` and `*`, above `|>` (9) and above
  every comparison, including the dotted ones (E-23). Consequences that callers must know:
  - `f ⨟ g ⨟ h` is `(f ⨟ g) ⨟ h`, and both groupings compute the same thing (law below);
  - `x |> f ⨟ g` parses as `x |> (f ⨟ g)`, which is the intended reading;
  - `c.x .> 3 ⨟ g` parses as `c.x .> (3 ⨟ g)`, so mixed expressions **must** be parenthesised;
  - `f ⨟ g ∘ h` parses as `(f ⨟ g) ∘ h` (same precedence, left-associative).

**Laws** (behavioural, for every input `x`): `((f ⨟ g) ⨟ h)(x) == (f ⨟ (g ⨟ h))(x) == h(g(f(x)))`;
`(identity ⨟ f)(x) == f(x) == (f ⨟ identity)(x)`.

names: `ChuiCore.:⨟`, `ChuiCore.opcompose`

**Example.**
```julia
using ChuiCore
inc(x) = x + 1
dbl(x) = 2x
(inc ⨟ dbl)(3) == dbl(inc(3)) == 8                    # true
opcompose(inc, dbl)(3) == 8                           # true
Meta.parse("c.x .> 3 ⨟ g") == :(c.x .> (3 ⨟ g))       # true: parenthesise!
```

**Parse shapes** (Base only), E-37:
```julia
Meta.parse("c.x .> 3 ⨟ g") == :(c.x .> (3 ⨟ g))   # -> true
Meta.parse("x |> f ⨟ g") == :(x |> (f ⨟ g))       # -> true
Meta.parse("f ⨟ g ∘ h") == :((f ⨟ g) ∘ h)         # -> true
Meta.parse("a ⨟ b ⨟ c").args                      # -> Any[:⨟, :(a ⨟ b), :c]
Meta.parse("a * b * c").args                      # -> Any[:*, :a, :b, :c]
```

test: `CC-001 ⨟ composes left to right` — checks `(f ⨟ g)(x) == g(f(x))` for a few Base
functions and several inputs (never `(f ⨟ g) == g ∘ f`), `opcompose === ⨟`, both associativity
groupings on sample inputs, and the parse shapes above by comparing `Expr` values, not printed
strings.

### CC-002 One `⨟` binding; downstream packages only add methods
`since=0.0.1 status=stable`

**Statement.**
- There is exactly one `⨟` binding in the Chui ecosystem, the one ChuiCore exports (ADR-0009 §1).
- A downstream package that needs `⨟` on its own types (e.g. ChuiFrames' `Step ⨟ Step → Pipeline`)
  **adds methods** to `ChuiCore.:⨟` (`import ChuiCore: ⨟` or `ChuiCore.:⨟(a::T, b::T) = …`). It
  never defines a new function named `⨟`, and if it re-exports `⨟`, its binding is identical:
  `Downstream.:⨟ === ChuiCore.:⨟`. Its methods dispatch on at least one type it owns (no piracy).
- Methods a downstream adds must keep CC-001's behavioural law: for values that are callable,
  `(a ⨟ b)(x)` equals `b(a(x))` under the downstream's documented equality for its results. For
  ChuiFrames that is **frame equality** (`chui-frames.md`, "Definitions").

names: `ChuiCore.:⨟`

**Example.**
```julia
module MyPkg
using ChuiCore
import ChuiCore: ⨟
struct Step; f::Function; end
struct Pipeline; steps::Vector{Step}; end
⨟(a::Step, b::Step) = Pipeline([a, b])      # a method, not a new binding
export ⨟
end
MyPkg.:⨟ === ChuiCore.:⨟                      # true
```

test: `CC-002 single ⨟ binding` — in each downstream repo: `isdefined(Pkg, :⨟)` implies
`Pkg.:⨟ === ChuiCore.:⨟`, and the downstream's own `⨟` methods (if any) satisfy CC-001's
behavioural law on its callable types, compared with its documented equality (frame equality
for ChuiFrames).

### CC-003 `⨟` is CompositionsBase's binding
`since=0.0.1 status=retired`

Withdrawn before the contract became binding (critic review B4, 2026-10-19): ADR-0009 §1 makes
this a *recommendation* that ChuiCore's own ADR confirms, not a decision. Now the PROVISIONAL item
"CompositionsBase binding" below. The ID is not reused.

### CC-004 Aggregator protocol: `init`, `partial`, `combine`, `final`
`since=0.0.1 status=stable`

**Statement.** An *aggregator* `agg` is a value (usually a singleton or small immutable struct)
that implements four generic functions owned by ChuiCore (ADR-0002 §2, ADR-0009 §5). The name
`partial` is subject to the PROVISIONAL item "`partial`: protocol vs partial application"; if the
L0 ★ renames it, this entry is edited before it becomes binding.

| Function | Returns | Semantics |
|---|---|---|
| `ChuiCore.init(agg)` | a fresh accumulator | A **factory**: every call returns a new accumulator that shares no mutable state with any other. Executors call it once per partition / task. The accumulator may be a "no value yet" state (CC-006). |
| `ChuiCore.partial(agg, acc, chunk)` | the updated accumulator | Folds every element of `chunk` (any iterable; usually an `AbstractVector` of one column's values for one partition) into `acc`. It **may mutate `acc`** and return it; callers always use the return value. An empty `chunk` returns an accumulator equivalent to `acc`. |
| `ChuiCore.combine(agg, a, b)` | the merged accumulator | Merges the accumulator of an **earlier** partition `a` with that of a **later** partition `b`. It **may mutate and return `a`**; callers must not reuse `a` or `b` afterwards. A "no value yet" accumulator on either side is an identity. |
| `ChuiCore.final(agg, acc)` | the result | Turns an accumulator into the user-visible value. The generic fallback is `final(agg, acc) = acc`. |

**Accumulator thunks.** Because `partial` and `combine` may mutate, every law below is stated over
*thunks* that build a fresh accumulator at each use, never over shared accumulator values:

```julia
acc(agg, x) = () -> ChuiCore.partial(agg, ChuiCore.init(agg), x)   # a fresh accumulator per call
# reference result of `agg` on the ordered chunks x₁, …, xₖ (k ≥ 1, chunks may be empty)
function R(agg, chunks)
    a = acc(agg, chunks[1])()
    for x in chunks[2:end]
        a = ChuiCore.combine(agg, a, acc(agg, x)())
    end
    ChuiCore.final(agg, a)
end
```

**Float tolerance** (the one definition every Chui law kit, contract test and CF-008 cites).
Let `v` be the whole input the compared results were computed from, `T = float(eltype(v))`,
`ε = √eps(T)` (≈ 1.49e-8 for `Float64`). Two results `r₁`, `r₂` are **`≈ᵃ` (approximately equal
for `agg` on `v`)** when `isequal(r₁, r₂)`, or both are floats and
`isapprox(r₁, r₂; atol = τ(agg, v), rtol = ε)`; tuples are compared componentwise:

| Aggregator | `τ(agg, v)` |
|---|---|
| `Sum` | `ε · sum(abs, v)` |
| `Mean` | `ε · sum(abs, v) / length(v)` (i.e. `ε · mean(abs, v)`) |
| `Prod` | `0` (relative tolerance `ε` only) |
| `Moments`, variance | `ε · mean(abs2, v)` |
| `Moments`, standard deviation | `√(ε · mean(abs2, v))` (since `|√a − √b| ≤ √|a − b|`) |
| `MapM(f, inner)` | `τ(inner, map(f, v))` |
| `ReduceM(op)` | stated by the user with the aggregator (PROVISIONAL constructor); exact by default |
| `Count`, `CountTrue`, `AnyM`, `AllM`, `Max`, `Min`, `Extrema`, `First`, `Last`, and any non-float result | exact: `isequal` only |

The tolerance applies to inputs with finite values, no intermediate overflow or underflow, and
`length(v) ≤ 1/ε` (≈ 6.7e7 for `Float64`): outside that domain float `combine` is not even
approximately associative (`(1e308 + 1e308) - 1e308` is `Inf`; `1e308 + (1e308 - 1e308)` is
`1e308`), and no law is promised. Base's default `isapprox` (`atol = 0`) is **not** the rule: it
fails on the counterexamples below (E-36).

**Laws** (`≈` is exact `isequal` for non-float results and `≈ᵃ` on the whole input otherwise):
1. **Split invariance:** for every ordered split `x₁, …, xₖ` of `v` (empty chunks allowed),
   `R(agg, [x₁, …, xₖ]) ≈ R(agg, [v])`.
2. **Identity of an empty partition:** with `E = acc(agg, eltype(v)[])` and `A = acc(agg, x)`,
   `final(agg, combine(agg, E(), A())) ≈ final(agg, A()) ≈ final(agg, combine(agg, A(), E()))`.
3. **Chunk concatenation:** `final(agg, partial(agg, acc(agg, x)(), y)) ≈
   final(agg, partial(agg, init(agg), Iterators.flatten((x, y))))` (both sides finalized;
   `Iterators.flatten`, not `vcat`, because chunks are any iterables).
4. **Agreement with Base:** for each built-in (CC-007) and non-empty `v`, `R(agg, split) ≈` the
   corresponding Base/Statistics call on `v` (`Sum()` ↔ `sum(v)`, `Mean()` ↔ `mean(v)`, …).
   **Values only:** the element type of a result is not promised by any law (e.g. `Sum` on
   `Real[1, 2.5]` may return `3.5` as `Float64` or `Real`). Empty input is CC-006's, not law 4's.

names: `ChuiCore.init`, `ChuiCore.partial`, `ChuiCore.combine`, `ChuiCore.final`

**Example.**
```julia
using ChuiCore
const CC = ChuiCore
agg = CC.Sum()
a = CC.partial(agg, CC.init(agg), [1, 2, 3])
b = CC.partial(agg, CC.init(agg), [4, 5])
CC.final(agg, CC.combine(agg, a, b)) == sum(1:5)       # true
```

**Counterexamples the tolerance must accept** (Base only), E-36:
```julia
using Statistics
ε = sqrt(eps(Float64))
approx(r1, r2, τ) = isequal(r1, r2) || isapprox(r1, r2; atol = τ, rtol = ε)
v1 = [1.0, 1e16, -1e16]                          # Sum split as [1.0] | [1e16, -1e16]
(sum(v1), sum(v1[1:1]) + sum(v1[2:3]))           # -> (0.0, 1.0)
approx(sum(v1), sum(v1[1:1]) + sum(v1[2:3]), ε * sum(abs, v1))   # -> true
part(v) = (m = mean(v); (length(v), m, sum(x -> abs2(x - m), v)))
chan((na, ma, Ma), (nb, mb, Mb)) = (n = na + nb; δ = mb - ma; (n, ma + δ * nb / n, Ma + Mb + δ^2 * na * nb / n))
fin((n, _, M2)) = M2 / (n - 1)
v2 = fill(0.1, 10)                               # the prototype's var, eager vs lazy (morsel 3)
lazyvar = fin(chan(part(v2[1:1]), part(v2[2:10])))
(var(v2), lazyvar)                               # -> (2.139922160430262e-34, 2.1185229388259596e-34)
isapprox(var(v2), lazyvar)                       # -> false
approx(var(v2), lazyvar, ε * mean(abs2, v2))     # -> true
chanvar = fin(chan(part(v2[1:3]), part(v2[4:10])))   # the Chan-merge split
approx(var(v2), chanvar, ε * mean(abs2, v2))     # -> true
approx(std(v2), sqrt(chanvar), sqrt(ε * mean(abs2, v2)))   # -> true
```

test: `CC-004 aggregator protocol` — for every built-in aggregator the downstream uses, checks
laws 1–4 with fresh accumulator thunks on fixed sample vectors split three ways (including an
empty chunk), comparing with the tolerance above; includes `[1.0, 1e16, -1e16]` for `Sum`; and
checks that two `init` calls return accumulators that do not alias (mutating one through
`partial` leaves the other's `final` unchanged).

### CC-005 `iscommutative` trait and the ordering obligation
`since=0.0.1 status=stable`

**Statement.**
- `ChuiCore.iscommutative(agg)::Bool` declares whether `combine(agg, a, b)` and
  `combine(agg, b, a)` finalize to equal results. The generic default is `false`.
- **Executors must respect it.** Any code that runs `partial`/`combine` in parallel (ChuiCore's
  own folds, ChuiFrames' engine, future packages) combines a non-commutative aggregator's
  accumulators **in partition order**. An operation that reorders rows (a shuffle, hash
  repartitioning) must either carry an order key and combine by it, or fall back to sequential
  combination, for every aggregator with `iscommutative(agg) == false`.
- Declaring `true` for an aggregator that is not commutative is a bug in that aggregator.

**Laws.** If `iscommutative(agg)`, then for all chunks `x`, `y`, with fresh thunks (CC-004):
`final(agg, combine(agg, acc(agg, x)(), acc(agg, y)())) ≈ final(agg, combine(agg, acc(agg, y)(), acc(agg, x)()))`,
with `≈` as in CC-004 on the input `Iterators.flatten((x, y))`.

names: `ChuiCore.iscommutative`

**Example.**
```julia
using ChuiCore
ChuiCore.iscommutative(ChuiCore.Sum())     # true
ChuiCore.iscommutative(ChuiCore.First())   # false: combine in partition order
```

test: `CC-005 iscommutative` — checks the declared value of each built-in against CC-007's
table, the commutativity law for those declared `true`, and that an aggregator type defined in
the test with no `iscommutative` method returns `false`.

### CC-006 Empty-input semantics
`since=0.0.1 status=stable`

**Statement.**
- **Value cases.** Where Base/Statistics returns a value on an empty `Vector`, `final(agg,
  init(agg))` returns the same value, compared with `isequal` (so `NaN` matches `NaN`). The
  *element type* is not promised, because `init(agg)` does not know the input element type
  (`final(Sum(), init(Sum()))` may be `0` while `sum(Float64[])` is `0.0`; `isequal(0, 0.0)` is
  `true`).
- **Throwing cases.** Where Base throws, ChuiCore throws the **exception type listed in CC-007's
  table**, the same on every supported Julia: `ArgumentError` for `Max`/`Min`/`Extrema`/`ReduceM`,
  `BoundsError` for `First`/`Last`. ChuiCore does **not** mirror the running Julia's exception
  type, because Base's is version-dependent: `maximum`/`minimum`/`extrema(Float64[])` and
  `reduce(max, Float64[])` throw `MethodError` on 1.10 and `ArgumentError` on 1.13 (E-34). Why
  this choice rather than "whatever Base throws here": one documented type is testable exactly
  (`@test_throws ArgumentError`), needs no `VERSION` branches in ChuiCore, and does not inherit
  1.10's `MethodError`, which wrongly suggests a missing method; `@test_throws Exception` would
  also pass on unrelated bugs.
- **Exemptions.** `ReduceM(op)` throws `ArgumentError` on empty input unless the user declares a
  neutral element (constructor PROVISIONAL), then returns that element; it is not compared with
  Base, which special-cases some operators (`reduce(+, Float64[]) == 0.0`). `MapM(f, inner)` on
  empty input behaves as `inner` on empty input; it is not compared with Base, which
  special-cases some mapped reductions (`maximum(abs, Float64[]) == 0.0`) (E-34).
- **Empty partitions.** Partitions may be empty. Every aggregator whose accumulator has no
  identity value carries an internal **"no value yet"** state, which `combine` treats as an
  identity and which `final` turns into CC-007's empty-input result. This covers the semigroups
  (`Max`, `Min`, `Extrema`, `First`, `Last`, `ReduceM`) **and `Moments`**: the prototype's Chan
  merge with a zero-count side gives `NaN` (`(0, NaN, 0.0)` merged with the state of `[1.0, 2.0]`
  is `(2, NaN, NaN)`), and its `partial` on an empty chunk throws (E-36).

names: `ChuiCore.init`, `ChuiCore.final`

**Example.**
```julia
using ChuiCore, Statistics
const CC = ChuiCore
isequal(CC.final(CC.Mean(), CC.init(CC.Mean())), mean(Float64[]))   # true: both NaN
CC.final(CC.Max(), CC.init(CC.Max()))     # throws ArgumentError on every Julia (Base: MethodError on 1.10)
```

test: `CC-006 empty input` — for every built-in the downstream uses except `ReduceM` and `MapM`:
value rows compare `final(agg, init(agg))` with the Base call on `Float64[]` by `isequal`;
throwing rows check `@test_throws <CC-007's type>` on ChuiCore and `@test_throws Exception` on the
Base call. `ReduceM` without a declared neutral element: `@test_throws ArgumentError`. Also law 2
of CC-004 with an empty partition on the left and on the right, for `Max` and `First`.

### CC-007 Built-in aggregators and their classification
`since=0.0.1 status=stable`

**Statement.** ChuiCore provides these aggregators. "Class" is the algebra that CC-004's laws are
checked against: a *Monoid* has an identity accumulator, a *Semigroup* only an associative
`combine` (its empty input throws), an *Aggregator* has a monoid accumulator plus a non-trivial
`final`. Float results are compared with CC-004's tolerance.

| Built-in | Base equivalent | Class | `iscommutative` | Empty input (CC-006) |
|---|---|---|---|---|
| `Sum()` | `sum` | Monoid (approximate for floats) | `true` | `0` |
| `Prod()` | `prod` | Monoid (approximate for floats) | `true` | `1` |
| `Count()` | `length` | Monoid | `true` | `0` |
| `CountTrue()` | `count` (Bool elements only; other elements throw, like Base) | Monoid | `true` | `0` |
| `AnyM()` | `any` | Monoid | `true` | `false` |
| `AllM()` | `all` | Monoid | `true` | `true` |
| `Max()`, `Min()` | `maximum`, `minimum` | Semigroup | `true` | throws `ArgumentError` |
| `Extrema()` | `extrema` | Semigroup | `true` | throws `ArgumentError` |
| `First()`, `Last()` | `first`, `last` | Semigroup | **`false`** | throws `BoundsError` |
| `Mean()` | `Statistics.mean` | Aggregator: monoid `(float sum, n)` + `final` | `true` | `NaN` |
| `Moments` (variance, standard deviation; constructor PROVISIONAL) | `Statistics.var`, `Statistics.std` (`corrected = true`) | Aggregator: Chan's parallel merge with a "no value yet" state + `final`; **approximately** associative | `true` | `NaN` |
| `ReduceM(op)` | `reduce(op, v)` on non-empty `v` | declared by the user; default Semigroup | default **`false`** | throws `ArgumentError` unless a neutral element is declared (exempt from Base match) |
| `MapM(f, inner)` | the `inner` call on `map(f, v)` for non-empty `v` | as `inner` | as `inner` | as `inner` on empty input (exempt from Base match) |

Further guarantees:
- `Mean` accumulates a floating-point sum, so `Mean()` on `Int` data never overflows and returns
  a float value, like `Statistics.mean` (prototype regression 1). Its element type is not
  promised beyond being a float (CC-004 law 4).
- `ReduceM(op)` assumes `op` is associative (Julia's `reduce` contract).
- Constructor arguments beyond those shown (how `Moments` selects variance vs standard deviation,
  how a user declares `ReduceM` commutative, a monoid, a neutral element or a tolerance) are
  PROVISIONAL.

names: `ChuiCore.Sum`, `ChuiCore.Prod`, `ChuiCore.Count`, `ChuiCore.CountTrue`, `ChuiCore.AnyM`, `ChuiCore.AllM`, `ChuiCore.Max`, `ChuiCore.Min`, `ChuiCore.Extrema`, `ChuiCore.First`, `ChuiCore.Last`, `ChuiCore.Mean`, `ChuiCore.ReduceM`, `ChuiCore.MapM`

**Example.**
```julia
using ChuiCore
const CC = ChuiCore
m = CC.MapM(abs2, CC.Sum())
CC.final(m, CC.partial(m, CC.init(m), [1, -2, 3])) == sum(abs2, [1, -2, 3])   # true
CC.iscommutative(CC.Last()) == false                                         # true
```

test: `CC-007 built-in classification` — a table-driven item over the rows above **except
`Moments`** (left out until its constructor is accepted): Base agreement (CC-004 law 4, values
only) on fixed integer, float and Bool vectors; the `iscommutative` column; the empty-input
column (as in CC-006); `Mean` on `typemax(Int)`-sized integers does not overflow.

### CC-008 Law-kit entry points
`since=0.0.1 status=retired`

Withdrawn before the contract became binding (critic review S3, 2026-10-19): the kit names,
calling convention and packaging depend on ADR-0007 §2's open option (a)/(b). Now the PROVISIONAL
item "Law kits". The one decided rule is CC-011. The ID is not reused.

### CC-009 Name-conflict banner utility
`since=0.0.1 status=retired`

Withdrawn before the contract became binding (critic review S3, 2026-10-19): ADR-0002 §2 places
the utility in ChuiCore but no ADR decides its API. Now the PROVISIONAL item "Name-conflict
banner". The ID is not reused.

### CC-010 No exported name collides with Base or a standard library
`since=0.0.1 status=stable`

**Statement.** For every name `n` exported by ChuiCore: if Base, Core or a standard-library
module exports `n`, then ChuiCore's binding **is** that module's (`getfield(ChuiCore, n) ===
getfield(M, n)`; ChuiCore only adds methods, each dispatching on a type ChuiCore owns). ChuiCore
exports no single-letter name; the ecosystem has no single-letter export other than ChuiFrames'
`c` (ADR-0009 §6). The same rule binds every Chui package (CT-003, CF-009).

**Example** (Base only):
```julia
function collisions(M::Module, others = (Base, Core))
    [n for n in names(M) if n !== nameof(M) && any(O -> Base.isexported(O, n) &&
        isdefined(O, n) && getfield(O, n) !== getfield(M, n), others)]
end
module Good; import Base: filter; export filter, combine; filter(::Nothing) = nothing; combine(a, b) = a; end
module Bad;  export identity; identity(x) = :mine; end
(collisions(Good), collisions(Bad))      # -> (Symbol[], [:identity])
```

test: `CC-010 no Base collisions` — runs the check above over ChuiCore's exports against Base,
Core and every standard library loaded in the contract environment (at least `Statistics`,
`LinearAlgebra`, `Dates`, `Random`, `Test`), and checks that no export is a single letter.

### CC-011 Law kits are never hard dependencies of ChuiCore
`since=0.0.1 status=stable`

**Statement.** Whatever form ChuiCore's law kits take (ADR-0007 §2 option (a) or (b), PROVISIONAL
below), loading ChuiCore never loads `Test` or Supposition: neither is in ChuiCore's `[deps]`
(ADR-0002 §5). Kits may live in an extension, a test-only module or a separate package.

**Example.**
```julia
# in a fresh process, with ChuiCore installed:
using ChuiCore
any(m -> nameof(m) in (:Test, :Supposition), values(Base.loaded_modules))   # false
```

test: `CC-011 law kits not hard deps` — in a fresh `julia --startup-file=no` subprocess of the
contract environment, `using ChuiCore` and checks that neither `Test` nor `Supposition` appears in
`Base.loaded_modules`; also reads ChuiCore's `Project.toml` (`pkgdir(ChuiCore)`) and checks that
neither is in `[deps]`.

---

## PROVISIONAL

No IDs and no contract tests. Each item gets an ID when ChuiCore's ADR accepts it (ADR-0010).

- **CompositionsBase binding** (was CC-003). Recommendation (ADR-0009 §1): ChuiCore depends on
  CompositionsBase (0.1.x, no dependencies of its own, E-03, E-28) and re-exports **only** `⨟`
  and `opcompose` from it (not `compose`, nor its re-export of Base's `∘`), so that
  `ChuiCore.:⨟ === CompositionsBase.:⨟` and a user loading ChuiCore with Accessors or
  Transducers sees no ambiguity. A future test of this must check the `===` identities and that
  an unqualified `⨟` resolves after `using ChuiCore, CompositionsBase`; it must **not** rely on
  the absence of a "both … export" warning: on 1.10 Julia prints that warning when two different
  bindings clash, on 1.13 it prints nothing and errors only at the use (`UndefVarError`), so a
  warning-based check passes vacuously on 1.13 (E-37).
- **Export list.** Whether the protocol functions (`init`, `partial`, `combine`, `final`,
  `iscommutative`) and the built-in aggregator types are exported or only `public`. Known
  pressure: `combine` is also exported by DataFrames (Context7, E-38), so exporting it makes a
  bare `combine` ambiguous for DataFrames users. The `public` keyword is a `ParseError` on 1.10
  (E-37), so marking names public needs a version gate: Compat's `@compat public …` (a no-op on
  1.10; ADR-0006, E-06) or `@static if VERSION >= v"1.11" eval(Meta.parse("public …")) end`.
  Downstream code uses qualified names until this is decided.
- **`partial`: protocol vs partial application** (★ decision item). Brief 10 asks for
  partial-application helpers; a function `partial(f, args...)` would clash with the protocol's
  `partial(agg, acc, chunk)` inside ChuiCore itself. Options:
  (a, recommended) the protocol keeps `partial` (ADR-0009 §5's vocabulary, already in CC-004);
  partial application is named `papply(f, args...)` (reusing `Base.Fix1`/`Fix2`, and `Base.Fix`
  from 1.12, where they fit);
  (b) the protocol function becomes `absorb(agg, acc, chunk)` (or `step!`), freeing `partial` for
  partial application; CC-004 is edited before it becomes binding.
  None of `partial`, `papply`, `absorb`, `step!` is exported by Base or Core (E-37).
- **Typeclass trait encoding.** How `Semigroup`, `Monoid`, `Functor`, `Applicative`, `Monad`,
  `Alternative`, `Foldable`, `Traversable`, `Contravariant`, `Bifunctor`, `Profunctor` and
  `Category`/`Arrow` are encoded as Holy traits, how an instance is declared, and the names of
  their operations. The monoid's neutral element is proposed as **`neutral(::Type{T})`**
  (ADR-0009 §5 as amended): `identity` is Base's and CC-010 forbids a new binding of it; `mempty`
  was considered and rejected as Haskell jargon. Neither `neutral` nor `mempty` is exported by
  Base or Core (E-37).
- **Law kits** (was CC-008). Recommended shape: ChuiCore exports `test_semigroup_laws`,
  `test_monoid_laws`, `test_aggregator_laws` as function stubs whose methods load only in test
  environments (ADR-0007 §2 option (a)); calling convention `test_*_laws(instance, gen; eq = …)`,
  recording `@test` results in the caller's testset, with CC-004's tolerance rule as the default
  `eq` for float results. Open: option (a) vs (b) (a separate test-utilities package), the form of
  `gen` (Supposition generator, sample vector, or both), and kits for the other typeclasses
  (`test_functor_laws`, …). Whatever is chosen must keep CC-011.
- **Name-conflict banner** (was CC-009). Recommended shape:
  `ChuiCore.binding_conflicts(mod)::Vector{Pair{Symbol,Vector{Module}}}` lists, for each name
  `mod` exports, the other loaded modules exporting a **different binding** of that name (method
  extension of the same binding is not a conflict; verified on 1.10.12 and 1.13.2, E-37);
  `ChuiCore.conflict_banner(io, mod)` prints them; silenced by `CHUI_QUIET_CONFLICTS=1`/`true`;
  each package calls it from `__init__` when `isinteractive()`. Names and switch are open.
- **Composition helpers:** `pipe`, `curry`, partial application (see the `partial` item),
  point-free helpers.
- **The transducer substrate API** (`Map`, `Filter`, `MapCat`, `Take`, `Reduced`, `foldxl`,
  `foldxt` in the prototype). Its *location* (ChuiCore, own implementation, Transducers.jl interop
  only via `ChuiCoreTransducersExt`) is decided by ADR-0002 §4; its names and semantics are not.
- **Recursion schemes:** `Fix`, cata, ana, hylo, para, apo, histo, futu, and monadic variants.
- **Data types à la carte and free monads:** coproducts, injection/projection, interpreters.
- **Laziness:** thunks, memoized lazy values, lazy structure combinators.
- **Optics:** lenses and prisms, possibly by reusing Accessors.jl.
- **The ADT and pattern-matching library choice** (own implementation vs Moshi.jl, SumTypes.jl,
  MLStyle.jl).
- **Purity and effect conventions** (documented here; the runtime itself is ChuiTypes', see
  `chui-types.md` "Obligations").
- **`missing`-aware aggregators** (`skipmissing` variants): ChuiFrames builds them on top of
  CC-004 (ADR-0002 §2); whether any live in ChuiCore is open.
