# ADR-0005: The dependency budget: ten registered core packages, Parquet and connectors as extensions

- **Status:** Accepted (2026-10-20, user at the ChuiFrames phase-1 ★)
- **Date:** 2026-10-20
- **Deciders:** the user, at the phase-1 ★ checkpoint
- **Scope:** ChuiFrames.jl

## Context

The ecosystem rules ask for few dependencies, each with an ADR, and optional integrations as
package extensions (`ECOSYSTEM.md` §1.3–1.4, ecosystem ADR-0002). The brief makes CSV, Arrow IPC
and Parquet built in, and makes databases, Excel, SAS/SPSS/Stata, JSON, HTTP and S3 extensions.
ChuiFrames sits under every future Chui package, so its load time is paid by all of them.

Measured facts:
- 33 candidates with closures, load times and activity are in
  [dependencies.md](../research/dependencies.md) (DP-01 to DP-08).
- Parquet and CSV are covered in [parquet-csv.md](../research/parquet-csv.md).
- The proposed core set **resolves together on 1.10.12 and 1.13.2**: 60–61 manifest entries,
  51 of them non-JLL. It **loads in 0.22–0.24 s on 1.13.2 and 0.39–0.44 s on 1.10.12** (LC-09,
  [lane-checks.md](../research/lane-checks.md)).
- Parquet2 alone loads in 1.1–1.5 s and has 64 transitive dependencies (PQ-10, DP-01).

## Decision

1. **Core dependencies** (each has its own ADR):

   | Package | Compat | Why | ADR |
   |---|---|---|---|
   | Tables | `1.14` | CF-001 interchange; `Tables.Scan` pushdown | 0006 |
   | DataAPI | `1.16` | shared selector and generic bindings | 0007 |
   | InvertedIndices | `1.3` | `Not` | 0008 |
   | StringViews | `1` | string element type | 0009 |
   | Arrow | `2.8` | Arrow IPC writing | 0010 |
   | PrecompileTools | `1` | TTFX workloads | 0011 |
   | Statistics (stdlib) | `1` | reductions, `describe` | 0012 |
   | Dates (stdlib) | `1` | date/time columns | 0013 |
   | ChuiCore | the exact `0.0.x` snapshot released (e.g. `"0.0.1"`), from its release | `⨟`, aggregators, transducers, schemes | 0014 |
   | ChuiTypes | the exact `0.0.x` snapshot released, phase 5 | effect runtime, streams | 0015 |
   | TranscodingStreams | `0.11` | IPC decompression | 0016 |
   | CodecZstd | `0.8` | Zstd buffers | 0017 |
   | CodecLz4 | `0.4` | LZ4-frame buffers | 0018 |
   | CSV | `1` | built-in CSV | 0019 |

   Compat.jl is allowed without its own ADR (ecosystem ADR-0006 §4). That makes ten registered
   packages at the start of phase 2 (excluding the two stdlibs and the two upstream Chui
   packages), and twelve once ChuiCore and ChuiTypes join.
2. **Weak dependencies (package extensions).**
   - **Parquet2**, for Parquet (ADR-0020).
   - **Phase-6 connectors**, named but not yet proposed. Each needs its own dependency ADR when
     its lane starts: DBInterface (SQLite, DuckDB, Postgres), XLSX, ReadStat, JSON (JSON.jl 1.x,
     not JSON3), HTTP, AWSS3, and CategoricalArrays for interop.
   - **Phase-5 candidates**, evaluated in phase 5: Dagger and Distributed.
3. **Test-only** packages follow ecosystem ADR-0007 and ADR-0011: TestItemRunner, Supposition,
   Aqua, ExplicitImports, JET (its own environment) and BenchmarkTools. Differential references
   (R packages through `Rscript`; Polars, DuckDB, pandas and pyarrow through `uv`) are external
   tools, not Julia dependencies. DataFrames may enter the test environment for interop tests
   only.
4. **Rejected as direct dependencies** for now, with reasons in dependencies.md and the ADRs.
   PooledArrays, SentinelArrays and InlineStrings still enter the closure through Arrow.jl and
   CSV.jl; ChuiFrames code must not use them directly.
   - PooledArrays, CategoricalArrays (as core), InlineStrings and WeakRefStrings: ADR-0001;
   - SentinelArrays and Missings: Base suffices;
   - JSON3 (JSON 1.x is preferred);
   - Metatheory and RuntimeGeneratedFunctions: ADR-0003;
   - Polyester and OhMyThreads: `Threads.@spawn` suffices (ADR-0003);
   - Transducers.jl: ecosystem ADR-0002;
   - Parquet.jl: it cannot open current pyarrow files (PQ-04).
5. **Load-time budget (interim).** `using ChuiFrames` must stay within 0.5 s on 1.13.2 and
   0.8 s on 1.10.12, measured with the method of LC-09 (the median of three warm runs).
   - That is about twice the dependencies' own load. The headroom must also cover ChuiCore,
     ChuiTypes and ChuiFrames' own package image.
   - The numbers hold on the development machine (Apple M3 Pro) only. Anyone else first
     re-measures LC-09's baseline and scales it.
   - The performance ADR that phase 2 owes (ADR-0003) replaces these numbers with measured TTFX
     budgets and a CI-reproducible method.
6. **Adding a core dependency** needs its own ADR plus a re-run of LC-09's measurement in the
   same PR. The ADR must show the new total stays within rule 5.

## Alternatives rejected

| Alternative | Why rejected |
|---|---|
| Zero dependencies, own everything | An own CSV parser and an own Arrow writer are large projects with no measured need. Tables.jl is required by CF-001. |
| Parquet2 in the core (the brief's "built in") | Adds 1.1–1.5 s and Transducers.jl to every load (PQ-10, DP-02). This is a ★ question (ADR-0020). |
| Arrow as an extension | Saves about 13 packages, but contradicts the brief, and spilling needs the writer (ADR-0010). Offered to the user. |
| Proposing the phase-6 connectors' dependencies now | Their versions and APIs will move before phase 6. Ecosystem rules require an ADR per dependency, and each is written when it is adopted. |

## Consequences

- Brief deviation, approved by the user at the phase-1 ★ on 2026-10-20: Parquet is a package
  extension on Parquet2, not built in (ADR-0020); the Arrow writer stays in the core (ADR-0010).
- Phase 2's `Project.toml` lists the ten core packages and two stdlibs, with these compat
  entries in place before the first `Pkg.add` (LC-09 pitfall).
- Each future core dependency carries a measured load-time delta.
- Exporting nothing from these packages except the re-exports in ADR-0002 keeps CF-009
  satisfied.

## Verification

- LC-09 in [lane-checks.md](../research/lane-checks.md).
- DP-01 to DP-08 in [dependencies.md](../research/dependencies.md).
- PQ-04 and PQ-10 in [parquet-csv.md](../research/parquet-csv.md).

UNVERIFIED: the load-time budget's headroom for ChuiFrames' own code (nothing is built yet);
ChuiCore's and ChuiTypes' load cost.

## Revisit when

- The performance ADR sets measured TTFX budgets.
- Arrow.jl 3.0, CSV 2.0 or a lighter Parquet package is released.
- A core dependency's load time doubles.
