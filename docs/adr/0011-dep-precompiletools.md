# ADR-0011: Depend on PrecompileTools.jl for TTFX workloads

- **Status:** Accepted (2026-10-20, user at the ChuiFrames phase-1 ★)
- **Date:** 2026-10-20
- **Deciders:** the user, at the phase-1 ★ checkpoint
- **Scope:** ChuiFrames.jl (core dependency)

## Context

The ecosystem rules ask for PrecompileTools workloads with measured TTFX (`ECOSYSTEM.md` §1.7). The
engine compiles a kernel per plan shape (ADR-0003 rule 12). Arrow.jl's first *read* costs about
1 s of compilation (ST-14); its first-write cost was not measured, and ChuiFrames uses only its
writer (ADR-0010). PrecompileTools 1.3.4 requires Julia ≥ 1.12; on 1.10.12 the
resolver picks 1.2.1, so `PrecompileTools = "1"` resolves on both (DP-04, DP-07,
[dependencies.md](../research/dependencies.md)). One registered dependency (Preferences), load
≤ 0.021 s.

## Decision

ChuiFrames depends on PrecompileTools with `PrecompileTools = "1"` and has one
`@setup_workload`/`@compile_workload` block covering: building a small frame, the core verbs
(`filter`, `mutate`, `group_by ⨟ summarise`, `arrange`), a lazy `collect` and `explain`, printing,
and one CSV and one Arrow IPC round trip on a tiny file (ChuiFrames' own IPC reader plus the
Arrow.jl writer). The Parquet2 extension carries its own workload. TTFX is measured with and
without the workloads on stable and LTS.

## Alternatives rejected

| Alternative | Why rejected |
|---|---|
| No precompile workload | Every session pays first-call compilation of the engine and Arrow reader. |
| `precompile(...)` statements by hand | Brittle; PrecompileTools is the documented, ecosystem-wide mechanism. |

## Consequences

- On 1.10 the resolved version differs (1.2.1 vs 1.3.x); CI on LTS covers it.

## Verification

DP-01, DP-04, DP-07 ([dependencies.md](../research/dependencies.md)).

## Revisit when

- The LTS moves to ≥ 1.12 (raise the compat floor to `1.3`).
