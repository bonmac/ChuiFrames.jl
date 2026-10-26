# Research notes (phase 1)

Verified notes behind the phase-1 ADRs. Each note lists its versions, method, findings, an
UNVERIFIED list and an Evidence section; evidence IDs are local to each note (a prefix per note),
and ADRs cite them as "<note> <ID>". Dated 2026-10-20 unless a note says otherwise.

| Note | Question | Evidence IDs |
|---|---|---|
| [parity-dplyr.md](parity-dplyr.md) | dplyr 1.2.0 → ChuiFrames: every export with status, phase, test | PR-01… |
| [parity-tidyr.md](parity-tidyr.md) | tidyr 1.3.1 parity matrix | PR-01… |
| [parity-tidyverse-other.md](parity-tidyverse-other.md) | readr, haven, stringr, lubridate, forcats, purrr, tibble | PR-01… |
| [parity-polars.md](parity-polars.md) | Polars 2.0.0 expression API, verbs and lazy engine | PE-01… |
| [parity-julia-frames.md](parity-julia-frames.md) | DataFrames.jl, DataFramesMeta, TidierData; name clashes | PJ-01… |
| [parity-others.md](parity-others.md) | data.table, pandas, Ibis, DuckDB, dbplyr/dtplyr, sqldf: ideas to borrow | PE-20… |
| [storage.md](storage.md) | Arrow.jl vs own buffers: layouts, speed, strings, dictionaries | ST-01… |
| [dependencies.md](dependencies.md) | 33 dependency candidates: versions, closures, load times | DP-01… |
| [parquet-csv.md](parquet-csv.md) | Parquet.jl vs Parquet2 for the built-in Parquet; CSV.jl versions | PQ-01… |
| [engine.md](engine.md) | Prototype facts, group-by, codegen, optimizers, execution, distributed | EN-01… |
| [grammar.md](grammar.md) | The `c.x` capture on 1.10 and 1.13, gaps, `missing`/NaN semantics | GR-01… |
| [source-sink.md](source-sink.md) | Tables.jl partitions, readers/writers, connector prior art | SS-01… |
| [differentials-polars-duckdb.md](differentials-polars-duckdb.md) | Phase 2c: eager verbs vs Polars 2.0.0 and DuckDB 1.5.6; every divergence | — |
| [performance.md](performance.md) | Phase 2c: budgets, load/TTFX, ratios vs DataFrames.jl, Polars, DuckDB; AirspeedVelocity | PF-01… |
| [performance-phase4.md](performance-phase4.md) | Phase 4: join/group-by/kernel budget rows, `RADIX_SWITCH` and broadcast-limit calibration, sort share, db-benchmark-like q1–q5/q1–q3 vs main, DataFrames.jl, Polars, DuckDB | P4-01… |
| [upstream-parquet2-timestamps.md](upstream-parquet2-timestamps.md) | Parquet2 loses 1 ms on INT64 timestamps (documented, not filed) | — |
| [upstream-airspeedvelocity-json3.md](upstream-airspeedvelocity-json3.md) | AirspeedVelocity cannot install next to CSV.jl 1.x (documented, not filed) | — |
| [lane-checks.md](lane-checks.md) | The lane owner's own confirmations | LC-01… |

How parity matrices are used: each row's "Test" column is the phase's test checklist (brief,
"API parity"). Status values: prototype, planned, adapted (spelling forced by Julia), base
(Base/stdlib already does it), skip (with a reason).

Scratch scripts and raw outputs stayed in the session scratchpad and are not part of the repo;
each Evidence entry quotes the command and the output that matters.
