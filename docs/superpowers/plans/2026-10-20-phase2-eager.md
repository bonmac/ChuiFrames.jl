# Phase 2 (eager frame): plan

- **Date:** 2026-10-20. **Branch:** `feat/phase2-eager` (lane `phase2-eager`), from `main` `c5db1cb`.
- **Tier:** T2 (public API, dependencies). **Spec:** the accepted phase-1 spec
  ([2026-10-20-phase1-research-design.md](../specs/2026-10-20-phase1-research-design.md), "How
  phase 2 starts") and ADRs 0001–0020. No new spec: this plan implements accepted decisions.
- **Brief:** `docs/agent/BRIEF.md` Phases §2: Arrow-backed storage, the core dplyr/tidyr verbs,
  tibble-style printing, CSV/Arrow/Parquet I/O, the conflict banner.

## Order

1. **Spike first** (ADR-0001 rule 10): ChuiFrames' own Arrow IPC reader against the gate corpus
   (Polars file and stream with strings over 12 bytes, ST-03 two views, ST-04 sliced dictionary,
   #610 replacement dictionaries, delta dictionaries, LZ4/Zstd, written by pyarrow 26.0.0, Polars
   2.0.0 and R arrow 23.0.1.1). Expected values are pyarrow dumps. **Gate:** every case reads
   correctly, unsupported types raise `ArgumentError`. **Fallback** (taken to the user by the lead
   if the gate fails or overruns): Arrow.jl's reader for streams only, file format raising, writes
   default to streams.
2. **Foundation** (this lane, before the sub-lanes): `Project.toml` with ADR-0005's compat
   entries; `src/columns.jl` (column kinds, zero-null-slot invariant, ingest, `take`,
   `vcat_columns`, offset widening); `src/frame.jl` (`Frame`, `GroupIndex`, Tables.jl, `groupcols`);
   `src/ChuiFrames.jl` with one entry file per sub-lane.
3. **Sub-lanes in parallel**, each its own worktree branched from `feat/phase2-eager`, disjoint
   file sets, merged back by this lane and reviewed:

   | Sub-lane | Owns | Deliverable |
   |---|---|---|
   | `p2-ipc` | `src/ipc/**`, `test/ipc/**`, `test/data/ipc/**` | own FlatBuffers table reader, IPC file (footer) and stream reader, dictionaries (per-batch, replacement, delta, dedup, null entries), Utf8View/BinaryView conversion, LZ4/Zstd, `ArgumentError` for unsupported types, big-endian and ordered dictionaries |
   | `p2-engine` | `src/engine/**`, `test/engine/**` | upstream adapter stand-ins (ADR-0014) with CC-004–CC-007 law tests; grammar nodes, capture, equality, guards, lints (ADR-0002); interpreter and grouped-window evaluation; the eager verbs (list below); the prototype's 8 regressions; the CF-001–CF-007/CF-009/CF-010 tests that need no lazy path |
   | `p2-io` | `src/io/**`, `ext/**`, `test/io/**` | Source/Sink abstract types and `TablesSource` (ADR-0004), the format registry (`register_format!`, `scan_file`, `write_file`), the Arrow writer adapter (ADR-0010, file format default, temp + rename, abort), the CSV source/sink (ADR-0019), the Parquet2 extension (ADR-0020) |
   | `p2-show` | `src/show/**`, `test/show/**`, `test/snapshots/**` | tibble-style `show` for frames (width/height fit, significant digits, `…` truncation, type row, group line, footers), `glimpse`, the conflict-banner stand-in (ChuiCore's PROVISIONAL shape) |

4. **Integration** (this lane): merge the sub-lanes in the order ipc → engine → io → show,
   PrecompileTools workload, exports and the CF-009 clash check, load time against ADR-0005
   rule 5, differential tests against dplyr/readr (`Rscript`) and Polars (`uv`), the full gate
   run, a read-only review of the whole diff, the changelog fragment and `HANDOFF.md`.

## Eager verbs in scope (from the parity matrices' phase-2 rows)

- **Rows:** `filter`, `filter_out`, `arrange` (+ `desc`), `distinct`, `slice`, `head`,
  `slice_head`, `slice_tail`, `slice_min`, `slice_max`, `slice_sample`.
- **Columns:** `select` (selectors: names, strings, vectors, regex, name predicates, `where`,
  `Cols`, `Between`, `All`, `Not`, `everything`, `last_col`, `any_of`, `group_cols`), `rename`
  (`new = :old`), `rename_with`, `relocate`, `mutate` (`keep`, `before`, `after`, `by`), `pull`.
- **Groups and summaries:** `group_by`, `ungroup`, `summarise`/`summarize` (`by`, `groups`),
  `reframe`, `count_by`, `tally`, `add_count`, `across`, `each`, `if_any`, `if_all`.
- **Helpers:** `n_rows`, `row_number`, `lag`, `lead`, `cumsum`/`cumprod`/`accumulate`, `cummean`,
  `case_when`, `n_distinct`, `nth`, `between`, `na_if`, `min_rank`, `dense_rank`,
  `consecutive_id`, `skipmissing` in reductions, `lit`, the CF-004 reductions.
- **Binding:** `bind_rows`, `bind_cols`.

## Milestone cut

If the branch grows past one reviewable diff, stop after step 4 with the verbs above and report
the rest as remaining: tidyr reshaping (`pivot_longer`/`pivot_wider`, `nest`/`unnest*`,
`separate_*`, `unite`, `fill`, `complete`/`expand`, `pack`/`unpack`), the ranking tail
(`percent_rank`, `cume_dist`, `ntile`), `ArrowTimestamp` (needs its phase-2 ADR first), and the
performance ADR (ADR-0003 consequences).

## Testing rules

- TDD per sub-lane: failing test first.
- Supposition properties: `@check record=false db=false …` plus an explicit `@test` on the
  result; no Supposition database directory under the test tree is ever committed.
- Differential tests are tagged `:differential` (they need `Rscript`/`uv`) and run in this
  lane's scratchpad environment; their results are reported, not assumed.
- Snapshot tests are tagged `:snapshot` (stable Julia only).

## Definition of done

The lead's list: the spike outcome; `ci.jl test` on 1.13.2 and `julia +lts … Pkg.test()` with
counts; `ci.jl test -- all`, `quality`, `jet`, `format`, `guards`, `contracts`; `dod.jl --base
main`; `scripts/lane audit phase2-eager`; load time; differential results; commit hashes; the
reviewer's final verdict; exports and clash check; what remains; draft requests; the roster;
what did not run.
