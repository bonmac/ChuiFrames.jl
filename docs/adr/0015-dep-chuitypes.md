# ADR-0015: Depend on ChuiTypes only when async I/O or the stream source needs it, from a release

- **Status:** Accepted (2026-10-20, user at the ChuiFrames phase-1 ★)
- **Date:** 2026-10-20
- **Deciders:** the user, at the phase-1 ★ checkpoint
- **Scope:** ChuiFrames.jl (core dependency, deferred)

## Context

ChuiTypes owns the one effect runtime and the conversions to and from it (ecosystem ADR-0009 §4;
the obligations in `chui-types.md`), and its streams are to become a ChuiFrames source whose adapter
lives in ChuiFrames (ecosystem ADR-0002 §1). All of its API is PROVISIONAL; only CT-003 (no Base
collisions) is a stable entry. ChuiFrames needs ChuiTypes for (a) asynchronous source reads
(ADR-0003 rule 15) and (b) the stream source (ADR-0004 rule 5). Neither is needed before phase 5.

## Decision

1. ChuiFrames adds no ChuiTypes dependency in phases 2–4. Asynchronous reads go through an
   internal effects adapter using plain `Task`s, with the semantics of ChuiTypes' conversion
   obligations: a failing task surfaces its original exception (ADR-0003 rule 7), and
   cancellation is **cooperative**, through a flag that tasks check between morsels, because
   Base has no task-cancellation API (critic probe P4). ChuiFrames defines no effect type of its
   own.
2. **The request is filed when the shim is created** (`chui-types.md` allows a shim only while
   its request is open). It asks for the runtime's run/cancel entry points, the Task and
   Channel conversions, and the public stream API the source adapter needs (draft in the phase
   report).
3. When ChuiTypes has released those pieces, ChuiFrames adds `ChuiTypes = "0.0.x"`, routes the
   effects adapter through the runtime, ships the stream adapter as a bounded source first
   (ADR-0004 rule 5), lists the CT IDs it relies on and adds their contract tests.
4. **v0.1.0 without ChuiTypes needs the user.** The brief puts asynchronous I/O through
   ChuiTypes effects in phase 5, before v0.1.0. If ChuiTypes has not released the runtime by the
   end of phase 5, the lead takes the choice to the user at a ★: release on the `Task` shim, or
   wait.

## Alternatives rejected

| Alternative | Why rejected |
|---|---|
| Depend on ChuiTypes from phase 2 | Nothing before phase 5 uses it, and its API is PROVISIONAL; the dependency would add load cost with no use. |
| Own effect/future type in ChuiFrames | Violates the one-runtime obligation (ecosystem ADR-0009 §4). |
| A ChuiTypes extension on ChuiFrames for the stream source | Forbidden by ecosystem ADR-0002 §1 (the adapter lives downstream). |

## Consequences

- Phases 2–4 have no ChuiTypes contract tests; `test/contracts/USED.md` lists no CT IDs until rule 3.

## Verification

Design decision derived from the brief, ecosystem ADR-0002 §1, ADR-0009 §4 and `chui-types.md`.

## Revisit when

- ChuiTypes releases its effect runtime or stream API.
- An earlier phase turns out to need asynchronous I/O (e.g. HTTP/S3 sources move earlier).
