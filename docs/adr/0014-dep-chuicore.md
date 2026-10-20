# ADR-0014: Depend on ChuiCore through one internal adapter, switching each piece when ChuiCore releases it

- **Status:** Accepted (2026-10-20, user at the ChuiFrames phase-1 ★)
- **Date:** 2026-10-20
- **Deciders:** the user, at the phase-1 ★ checkpoint
- **Scope:** ChuiFrames.jl (core dependency)

## Context

Ecosystem ADR-0002 assigns ChuiCore four things ChuiFrames needs: the `⨟` binding (CC-001,
CC-002), the aggregation protocol and built-in aggregators (CC-004 to CC-007), the transducer
substrate, and recursion schemes. It also owns the name-conflict banner. The last three, the
transducer names and the export list are PROVISIONAL (`chui-core.md`). ChuiCore is not released.
The brief says to adopt upstream APIs only from tagged releases and to keep a small internal
adapter until then, so switching is one change. ADR-0004 of the ecosystem makes 0.0.x compat name
exact tested snapshots.

## Decision

1. **Before ChuiCore's first release**, ChuiFrames has no ChuiCore entry in `[deps]`. One
   internal module (the *upstream adapter*) defines **stand-ins**, named and shaped as in
   ChuiCore's accepted ADRs (accepted at its ★, 2026-10-20):
   - **Aggregators as instance values** (ChuiCore ADR-0001): `init`, `partial`, `combine(agg, a, b)`
     (always 3 arguments), `final`, `iscommutative`, and `neutral(agg)` returning a fresh value on
     every call. The built-in aggregators the engine uses, and `aggregate(agg, xf, parts)`.
   - **Transducers as immutable structs** (ChuiCore ADR-0003): `Map`, `Filter`, `MapCat`, `Take`
     and the others, plus `start`/`next`/`complete`, `Reduced`, `asrf`, `foldxl`,
     `foldparts(…; init, merge)`, `foldxt`, and a fail-closed `isstateless`.
   - The **recursion-scheme** functions the optimizer needs (`cata`, `ana`, a paramorphism).
   - `⨟`/`opcompose` semantics.

   ChuiCore makes all of these **public but not exported**, except `⨟`, `opcompose`, `neutral` and
   `papply` (ChuiCore ADR-0005). So ChuiFrames code writes them qualified, through the adapter
   (`Upstream.combine` now, `ChuiCore.combine` after the switch). No other ChuiFrames file
   defines or imports these names except through the adapter (ADR-0003 rules 4–6 and 14).
2. **Stand-ins never become public API.** ChuiFrames must not export them. In particular it
   must not export a `⨟` binding of its own, which would clash with ChuiCore's (LC-01 mechanism).
   ChuiFrames is released only after ChuiCore (ecosystem ADR-0002, release order), so no release
   of ChuiFrames ever lacks `⨟`. Before that, internal tests compose steps through the adapter.
   From the switch on, ChuiFrames **re-exports ChuiCore's `⨟` binding** (the same binding, so it
   never conflicts), and `using ChuiFrames` alone is enough for CF-007. It re-exports no other
   ChuiCore name. In particular it never exports `combine`, which DataFrames also exports
   (ChuiCore ADR-0005's clash list).
3. **At ChuiCore's first release**, ChuiFrames adds `ChuiCore = "0.0.x"` (the exact snapshot).
   It replaces with `const` re-bindings to ChuiCore's names every stand-in whose piece that
   release contains; the others follow rule 4. It adds methods to `ChuiCore.:⨟` for `Step`s,
   lists the IDs it relies on in
   `test/contracts/USED.md` (CC-001, CC-002, CC-004, CC-005, CC-006, CC-007, CC-010 at least) and
   adds one `:contract` test item per ID.
4. **Missing pieces go to ChuiCore as requests** (ecosystem ADR-0010 rule 3), not as permanent
   local copies. The requests are filed **when the stand-in is created**: a recursion-scheme API
   that fits a plan functor (including a paramorphism); the transducer substrate's names;
   `missing`-aware aggregator variants if ChuiCore wants to own them (CC PROVISIONAL); the
   conflict banner. Each stand-in switches when **its own** piece is released, not at
   ChuiCore's first release as a whole.
5. **Release gate.** ChuiFrames' `/release-check` **must** fail while any adapter body is still
   a local stand-in for a piece ChuiCore owns. If ChuiCore declines a request, the lead raises it
   as an ecosystem ADR (escalation to the user). ChuiFrames must not keep the local copy and
   release anyway.

## Alternatives rejected

| Alternative | Why rejected |
|---|---|
| `Pkg.develop` ChuiCore by path now | Ecosystem ECOSYSTEM.md §2: no committed develop paths; a fresh clone must test alone. |
| Permanent local copies of the protocol | Ecosystem ADR-0002: two copies drift; ChuiCore owns them. |
| Wait for ChuiCore before writing any engine code | Blocks phases 2–3; the brief explicitly asks to design behind adapters. |

## Consequences

- The adapter's stand-ins must pass the same law tests ChuiCore's will (CC-004's thunks and
  tolerances), so the switch cannot change results.
- Unreleased development builds have no user-facing `⨟`. Documentation examples that use it
  run only after the switch.

## Verification

Design decision derived from the brief (Independence), ecosystem ADR-0002, ADR-0004 and ADR-0010,
and `chui-core.md`; LC-01 ([lane-checks.md](../research/lane-checks.md)) for the binding clash.
ChuiCore's ADR-0001, ADR-0003 and ADR-0005 (Accepted 2026-10-20, in ChuiCore's main
`docs/adr/`), as relayed by the lead and read by the lane owner.

## Revisit when

- ChuiCore tags its first release, or its phase-1 ADRs change a name used here.
