# ADR-0019: Depend on CSV.jl 1.x for the built-in CSV reader and writer

- **Status:** Accepted (2026-10-20, user at the ChuiFrames phase-1 ★)
- **Date:** 2026-10-20
- **Deciders:** the user, at the phase-1 ★ checkpoint
- **Scope:** ChuiFrames.jl (core dependency)

## Context

The brief makes CSV a built-in format, with readr-style readers. CSV 1.1.0 (2026-09-21) supports
Julia `[1.10, 2)` and has 7 direct and 14 transitive registered dependencies. It loads in
0.16 s on 1.13.2 and 0.20–0.35 s on 1.10.12 (DP-01 to DP-04,
[dependencies.md](../research/dependencies.md)). [parquet-csv.md](../research/parquet-csv.md)
found:
- `CSV = "0.10, 1"` alone resolves to 1.1.0 (PQ-12).
- A fresh environment with DuckDB.jl 1.5.5 resolves to **CSV 1.1.0**, with FixedPointDecimals
  0.4.2, and a DECIMAL query works. CSV drops to 0.10.17 only when FixedPointDecimals 0.6 is
  already locked (PQ-11, PQ-13). This corrects SS-12 in
  [source-sink.md](../research/source-sink.md).
- The same `CSV.File(…; select, types, missingstring, dateformat, delim, header, limit, ntasks)`
  call works on 0.10.17 and 1.1.0, but the column types differ:
  - 0.10.17 returns SentinelArrays, InlineStrings and pooled vectors;
  - 1.1.0 returns plain `Vector`s and `DataStrings.StringVector`.
- In 1.1.0, `CSV.Chunks` splits by 64 MiB byte windows, not by `ntasks` (PQ-14).
- CSV 0.10.17's first partitioned write under `-t 4` failed twice; 1.1.0 passed 3 of 3 (SS-10).

## Decision

1. ChuiFrames depends on CSV with **`CSV = "1"`**.
2. The CSV source converts every column into ChuiFrames column types (ADR-0001), always passing
   `pool` and string-type options explicitly.
   - It reads `CSV.Chunks` **sequentially**, as one ordered stream of partitions.
     `CSV.Chunks` cannot be accessed by handle (`getindex` is a `MethodError`; I/O critic
     `p9_chunks_api.jl`), and 1.x splits by 64 MiB byte windows, so code must not assume a
     partition count.
   - `CSV.Chunks` rejects `scan=` (`ArgumentError: unsupported Chunks keyword scan`, I/O
     critic `r2_scan.jl`). So the whole `Tables.Scan` is the CSV source's residual, and the
     engine applies it to every chunk. Column projection is passed through `CSV.Chunks`' own
     `select` keyword (`CSV.Chunks(…; select)` gave per-chunk columns `[[:x]]` with CSV 1.1.0 on
     Julia 1.13.2, I/O critic `r3_rules.jl`; not run on 1.10).
     `CSV.File(path; scan = …)` is used only for a whole-file, single-partition read.
3. The readr-style API (column specification, locale, `na`, skip and comment handling) is
   ChuiFrames' own layer over `CSV.File`. Where CSV.jl cannot express a readr feature, the parity
   matrix marks the row (phase 2). The CSV sink writes one file, sequentially (ADR-0004 rule 7).
4. **The differential oracle for the reader is readr**, through `Rscript`, on the same files.
   CSV.jl cannot be its own oracle.

## Alternatives rejected

| Alternative | Why rejected |
|---|---|
| `CSV = "0.10, 1"` | Two different column-type families to normalise and test, plus the 0.10 threaded-write failure (SS-10). The DuckDB conflict that motivated 0.10 does not hold in a fresh resolve (PQ-11, PQ-13). |
| An own CSV parser | Large (type inference, quoting, dates, threading) with no measured need. Kept as a phase-6 option if readr parity requires it. |
| CSV as an extension | The brief makes CSV built in, and a frame library that can't read CSV on load fails at first use. |

## Consequences

- source-sink.md's SS-12 is corrected by a note in that file. ADR-0004's consequence about
  DuckDB and CSV says the DBInterface extension must resolve FixedPointDecimals 0.4.0–0.4.2.
- CSV 1.x's other migration changes (nanosecond timestamps, no function-valued `types`/`select`)
  are UNVERIFIED and are checked in phase 2.

## Verification

- PQ-11 to PQ-14 in [parquet-csv.md](../research/parquet-csv.md).
- DP-01 to DP-04 in [dependencies.md](../research/dependencies.md).
- SS-10 in [source-sink.md](../research/source-sink.md).

UNVERIFIED:
- CSV 1.x migration-guide items not run;
- DuckDB with FixedPointDecimals 0.4.2 beyond one query.

## Revisit when

- CSV 2.0, or readr parity needs features CSV.jl cannot express.
