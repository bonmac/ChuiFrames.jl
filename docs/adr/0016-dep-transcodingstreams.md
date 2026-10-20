# ADR-0016: Depend on TranscodingStreams.jl for buffer decompression in the IPC reader

- **Status:** Proposed
- **Date:** 2026-10-20
- **Deciders:** the user, at the phase-1 ★ checkpoint
- **Scope:** ChuiFrames.jl (core dependency)

## Context

ADR-0001 rule 10 makes the Arrow IPC reader ChuiFrames' own. It must decompress buffers written
with LZ4-frame or Zstd compression. Arrow.jl 2.8.1, a core dependency (ADR-0010), already
depends on TranscodingStreams (`0.9.12, 0.10, 0.11`), CodecLz4 (`0.4`) and CodecZstd (`0.7, 0.8`).
It uses their `LZ4FrameDecompressor` and `ZstdDecompressor` (its `Arrow.jl` source, lines 83–109),
so these packages add **no new package** to the closure. TranscodingStreams 0.11.3 has no
registered dependencies, supports Julia `1`, and loads in 0.002 s (DP-01, DP-03,
[dependencies.md](../research/dependencies.md)).

## Decision

ChuiFrames depends on TranscodingStreams with `TranscodingStreams = "0.11"` (after checking that
this compat co-resolves with Arrow.jl's, which it admits). It decompresses whole buffers with one
codec object per task, never shared between tasks. Each codec object **must** be set up with
`TranscodingStreams.initialize` and released with `finalize` in a `try`/`finally`, as Arrow.jl
does. Alternatively the type form `transcode(LZ4FrameDecompressor, bytes)` is used, which manages
its own codec. The reason: `transcode(codec, bytes)` "does not initialize or finalize `codec`"
(its docstring), and an LZ4 decompressor that was never initialized throws `LZ4F_dctx:
Uninitialized decompression context` (LC-10).

## Alternatives rejected

| Alternative | Why rejected |
|---|---|
| ChunkCodecLibLz4 / ChunkCodecLibZstd 1.0 (whole-buffer API; LZ4 frame and Zstd round-trip verified in scratch) | Three packages new to the closure (ChunkCodecCore plus two codec libraries), where the TranscodingStreams codecs come free with Arrow.jl. Revisit if Arrow.jl is dropped. |
| Calling Arrow.jl's internal decompressors | Internal API, and it may change in 3.0. |
| No compression support | Polars and pyarrow can write compressed IPC. Reading would fail on real files. |

## Consequences

- If Arrow.jl ever leaves the core (ADR-0010's ★ alternative), these three dependencies become
  marginal costs and this ADR is revisited.

## Verification

- DP-01 and DP-03 in [dependencies.md](../research/dependencies.md).
- Arrow.jl 2.8.1's `Project.toml` and its `Arrow.jl` source file (codec setup at lines 83–109),
  read in the installed package by the lane owner and the I/O critic.
- LC-10 in [lane-checks.md](../research/lane-checks.md) (the LZ4 `initialize` failure).
- The ChunkCodec round-trip ran in the lane owner's scratch environment:
  `LZ4FrameCodec roundtrip true`, `ZstdCodec roundtrip true`.

## Revisit when

- Arrow.jl leaves the core, or Arrow.jl 3.0 drops these codecs.
