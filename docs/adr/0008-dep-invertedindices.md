# ADR-0008: Depend on InvertedIndices.jl for `Not`

- **Status:** Accepted (2026-10-20, user at the ChuiFrames phase-1 ★)
- **Date:** 2026-10-20
- **Deciders:** the user, at the phase-1 ★ checkpoint
- **Scope:** ChuiFrames.jl (core dependency)

## Context

dplyr's `select(-x)` / `!x` exclusion needs a Julia spelling. DataFrames.jl re-exports `Not` from
InvertedIndices 1.3.1; DataAPI has no `Not` (GR-07, [grammar.md](../research/grammar.md)). A
second `Not` binding would make `Not` undefined for anyone who loads both packages (the same
mechanism as LC-01, [lane-checks.md](../research/lane-checks.md)). InvertedIndices 1.3.1 has no
registered dependencies and supports Julia ≥ 1.6 (LC-02).

## Decision

ChuiFrames depends on InvertedIndices (`InvertedIndices = "1.3"`) and re-exports
`InvertedIndices.Not`. Selectors accept `Not(sel)` (ADR-0002 rule 7). ChuiFrames adds no method
to `getindex` for `InvertedIndex` on types it does not own.

## Alternatives rejected

| Alternative | Why rejected |
|---|---|
| Own `Not` | Clashes with DataFrames' `Not` for users of both (LC-01 mechanism). |
| A differently named exclusion (`except(:x)`) | Avoids the dependency but diverges from DataFrames users' habit; still needs a name that passes CF-009. A fallback if the user declines this dependency (★ question). |
| Unary minus on selectors (`-:x`) | Piracy on `Symbol` (`-(::Symbol)` is not ours). |

## Consequences

- One zero-dependency package added to the closure.

## Verification

GR-07 ([grammar.md](../research/grammar.md)); LC-01, LC-02 ([lane-checks.md](../research/lane-checks.md)).
The grammar critic measured `using InvertedIndices` at 0.0046 s (1.13.2) and 0.0041 s (1.10.12),
and LC-08 shows `DataFrames.Not === InvertedIndices.Not` with DataFrames 1.8.2.

## Revisit when

- DataAPI gains a `Not`, or DataFrames moves away from InvertedIndices.
