# ADR-0020: Read and write Parquet through Parquet2.jl, in a package extension

- **Status:** Accepted (2026-10-20, user at the ChuiFrames phase-1 ★)
- **Date:** 2026-10-20
- **Deciders:** the user, at the phase-1 ★ checkpoint
- **Scope:** ChuiFrames.jl (weak dependency)

## Context

The brief lists Parquet as a built-in format. The prototype used Parquet2 (DESIGN §3.8).
Findings from [parquet-csv.md](../research/parquet-csv.md), Julia 1.13.2 and 1.10.12:
- **Parquet.jl 0.8.6** cannot open files written by pyarrow 20 or later (`KeyError` in the
  footer's statistics). It writes one row group, with no statistics, and rejects Date/DateTime
  columns (PQ-04, PQ-07).
- **Parquet2 0.2.37:**
  - lists row groups, reads one column of one row group, returns typed min/max/null-count
    statistics, and decodes nulls, dictionaries, snappy and zstd (PQ-03, PQ-05);
  - its concurrent reads matched sequential reads in 10 of 10 runs (PQ-09);
  - it writes several row groups, but drops min/max for any chunk with a `missing`, and pyarrow
    ignores the min/max it does write (PQ-07, PQ-08);
  - it loads in 1.1–1.5 s, plus 1.7–2.0 s for the first read (PQ-10);
  - it has 25 direct and 64 transitive dependencies, including Transducers.jl
    ([dependencies.md](../research/dependencies.md) DP-01, DP-02). Ecosystem ADR-0002 §4 kept
    Transducers.jl out of ChuiCore for its weight (about 20 transitive dependencies). By the same
    reasoning it should not load with every `using ChuiFrames`.
- **This ADR deviates from the brief** ("built in"), and the user decides it at the ★.

## Decision

1. Parquet support lives in a **package extension** on the weak dependency Parquet2
   (`Parquet2 = "0.2.37"`, so 0.2.x from 0.2.37). It is one file implementing ADR-0004's Source
   and Sink for Parquet: one partition per row group, statistics from
   `Parquet2.ColumnStatistics`, and one row group per morsel-sized partition on write.
2. `using ChuiFrames, Parquet2` enables it. The extension registers the format's source and sink
   from its `__init__` (`register_format!(:parquet; source = …, sink = …)`, ADR-0004 rule 9), so
   it needs no core stub. Then `scan_file("x.parquet")` and `write_file(x, "x.parquet")` work.
   Without Parquet2 loaded, the core's generic "no reader/writer registered" error applies, and
   the docs say which package to load.
3. **Statistics on our own files.** Since Parquet2 drops min/max for chunks with `missing`,
   pruning on ChuiFrames-written files works only for null-free chunks. That limitation is
   documented, and a request upstream (Parquet2 issue) is drafted for the lead.
4. Moving Parquet into the core, or to an own reader, is revisited when Parquet2's load cost or
   writer gap changes.

## Alternatives rejected

| Alternative | Why rejected |
|---|---|
| Parquet2 as a core dependency (the brief's "built in") | Adds 1.1–1.5 s to every `using ChuiFrames`, and 64 packages including Transducers.jl, for users who never touch Parquet. The ★ question asks the user to choose. |
| Parquet.jl | Cannot open current pyarrow files (PQ-04). |
| An own Parquet reader/writer | Thrift compact protocol, page encodings, nested repetition levels: a large project with no phase-2 need. Revisit for out-of-core and pushdown if Parquet2 blocks them. |
| Reading Parquet through DuckDB.jl | DuckDB is itself a heavy binary dependency, and the brief wants DuckDB as a differential reference, not the reader. |

## Consequences

- Brief deviation (★): Parquet is "one `using` away", not built in. The user approved this
  deviation at the phase-1 ★ on 2026-10-20.
- Parquet tests run in the extension's test environment, with files written by pyarrow and by
  Parquet2.
- Arrow IPC (built in) is the recommended on-disk format for ChuiFrames' own data.

## Verification

- PQ-03 to PQ-10 in [parquet-csv.md](../research/parquet-csv.md).
- DP-01 to DP-03 in [dependencies.md](../research/dependencies.md).

UNVERIFIED:
- why pyarrow ignores Parquet2's min/max;
- Parquet2's maintenance status beyond the GitLab activity in DP-06.

## Revisit when

- Parquet2 loads in under about 0.3 s, or drops Transducers.jl.
- Its writer keeps min/max with nulls.
- The user chooses built-in Parquet at the ★.
