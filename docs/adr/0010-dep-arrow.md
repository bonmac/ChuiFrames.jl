# ADR-0010: Depend on Arrow.jl to write Arrow IPC

- **Status:** Accepted (2026-10-20, user at the ChuiFrames phase-1 ★)
- **Date:** 2026-10-20
- **Deciders:** the user, at the phase-1 ★ checkpoint
- **Scope:** ChuiFrames.jl (core dependency)

## Context

The brief makes Arrow IPC a built-in format, and ecosystem ADR-0009 §3 makes it the on-disk and
inter-process format. ADR-0001 keeps Arrow.jl out of the in-memory engine and **out of the read
path**: reading is ChuiFrames' own (rule 10), because Arrow.jl 2.8.1 reads Polars files as empty
tables (LC-04) and has dictionary bugs (ST-04, #610). Arrow.jl still writes the layouts ChuiFrames
needs correctly; pyarrow reads them (ST-12). Out-of-core spilling (ADR-0003 rule 16) writes Arrow
IPC too, so the writer must be in the core.

Arrow.jl 2.8.1 (2026-01-14) supports Julia `[1.9, 2)`. It has 13 direct and 28 transitive
registered dependencies; Tables, DataAPI, PrecompileTools, StringViews and Compat are already in
the core closure, so the marginal cost is smaller (DP-02). `using Arrow` takes 0.15–0.17 s on
1.13.2 and 0.24–0.31 s on 1.10.12 (DP-03, DP-04, [dependencies.md](../research/dependencies.md)).
It caps StringViews and InlineStrings at 1.x (DP-08).

Its writer, read from source:
- writes a dictionary only when `DataAPI.refarray(x) !== x`;
- assumes the codes start at 1;
- always writes `isOrdered = false`;
- takes the schema from the first partition only.

## Decision

1. ChuiFrames depends on Arrow with `Arrow = "2.8"`, for **writing only**.
2. Every call goes through one internal writer adapter, which **must** meet these rules
   (ADR-0001 rule 11):
   - every partition is given the same declared schema;
   - dictionary columns expose 1-based `refarray`;
   - strings are written as Utf8 or LargeUtf8;
   - the file format is the default; the stream format is for spills, append and `.arrows`
     paths (ADR-0004 rule 7);
   - every write goes to a temporary path that is renamed on commit, and is deleted on abort.
3. Arrow.jl's reader is not used by `src/`. Tests use it as a cross-check.
4. A PrecompileTools workload includes one small write. That this moves the writer's first-call
   compilation to precompile time is UNVERIFIED and is measured with the TTFX budget.

## Alternatives rejected

| Alternative | Why rejected |
|---|---|
| Arrow.jl for reading too | Silent wrong results: an empty table from a Polars file (LC-04), and wrong dictionaries (#610, ST-04). ADR-0001 rule 10. |
| Arrow IPC as a package extension (Arrow in `[weakdeps]`) | Would save about 13 packages for users who never write Arrow: ArrowTypes, BitIntegers, ConcurrentUtilities, EnumX, ExprTools, InlineStrings, Mocking, PooledArrays, RecipesBase, Scratch, SentinelArrays, TZJData and TimeZones. The other 15 of its 28 are core anyway (storage critic's count from DP-02). The load-time saving is not measured separately. But it contradicts the brief's "built in", and spilling (ADR-0003 rule 16) needs the writer in the core. Offered to the user as a ★ question with that cost stated. |
| Our own writer in v0 | The read side already carries the own-format work. Arrow.jl writes correctly, and moving in-house later is a change inside the adapter only. |

## Consequences

- The writer adapter needs regression tests: a fixed schema across morsels where the first has
  no nulls, 1-based codes, and pyarrow reading the output back.
- Arrow.jl's compat keeps StringViews at 1.x (ADR-0009).

## Verification

- DP-02 to DP-04 and DP-08 in [dependencies.md](../research/dependencies.md).
- ST-04, ST-12 and ST-13 in [storage.md](../research/storage.md).
- LC-04 in [lane-checks.md](../research/lane-checks.md).
- The writer facts come from Arrow.jl 2.8.1's source (`write.jl`, `dictencoding.jl`,
  `arraytypes.jl`), as read by the storage critic.

UNVERIFIED: whether the precompile workload absorbs the first-write compilation.

## Revisit when

- Arrow.jl 3.0 is released.
- Measured TTFX with Arrow exceeds the budget (reconsider the extension option).
