# ADR-0006: Depend on Tables.jl for interchange

- **Status:** Proposed
- **Date:** 2026-10-20
- **Deciders:** the user, at the phase-1 ★ checkpoint
- **Scope:** ChuiFrames.jl (core dependency)

## Context

CF-001 promises that every frame is a Tables.jl table and that every table input accepts any
Tables.jl source; ecosystem ADR-0009 §3 makes Tables.jl the interchange interface. Tables 1.14.0:
Julia `[1.9, 2)`, 5 direct and 5 transitive registered dependencies (DataAPI,
DataValueInterfaces, IteratorInterfaceExtensions, OrderedCollections, TableTraits), load
0.012–0.015 s on 1.13.2 and 0.015–0.025 s on 1.10.12, released 2026-08-24, 6 contributors with ≥ 5
commits ([dependencies.md](../research/dependencies.md) DP-01 to DP-05). Its partitions carry
data only. Since 1.14.0 it also has `Tables.Scan`: a plain-data projection, filter and limit
request with a residual protocol (LC-10, [lane-checks.md](../research/lane-checks.md); SS-01 as
corrected).

## Decision

ChuiFrames depends on Tables with `Tables = "1.14"`, the version with `Tables.Scan` (LC-10).
- Frames implement `Tables.istable`, `Tables.columnaccess`, `Tables.columns` (with
  `Tables.getcolumn`/`columnnames`), `Tables.schema` and `Tables.materializer`.
- `Tables.partitions` of a lazy result yields its materialized partitions.
- `Tables.Scan` is the pushdown vocabulary of ChuiFrames' Source interface (ADR-0004 rule 1).
  Partition handles, statistics, ordering and boundedness are ChuiFrames' additions over it.

## Alternatives rejected

| Alternative | Why rejected |
|---|---|
| No Tables dependency (duck-typed `NamedTuple`s only) | Breaks CF-001: DataFrames, Arrow, CSV, database results would not be accepted. |
| TableTraits/IterableTables | Older interface with less adoption; Tables already bridges it (TableTraits is in its closure). |

## Consequences

- DataAPI arrives transitively; using its names directly needs its own ADR (ADR-0007).
- CF-001's contract test depends on this.

## Verification

DP-01 to DP-05 ([dependencies.md](../research/dependencies.md)); Tables interface requirements
from Context7 `/juliadata/tables.jl` (ST-15, [storage.md](../research/storage.md)).

## Revisit when

- Tables 2.0 is released.
