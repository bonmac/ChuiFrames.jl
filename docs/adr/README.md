# Architecture Decision Records

Package-level decisions for this repo. Ecosystem-wide decisions live in the coordinator's
`adr/`. New ADRs start from [`0000-template.md`](0000-template.md); one decision per file,
about 60–120 lines, titled as a claim. Keep this index current in the same commit. The
phase-1 ADRs that carry many binding rules (0001–0004) run longer than that guide.

| # | Title | Status |
|---|---|---|
| 0000 | [Template](0000-template.md) | — |
| 0001 | [Columns are ChuiFrames' own Arrow-layout buffers; ChuiFrames reads Arrow IPC itself and writes it through Arrow.jl](0001-columnar-storage.md) | Accepted (2026-10-20, user at the ChuiFrames phase-1 ★) |
| 0002 | [The expression grammar stays macro-free: `c.x` nodes, dots for elementwise, plain calls for whole columns](0002-expression-grammar.md) | Accepted (2026-10-20, user at the ChuiFrames phase-1 ★) |
| 0003 | [One plan-based engine runs both modes: rule passes, a narrow cost stage, push-based morsel pipelines](0003-engine-architecture.md) | Accepted (2026-10-20, user at the ChuiFrames phase-1 ★) |
| 0004 | [Sources take `Tables.Scan` pushdown and answer with a residual, plus statistics and handles; sinks are transactional; v0 is bounded-only](0004-source-sink-interface.md) | Accepted (2026-10-20, user at the ChuiFrames phase-1 ★) |
| 0005 | [The dependency budget: ten registered core packages, Parquet and connectors as extensions](0005-dependency-budget.md) | Accepted (2026-10-20, user at the ChuiFrames phase-1 ★) |
| 0006 | [Depend on Tables.jl for interchange](0006-dep-tables.md) | Accepted (2026-10-20, user at the ChuiFrames phase-1 ★) |
| 0007 | [Depend on DataAPI.jl directly for shared selector and data-frame names](0007-dep-dataapi.md) | Accepted (2026-10-20, user at the ChuiFrames phase-1 ★) |
| 0008 | [Depend on InvertedIndices.jl for `Not`](0008-dep-invertedindices.md) | Accepted (2026-10-20, user at the ChuiFrames phase-1 ★) |
| 0009 | [Depend on StringViews.jl 1.x as the element type of string columns](0009-dep-stringviews.md) | Accepted (2026-10-20, user at the ChuiFrames phase-1 ★) |
| 0010 | [Depend on Arrow.jl to write Arrow IPC](0010-dep-arrow.md) | Accepted (2026-10-20, user at the ChuiFrames phase-1 ★) |
| 0011 | [Depend on PrecompileTools.jl for TTFX workloads](0011-dep-precompiletools.md) | Accepted (2026-10-20, user at the ChuiFrames phase-1 ★) |
| 0012 | [Depend on the Statistics standard library for reductions](0012-dep-statistics.md) | Accepted (2026-10-20, user at the ChuiFrames phase-1 ★) |
| 0013 | [Depend on the Dates standard library for date and time columns](0013-dep-dates.md) | Accepted (2026-10-20, user at the ChuiFrames phase-1 ★) |
| 0014 | [Depend on ChuiCore through one internal adapter, switching each piece when ChuiCore releases it](0014-dep-chuicore.md) | Accepted (2026-10-20, user at the ChuiFrames phase-1 ★) |
| 0015 | [Depend on ChuiTypes only when async I/O or the stream source needs it, from a release](0015-dep-chuitypes.md) | Accepted (2026-10-20, user at the ChuiFrames phase-1 ★) |
| 0016 | [Depend on TranscodingStreams.jl for buffer decompression in the IPC reader](0016-dep-transcodingstreams.md) | Accepted (2026-10-20, user at the ChuiFrames phase-1 ★) |
| 0017 | [Depend on CodecZstd.jl for Zstd-compressed Arrow IPC buffers](0017-dep-codeczstd.md) | Accepted (2026-10-20, user at the ChuiFrames phase-1 ★) |
| 0018 | [Depend on CodecLz4.jl for LZ4-frame-compressed Arrow IPC buffers](0018-dep-codeclz4.md) | Accepted (2026-10-20, user at the ChuiFrames phase-1 ★) |
| 0019 | [Depend on CSV.jl 1.x for the built-in CSV reader and writer](0019-dep-csv.md) | Accepted (2026-10-20, user at the ChuiFrames phase-1 ★) |
| 0020 | [Read and write Parquet through Parquet2.jl, in a package extension](0020-dep-parquet2.md) | Accepted (2026-10-20, user at the ChuiFrames phase-1 ★) |
| 0021 | [Timestamps that `DateTime` cannot hold are `ArrowTimestamp{U,TZ}` values compared by exact instant; zones are display metadata](0021-arrow-timestamp.md) | Accepted (2026-10-20, user at the phase-2b ★) |
| 0022 | [ChuiFrames' performance budgets: per-entry time and allocation budgets, a load-plus-first-call budget, informational targets against DataFrames.jl and Polars](0022-performance-budgets.md) | Accepted (2026-10-20, user at the phase-2c ★) |
