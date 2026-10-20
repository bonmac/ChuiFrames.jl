# ADR-0007: Depend on DataAPI.jl directly for shared selector and data-frame names

- **Status:** Proposed
- **Date:** 2026-10-20
- **Deciders:** the user, at the phase-1 ★ checkpoint
- **Scope:** ChuiFrames.jl (core dependency)

## Context

The grammar ADR (ADR-0002 rules 5 and 7) re-exports DataAPI's `Cols`, `Between` and `All`, so that
ChuiFrames' selectors are the *same bindings* DataFrames.jl users already have: re-exporting the
same binding never conflicts, defining another one does (GR-07 in
[grammar.md](../research/grammar.md)). DataAPI also owns generic names such as `nrow`, `ncol`,
`describe`, `refarray`/`refpool` and the metadata API, which DataFrames extends. DataAPI 1.16.0:
zero dependencies, Julia `[1, 2)`, already in Tables' closure (DP-01, DP-02), load ≤ 0.004 s,
last release 2024-01-22, last push 2026-10-09 ([dependencies.md](../research/dependencies.md)).

## Decision

ChuiFrames lists DataAPI as a direct dependency (`DataAPI = "1.16"`) and:
- re-exports `DataAPI.Cols`, `DataAPI.Between`, `DataAPI.All`;
- adds methods to DataAPI generics where they exist (`DataAPI.nrow`, `DataAPI.ncol`,
  `DataAPI.innerjoin` and the other joins, `DataAPI.groupby`, `DataAPI.describe` on frames;
  `DataAPI.refarray`/`refpool` on dictionary columns, 1-based as ADR-0001 rule 5 requires)
  instead of defining same-named functions.

## Alternatives rejected

| Alternative | Why rejected |
|---|---|
| Own `Cols`/`Between`/`All` | Conflicts with DataFrames' bindings for users who load both (GR-07). |
| Rely on DataAPI transitively through Tables without listing it | Pkg forbids `using` a package not in `[deps]`; the version would be uncontrolled. |

## Consequences

- No new package enters the dependency closure (DataAPI is already in Tables').
- The no-piracy rule (CF-009) still applies: methods on DataAPI functions take a ChuiFrames type.

## Verification

GR-07 ([grammar.md](../research/grammar.md)); DP-01, DP-02 ([dependencies.md](../research/dependencies.md)).
LC-08 ([lane-checks.md](../research/lane-checks.md)) shows, with DataFrames 1.8.2:
`DataFrames.nrow === DataAPI.nrow`, `ncol` likewise, the selector bindings identical, and DataAPI
also owning `innerjoin`/`leftjoin`/…, `groupby`, `describe` and `rownumber` (ADR-0002 rule 5).

## Revisit when

- DataAPI 2.0, or DataFrames stops sharing these bindings.
