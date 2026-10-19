<!-- vendored contract: coordinator commit 275e879, contracts/chui-types.md, copied 2026-10-19 -->
# Contract: chui-types (v0)

> **DRAFT: not binding.** This contract becomes binding when ADR-0002, ADR-0004, ADR-0007,
> ADR-0009 and ADR-0010 are Accepted at the L0 ★. Until then no downstream relies on it and its
> entries may change without a contract ADR (see [README.md](README.md), "Drafts").

- **Owner:** ChuiTypes. **Consumers:** ChuiFrames, and future Chui packages.
- **Contract version:** v0, describing ChuiTypes 0.0.1 (unreleased).
- **Sources:** ADR-0002 §1, §2 (placement), ADR-0009 §4, §6, §7, ADR-0010 (format).
- **Format:** see [README.md](README.md). Version 0 has one stable entry, CT-003. None of
  ChuiTypes' API is decided yet, so its types, effect runtime, futures and streams are
  [PROVISIONAL](#provisional), and the ecosystem's effect rules are **obligations**, not entries:
  they have no IDs and no contract tests until the runtime's names are accepted. CT-001 and CT-002
  were withdrawn before the contract became binding (`status=retired`); their IDs are not reused.

## Obligations (not entries)

No IDs and no contract tests (a test would need the PROVISIONAL runtime names). Each becomes an
entry with the next free ID, and a `test:` line, when ChuiTypes' ADR accepts the names it needs.
They bind the ecosystem's design now through ADR-0009 §4 and ADR-0002 §2.

**One effect runtime, owned by ChuiTypes** (was CT-001).
- ChuiTypes defines **exactly one effect runtime**: the single place where effectful
  computations are interpreted (run, scheduled, cancelled, and their resources released). It
  provides environment, error and success channels, resource safety, and structured concurrency
  on Julia `Task`s with cancellation that propagates (brief 20).
- Every other effect-like type in the ecosystem (lazy IO values, futures, Task-like values,
  ChuiTypes streams) is **run by converting it to that runtime**. None has its own scheduler or
  cancellation machinery.
- ChuiFrames' asynchronous I/O and any future package's side effects run on this runtime. A
  downstream package does not define a second effect runtime; if it needs one, it files a request
  (`requests/`, ADR-0010) instead.
- ChuiCore only *documents* purity and effect conventions; it ships no runtime (ADR-0009 §4).
- Future test, once named: every effect-like value a downstream produces for async work is, or
  converts to, the runtime's effect type and runs through its run function; cancelling it through
  the runtime cancels the underlying `Task`.

**Conversions to and from the runtime live in ChuiTypes** (was CT-002).
- The adapters between the runtime's effect type and other effect-like values (plain `Task`,
  `Channel`, thrown exceptions, ChuiTypes' own lazy IO values, futures and streams) are defined
  **in ChuiTypes**, not downstream.
- Semantics every adapter keeps:
  - *Task → effect:* running the effect runs the task (once) and succeeds with `fetch(task)`'s
    value; if the task fails, the effect fails with the task's exception in its error channel,
    not as a thrown `TaskFailedException`.
  - *Effect → Task:* the task's result is the effect's success value; an effect failure is thrown
    from `fetch` as the original exception; cancelling the effect stops the task.
  - *Exceptions:* a thrown exception inside an effect becomes a value in the error channel;
    converting back rethrows the same exception object.
  - *Channel ↔ effect/stream:* closing the channel ends the stream; an exception closing the
    channel becomes a stream failure.
  - *Round trip:* converting to the runtime and back gives a value that behaves as the original
    (same result, same failure, same cancellation).
- A downstream package that needs an adapter for another effect-like type requests it from
  ChuiTypes (ADR-0010 rule 3); an internal shim is allowed only while that request is open.
- Future test, once named: round-trips a successful `Task`, a failing `Task` (the exception object
  is preserved) and a `Channel` (closing ends the stream) for each conversion the downstream uses.

Illustrative shape only (every name is a placeholder; parsed, never run):
```julia
using ChuiTypes
eff = ChuiTypes.from_task(@task read("data.csv", String))   # Task → the runtime's effect type
res = ChuiTypes.run(eff)                                   # run on the one runtime
```

---

### CT-001 One effect runtime, owned by ChuiTypes
`since=0.0.1 status=retired`

Withdrawn before the contract became binding (critic review S4, 2026-10-19): it could only be
tested with PROVISIONAL names. Now the first obligation above. The ID is not reused.

### CT-002 Conversions to and from the runtime live in ChuiTypes
`since=0.0.1 status=retired`

Withdrawn before the contract became binding (critic review S4, 2026-10-19), for the same reason.
Now the second obligation above. The ID is not reused.

### CT-003 No exported name collides with Base, Core or a standard library
`since=0.0.1 status=stable`

**Statement.** For every name `n` exported by ChuiTypes: if Base, Core or a standard-library
module exports `n`, ChuiTypes' binding **is** that module's (it only adds methods, each
dispatching on a type ChuiTypes owns). In particular ChuiTypes does **not** export new bindings
named `IO`, `Task`, `Ref` or `Some`, which are **exported by Base or Core** on every supported
Julia: on 1.10 `IO`, `Task` and `Ref` are Core's exports and not Base's, on 1.13 both export
them (E-34). Brief 20's `IO` and `Task` types get other names in ChuiTypes' ADR. This is
ADR-0009 §6, the same rule as CC-010 and CF-009.

**Example** (Base only):
```julia
reserved = (:IO, :Task, :Some, :Channel, :Ref, :identity, :map, :filter)
all(n -> Base.isexported(Base, n) || Base.isexported(Core, n), reserved)   # -> true
```

test: `CT-003 no Base collisions` — runs CC-010's collision check over ChuiTypes' exports
against Base, Core and every loaded standard library (at least `Statistics`, `LinearAlgebra`,
`Dates`, `Random`, `Test`), and explicitly checks that `IO`, `Task`, `Ref` and `Some`, if
exported, are the Base/Core bindings.

---

## PROVISIONAL

No IDs and no contract tests. Each item gets an ID when ChuiTypes' ADR accepts it (ADR-0010).

- **Data types:** `Option`/`Maybe`, `Either`/`Result`, `Validation`, `These`, `NonEmpty`,
  `LazyList`, `Reader`, `Writer`, `State`, and the IO type (which needs a non-Base name, CT-003);
  their type-stable encoding; which ChuiCore typeclasses each implements (depends on ChuiCore's
  PROVISIONAL trait encoding) and which law kits they pass.
- **The effect runtime's API:** the effect type's name and parameters (environment, error,
  success), `run`-style entry points, resource safety (`bracket`/`Scope`), retries and schedules,
  timeouts, fibers vs `Task`s, cancellation semantics, and the environment mechanism
  (`Base.ScopedValues` / the ScopedValues.jl backport on 1.10, ADR-0006).
- **The adapter names** behind the conversion obligation (`from_task` and similar above are
  placeholders).
- **Futures:** Fluture-style lazy, cancellable futures; the Folktale/Monet-style Task-like type
  (which needs a non-Base name, CT-003).
- **Streams:** push vs pull, backpressure, cold/hot observables, the operator set, schedulers and
  the virtual-time test scheduler.
- **Stream as a ChuiFrames `Source`.** *Placement is decided* (ADR-0002 §1): the adapter lives in
  **ChuiFrames itself**, using only ChuiTypes' public stream API; ChuiTypes ships **no** extension
  on ChuiFrames. *Still open:* the adapter's API, which depends on `chui-frames.md`'s PROVISIONAL
  Source interface and its bounded-vs-streaming choice (ADR-0009 §7, ADR-0010 rule 6), and which
  stream operations ChuiTypes must make public for it.
- **Pre-0.1 dependency form** for ChuiTypes on ChuiCore: `0.0.x` snapshots (ADR-0004 rule 2,
  recommended) versus brief 20's `v0.1.0-DEV` (★ the user's decision).
