# ADR-0013: Depend on the Dates standard library for date and time columns

- **Status:** Accepted (2026-10-20, user at the ChuiFrames phase-1 ★)
- **Date:** 2026-10-20
- **Deciders:** the user, at the phase-1 ★ checkpoint
- **Scope:** ChuiFrames.jl (core dependency, standard library)

## Context

Date and time columns come from CSV, Arrow and Parquet. ADR-0001 stores them over Arrow's integer
layouts and converts them at the I/O boundary to `Dates` types. Lubridate parity maps mostly onto
`Dates` functions applied with dots (`year.(c.d)`, `c.d .+ Day(1)`, verified in GR-01). Known
semantic differences (verified in
[parity-tidyverse-other.md](../research/parity-tidyverse-other.md)):
- R's `wday` starts weeks on Sunday, Julia's `dayofweek` on Monday;
- R's `ymd("2024-01-31") + months(1)` is `NA`, while Julia clamps the date;
- `Dates` knows only the UTC time zone.

Dates has no package version on 1.10.12 (LC-03, [lane-checks.md](../research/lane-checks.md)).

## Decision

ChuiFrames depends on Dates with `Dates = "1"`. The grammar critic resolved and instantiated a
scratch project with that entry on 1.10.12 and 1.13.2. Time-zone-aware columns
(TimeZones.jl, which is already in Arrow.jl's closure) are not decided here: phase 6 decides them
in its lubridate parity work.

## Alternatives rejected

| Alternative | Why rejected |
|---|---|
| Raw integers for dates | Users would have to convert every column; parity rows would need wrappers. |
| TimeZones.jl as a core dependency now | No phase before 6 needs zone-aware arithmetic. It arrives transitively through Arrow.jl as long as Arrow.jl stays in the core (ADR-0010's ★ question), so deferring it costs nothing. |

## Consequences

- The differential tests encode the `wday` and month-arithmetic differences.

## Verification

GR-01 ([grammar.md](../research/grammar.md)); LC-03 ([lane-checks.md](../research/lane-checks.md));
[parity-tidyverse-other.md](../research/parity-tidyverse-other.md) evidence; the grammar critic's
compat probe (scratch `p4.jl`, both Julia versions).

## Revisit when

- Phase 6 needs time-zone-aware columns.
