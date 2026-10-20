# ADR-0018: Depend on CodecLz4.jl for LZ4-frame-compressed Arrow IPC buffers

- **Status:** Proposed
- **Date:** 2026-10-20
- **Deciders:** the user, at the phase-1 ★ checkpoint
- **Scope:** ChuiFrames.jl (core dependency)

## Context

Arrow IPC's other buffer compression is the LZ4 frame format, which the own reader (ADR-0001
rule 10) must decode. CodecLz4 0.4.6 is the line Arrow.jl 2.8.1 requires (`CodecLz4 = "0.4"`).
Arrow.jl uses its `LZ4FrameDecompressor` (Arrow.jl source, lines 85–109; `initialize` at line 108), so it is already in
the closure (ADR-0016). Its dependencies are `Lz4_jll` and TranscodingStreams, and it supports
Julia `1.3.0-1` for the 0.4 line (the lane owner's read of the General registry, confirmed by the
I/O critic). `@time using CodecLz4` takes 0.024–0.036 s on 1.13.2 and 0.025–0.041 s on 1.10.12
(LC-12, [lane-checks.md](../research/lane-checks.md)).

## Decision

ChuiFrames depends on CodecLz4 with `CodecLz4 = "0.4"`, used only as `LZ4FrameDecompressor`
through `transcode`, with `initialize`/`finalize` per task (ADR-0016).

## Alternatives rejected

| Alternative | Why rejected |
|---|---|
| ChunkCodecLibLz4 (its `LZ4FrameCodec` round-trips) | Adds packages that are not already in the closure (ADR-0016). |
| Refuse LZ4-compressed files | pyarrow writes LZ4-frame IPC, so real files would fail to read. |

## Consequences

- A phase-2 test reads an LZ4-compressed IPC file written by pyarrow.

## Verification

- Arrow.jl 2.8.1 `Project.toml` and its `Arrow.jl` source file (installed package).
- The local General registry's `C/CodecLz4` entry (lane owner), and LC-12 (load time on both
  Julia versions).
- LC-10 (the decompressor needs `initialize`).

## Revisit when

- As ADR-0016.
