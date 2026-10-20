# ADR-0012: Depend on the Statistics standard library for reductions

- **Status:** Proposed
- **Date:** 2026-10-20
- **Deciders:** the user, at the phase-1 ★ checkpoint
- **Scope:** ChuiFrames.jl (core dependency, standard library)

## Context

CF-004's reductions include `mean`, `median`, `std`, `var` and `quantile`, which live in
Statistics, not Base. A plain call `mean(c.x)` must build a node, so ChuiFrames adds methods to
`Statistics.mean` and the rest, taking a ChuiFrames node (no piracy, CF-009). The prototype does the same
(DESIGN §1). Statistics carries a package version on both supported Julias: 1.10.0 is bundled
with 1.10.12, and 1.11.2 with 1.13.2. None of its exports is also a Base export (LC-03,
[lane-checks.md](../research/lane-checks.md)). It is also registered, and a scratch environment
with `Statistics = "1"` on 1.13.2 resolved 1.11.5 from the registry (grammar critic).

## Decision

ChuiFrames depends on Statistics with `Statistics = "1"` (CI tests whichever version resolves,
bundled or registered), extends `Statistics.mean`, `median`,
`std`, `var` and `quantile` for nodes, and does not re-export Statistics (users write
`using Statistics`, as with vectors).

## Alternatives rejected

| Alternative | Why rejected |
|---|---|
| Own `mean`/`std` functions | A second `mean` binding hides Statistics' for users of both (LC-01 mechanism). |
| A package extension on Statistics | Workable for the `mean(c.x)` grammar: users load Statistics to get `mean` at all, and that load would trigger the extension. Rejected for two reasons. First, ChuiFrames' own core code calls Statistics: the `describe`/summary verb (tibble/skimr-style column summaries) and the eager `median`/`quantile` evaluation. With an extension those verbs would fail until the user happened to load Statistics. Second, the optimizer's table that maps `Statistics.mean`/`var`/`std` nodes to ChuiCore's `Mean`/`Moments` aggregators (ecosystem ADR-0009 §5) needs the function identities. Statistics is a standard library, so there is little load to save. |
| Re-export Statistics' names | Changes what `using ChuiFrames` brings into scope beyond the frame grammar. Users already know to load Statistics. |

## Consequences

- No package beyond Statistics itself (bundled, or registered 1.11.x) enters the closure.

## Verification

LC-03 ([lane-checks.md](../research/lane-checks.md)).

## Revisit when

- Statistics moves out of the default system image in a way that changes its load cost.
