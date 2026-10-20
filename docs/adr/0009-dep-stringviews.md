# ADR-0009: Depend on StringViews.jl 1.x as the element type of string columns

- **Status:** Accepted (2026-10-20, user at the ChuiFrames phase-1 ★)
- **Date:** 2026-10-20
- **Deciders:** the user, at the phase-1 ★ checkpoint
- **Scope:** ChuiFrames.jl (core dependency)

## Context

ADR-0001 stores strings as Arrow offsets plus data buffers, and its rule 3 fixes their element
type: `StrView = StringView{SubArray{UInt8,1,Vector{UInt8},Tuple{UnitRange{Int64}},true}}`.
Elements are returned without allocating. Allocating a `String` per element is what made
Arrow.jl's string column 2.5x slower to group by than `Vector{String}` (285 vs 114 ms, 10M
allocations; ST-10, [storage.md](../research/storage.md)).

StringViews has no dependencies and supports Julia `[1.6, 2)`. It loads in ≤ 0.004 s on 1.13.2
and 0.005–0.008 s on 1.10.12 (DP-03, DP-04, [dependencies.md](../research/dependencies.md)).
Under 1.3.7 the type above is concrete, compares `==` and hashes equal to `String` (LC-05,
[lane-checks.md](../research/lane-checks.md)). Its `Base.hash` method is the same code in 1.3.7 and
2.0.1 (storage critic, from source).

**Arrow.jl 2.8.1 requires `StringViews = "1"`** (DP-08), and Arrow.jl is a core dependency
(ADR-0010), so 2.x cannot be installed next to it. **StringViews 2.0 removes** (critic, from the
1.3.7 vs 2.0.1 source):
- `StringView(::String)`;
- `StringView(::IOBuffer, …)`;
- `StringView(::StringView)`;
- `Vector{UInt8}(::StringView{Vector{UInt8}})`.

It also adds a constructor check (concrete, 1-based parent), and becomes a stub over
`Base.StringView` once Base defines one (its docstring says Julia 1.14).

## Decision

1. ChuiFrames depends on StringViews with **`StringViews = "1"`**.
2. ChuiFrames code **must not** use the constructors and conversions that 2.0 removes (listed
   above). It builds views only as `StringView(view(data, a:b))` over a `Vector{UInt8}`, which
   2.0's constructor check also accepts.
3. Widening to `"1, 2"` is its own PR. It happens after Arrow.jl allows 2.x, and only once the
   tests pass on 2.x (ecosystem ADR-0004 rule 7).

## Alternatives rejected

| Alternative | Why rejected |
|---|---|
| `StringViews = "1, 2"` now | 2.x cannot be installed next to Arrow.jl 2.8.1, so it can't be tested, and admitting an untested major breaks ecosystem ADR-0004 rule 7. |
| Allocate a `String` per access | 10M allocations per scan (ST-10). |
| Store `Vector{String}` | Not Arrow layout: one pointer and one heap object per row. |
| Own view type | Re-implements a registered package that has no dependencies. |
| InlineStrings | No hashing gain, and `String31` uses 4x the memory (ST-10). |

## Consequences

- A lint or test greps `src/` for the forbidden constructors (phase 2).
- Hashing `StrView` group keys is not benchmarked yet. Phase 4 measures it against `String`.

## Verification

- ST-10 and A3 in [storage.md](../research/storage.md).
- DP-01, DP-03, DP-04 and DP-08 in [dependencies.md](../research/dependencies.md).
- LC-05 in [lane-checks.md](../research/lane-checks.md).
- The 1.x → 2.x API diff comes from the critic's reading of the two installed sources.

UNVERIFIED: the 2.x behaviour of the constructor rule 2 allows; 2.0 was not run.

## Revisit when

- Arrow.jl releases with StringViews 2 support.
- Julia ships `Base.StringView`.
