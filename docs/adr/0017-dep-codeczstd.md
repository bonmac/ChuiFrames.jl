# ADR-0017: Depend on CodecZstd.jl for Zstd-compressed Arrow IPC buffers

- **Status:** Proposed
- **Date:** 2026-10-20
- **Deciders:** the user, at the phase-1 ★ checkpoint
- **Scope:** ChuiFrames.jl (core dependency)

## Context

The own IPC reader (ADR-0001 rule 10) must decode Zstd-compressed buffers. CodecZstd 0.8.7 has 1
registered dependency plus `Zstd_jll` and supports Julia `[1.6, 2)`. `Zstd_jll` is a standard
library on 1.13.2 and a registered JLL on 1.10.12 (LC-12, [lane-checks.md](../research/lane-checks.md)). It loads in 0.006–0.007 s
([dependencies.md](../research/dependencies.md) DP-01, DP-03) and is already in Arrow.jl 2.8.1's
closure (`CodecZstd = "0.7, 0.8"`), so it adds no package (ADR-0016).

## Decision

ChuiFrames depends on CodecZstd with `CodecZstd = "0.8"`, used only as `ZstdDecompressor` through
TranscodingStreams' `transcode`, with `initialize`/`finalize` per task (ADR-0016).

## Alternatives rejected

| Alternative | Why rejected |
|---|---|
| ChunkCodecLibZstd | Adds packages that are not already in the closure (ADR-0016). |
| Refuse Zstd-compressed files | Polars and pyarrow can write them, so real files would fail to read. |

## Consequences

- A phase-2 test reads a Zstd-compressed IPC file written by pyarrow.

## Verification

DP-01 and DP-03 ([dependencies.md](../research/dependencies.md)); Arrow.jl 2.8.1 `Project.toml`
(ADR-0016).

## Revisit when

- As ADR-0016.
