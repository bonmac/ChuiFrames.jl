# Phase 1 (Research and ADRs): design summary

- **Date:** 2026-10-20
- **Branch:** `feat/phase1-research`
- **Tier:** T2 (public API, contracts, dependencies)
- **Status:** Accepted (2026-10-20, user at the ChuiFrames phase-1 ★), with every recommendation
  taken. Nothing is implemented.

## Goal

Decide, with evidence, the parts of ChuiFrames the brief lists for phase 1:
- parity matrices;
- the storage design;
- the expression grammar;
- the engine architecture;
- the source/sink interface;
- the dependency budget.

Phase 2 (eager frame) can then start from accepted ADRs instead of the prototype's guesses.

## Research (all in [docs/research/](../../research/README.md))

| Note | What it settles |
|---|---|
| parity-dplyr, parity-tidyr, parity-tidyverse-other | All 889 exports of the 9 R packages, each in a row (long tails grouped), with proposed spelling, status, phase and test kind |
| parity-polars, parity-julia-frames, parity-others | Polars 2.0.0, DataFrames/DataFramesMeta/TidierData name clashes, ideas to borrow |
| storage, dependencies, parquet-csv | Arrow.jl vs own buffers (measured); 33 dependency candidates; Parquet.jl vs Parquet2; CSV 0.10 vs 1.x |
| engine | Prototype facts, group-by and codegen measurements, optimizer/execution survey |
| grammar, source-sink | `c.x` capture on 1.10/1.13, `missing`/NaN semantics, connector prior art |
| lane-checks | The lane owner's confirmations (LC-01 to LC-09) |

## Decisions (ADRs, all Proposed)

| ADR | Decision in one line |
|---|---|
| [0001](../../adr/0001-columnar-storage.md) | Own immutable Arrow-layout columns (values + `BitVector` validity, zeroed null slots, `StringView` strings, coded dictionaries, object columns for the rest). ChuiFrames reads Arrow IPC with its own reader and writes it through Arrow.jl. |
| [0002](../../adr/0002-expression-grammar.md) | Keep the macro-free `c.x` grammar. Selectors are a separate kind (re-exporting DataAPI's `Cols`/`Between`/`All` and InvertedIndices' `Not`). `filter` keeps `true`. `arrange` follows dplyr's NaN/NA ties. Distinct names wherever Base would capture plain inputs. |
| [0003](../../adr/0003-engine-architecture.md) | One plan IR for both modes: eager runs the same operators with the optimizer off. Rule passes run to a fixpoint, then a narrow cost stage. Push-based morsel pipelines over contiguous ranges keep CC-005 order. The group-by switches adaptively between per-thread tables and radix partitioning. Kernels are closures keyed on plan shape, with an interpreter for small inputs. |
| [0004](../../adr/0004-source-sink-interface.md) | Pushdown uses Tables.jl 1.14's `Tables.Scan` and its residual protocol. Sources add handles, NaN-safe statistics, row counts, ordering and boundedness. Any Tables.jl input is a Source. Formats go through a registry that extensions fill. Sinks are transactional (abort, temp file then rename, schema conformance), with Arrow file format by default. v0 is bounded-only. |
| [0005](../../adr/0005-dependency-budget.md) | Ten registered core packages plus Statistics and Dates. The set loads in about 0.23 s (1.13) and 0.41 s (1.10). Parquet and the connectors are extensions. Interim load budget: 0.5 s / 0.8 s. |
| 0006–0013, 0016–0019 | One ADR per core dependency: Tables, DataAPI, InvertedIndices, StringViews 1.x, Arrow (writer only), PrecompileTools, Statistics, Dates, TranscodingStreams, CodecZstd, CodecLz4, CSV 1.x. |
| [0014](../../adr/0014-dep-chuicore.md) | ChuiCore through one internal adapter. Each piece switches when ChuiCore releases it. Requests are filed when a stand-in is created. A release gate blocks shipping local stand-ins. |
| [0015](../../adr/0015-dep-chuitypes.md) | ChuiTypes from phase 5, through a `Task` shim with cooperative cancellation. Its request is filed now. v0.1.0 without it needs the user. |
| [0020](../../adr/0020-dep-parquet2.md) | Parquet through Parquet2 in a package extension (★: the brief says built in). |

## How phase 2 starts (outline for the plan; not the plan)

1. **Spike: the own Arrow IPC reader** against the gate corpus (ADR-0001 rule 10). On failure,
   the fallback goes to the user.
2. **Column types and their invariants**, and Tables.jl in and out (ADR-0001, ADR-0006).
3. **The upstream adapter's stand-ins** with CC-004 law tests, and the requests drafted
   (ADR-0014).
4. **Grammar nodes, equality, guards and lints** (ADR-0002).
5. **Single-threaded physical operators, the group index, the grouped-window operator and the
   interpreter.** Eager verbs from the dplyr matrix's phase-2 rows (ADR-0003 rule 18).
6. **CSV and Arrow sources and sinks** (ADR-0004, ADR-0019, ADR-0010).
7. **tibble-style printing**, with snapshot tests.
8. **The performance ADR**: TTFX, per-verb eager overhead, target ratios per benchmark family.

## Testing plan carried into phase 2

- **The prototype's 8 review bugs** become regression tests (brief).
- **CF-008 property tests** against an independent oracle:
  - morsel sizes 1–7, forced strategies, `-t 1` and `-t 4`;
  - adversarial values (NaN, `-NaN`, ±0.0, `missing`, permuted dictionaries, `ReduceM(string *)`).
  - Supposition's `@check` runs with `record = false` and `db = false`, plus an explicit
    `@test`. A failing `@check` is silent on Julia 1.10.12 (lead's finding), and a counterexample
    database written under 1.13 crashes 1.10 ("Cannot read stream serialized with a newer
    version"; ChuiCore phase 2, via the lead).
- **Differential tests** against dplyr (`Rscript`), Polars and DuckDB (`uv`). Expected
  divergences are encoded:
  - NaN in negated predicates (ADR-0002 rule 12);
  - `missing` join keys under DuckDB (ADR-0003 rule 11).
- **Reader tests** use files written by pyarrow, Polars and R's arrow package, with expected
  values from pyarrow dumps.

## ★ questions for the user (with recommendations)

1. **Arrow IPC read path:** own reader (recommended, ADR-0001), or Arrow.jl's reader with known
   silent failures.
2. **Parquet:** extension on Parquet2 (recommended, ADR-0020), or built in at about +1.2 s load.
3. **Arrow writer:** core (recommended, ADR-0010), or an extension saving about 13 packages, at
   the cost of the brief's "built in" and of in-core spilling.
4. **Morsel parallelism** in phase 3 instead of phase 5 (recommended, ADR-0003 rule 18).
5. **Renaming direction** `rename(new = :old)`, as in dplyr (recommended, ADR-0002 rule 15), or
   DataFrames' `old => new`.
6. **`Not` via InvertedIndices** (recommended, ADR-0008), or a distinct `except(…)` with no
   dependency.

## Risks

- **The own IPC reader** is phase 2's largest unknown. It is mitigated by the spike gate and its
  fallback.
- **Upstream.** ChuiCore's recursion-scheme and transducer APIs may not fit the plan functor.
  Requests are drafted now.
- **Thresholds** (interpreter rows, group-by switch, broadcast size) are educated starting
  values, calibrated in phase 4.
