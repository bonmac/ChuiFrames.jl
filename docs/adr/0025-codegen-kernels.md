# ADR-0025: Streamed stages compile into closure-composed kernels for a whitelist of steps and nodes, with the interpreter as the exact fallback; a new shape compiles from 5×10⁵ estimated rows

- **Status:** Proposed (2026-10-26). **Open condition:** quiet-machine `ttfx.jl --check` and
  `run.jl --check` timings on the integrated `feat/phase4`, 1.13 and 1.10, before it merges
  into main.
- **Date:** 2026-10-26
- **Deciders:** the lead (design, spec §3; the threshold from lane p4-codegen's measurements);
  acceptance of this record, including the change to ADR-0003 rule 12: the ecosystem lead or
  the user
- **Scope:** ChuiFrames.jl

## Context

ADR-0003 rule 12 compiles each fused stage into one shape-keyed kernel by composing closures,
runs the interpreter below 10⁵ estimated rows or when the stage is deeper than 50, and asks
phase 4 to recalibrate 10⁵. Its basis: 3–9 ms per two-operation closure shape (EN-07), 18 ms at
depth 20 (EN-08). The design is spec
`docs/superpowers/specs/2026-10-26-phase4-joins-groupby-codegen-design.md` §3; this ADR records
it as built on `feat/phase4` at 50dbf18 (p4-codegen 3a61c69, p4-gbfix 50dbf18). The full kernel,
with critic B2/N3's exactness checks, costs 18–45 ms per new 1–10-step shape
(docs/research/codegen-phase4.md). Code: src/lazy/{kernels,kernels_build,execute}.jl.

## Decision

1. **Construction.** A kernel **must** be a composition of small callable structs whose types
   encode the shape, literals held as fields, one fused row loop per stage. It **must not** use
   `eval`, `invokelatest` or RuntimeGeneratedFunctions (rule 12), nor `@generated` (spec §3.3).
2. **Whitelist.** Only `FilterStep`, elementwise `MutateStep`, `SelectStep`, `RenameStep`,
   `RenameWithStep` and `RelocateStep`, over `Col`, scalar `Lit`, `Call` and `CaseWhen`, may
   compile. A stage with any other step (`ProbeStep`, a windowed `mutate`) or node **must** be
   decided as the interpreter before any shape key or hash is built, writing nothing to the
   cache (`_offwhitelist`). Then, with the schema, a type check: concrete (or
   `Union{Missing, T}`) static types, no string-valued computed column.
3. **Exactness.** The kernel **must** evaluate every filter conjunct and every `case_when`
   condition, value and default on every row (no short-circuit), and scalar-only
   subexpressions once per morsel even when no row is left. On any exception except
   `InterruptException` (rethrown at once) it re-runs the morsel through `interpret_stage` and
   raises the interpreter's exception; if the interpreter succeeds, its result is used and
   `_KERNEL_DISAGREE` is incremented.
4. **Decline path.** When a computed value's type differs from the declared static type (e.g.
   `/` on `Int` columns, which `typed_column` narrows back), the kernel hands the morsel to the
   interpreter and marks that shape and column types rejected for the session. Decided by
   types, so it is not a disagreement. A program that fails to build is marked rejected too.
5. **Column kinds (critic N3).** Passed-through, renamed and filtered columns **must** keep their
   column object (the input column, or `take` of it), so a `DictColumn` keeps its levels.
   Computed columns are `column(values)`, equal to `typed_column` for values of the declared
   type (reviewer m8, accepted). A probe check compares `typeof(col)` per output column against
   the interpreter once per compile.
6. **Decision.** `kernel_decision(ph, est_rows)` serves `collect` and `explain`. Forced by
   `_FORCE_KERNEL` (an unknown value is an `ArgumentError`); otherwise compiled when the shape
   is cached, or when `est_rows ≥ INTERP_THRESHOLD = 500_000`; unknown rows compile only when
   cached. A stage with more than `MAX_KERNEL_NODES = 50` operations (`Call` and `case_when`
   nodes summed over its steps) runs the interpreter. **This replaces both of ADR-0003 rule 12's
   criteria**: 10⁵ becomes 5×10⁵, and "deeper than 50" becomes "more than 50 operations".
7. **Small inputs** (below the threshold, or unknown) **must not** build, probe or format
   anything: with nothing compiled in the session they return at once; otherwise they look up
   an allocation-free shape hash (`_KERNEL_SMALL`) that includes a non-frame source's declared
   schema. A collision can only compile early; each morsel's program is checked under its exact key.
8. **One precompile workload.** A forced compiled lazy `collect` sits inside the package's single
   `@compile_workload` (src/ChuiFrames.jl), mirrored in `benchmark/ttfx.jl` (ADR-0022 rule 4).
   There **must** be no second workload.
9. `explain(q; kernel = true)` prints the decision line; off by default, so goldens do not depend
   on the session cache. `code_lowered` and the rendered kernel are unchanged (rule 13).

## Alternatives rejected

| Alternative | Why rejected |
|---|---|
| Keep 10⁵ | The full kernel costs 18–45 ms per new 1–10-step shape; at 10⁵ rows almost every new shape loses. |
| 10⁶ or higher | Five-to-ten-step stages and `case_when` break even at 1.6–2.8×10⁵ rows; they would run interpreted for no gain. |
| Keep "depth > 50" | Depth misses long flat stages (60 one-operation mutates are depth 1), while compile time grows with the operation count (research: a 50-operation chain costs 175–227 ms; flat stages measured only to 10 steps, so the flat case is UNVERIFIED beyond that). |
| `eval`/RGF/`@generated` | Recompiles per literal, slow at depth (rule 12); world-age hazards. |
| Short-circuit `case_when`/conjuncts | Critic B2: other rows evaluated, other exceptions than eager. |
| Rebuild passed-through columns from values | Critic N3: a `DictColumn` loses its levels; `group_by(drop = false)` changes. |
| Compile a prefix before a non-whitelisted step | Two kernels and a hand-off per stage; deferred (spec §6). |

## Consequences

- Below 5×10⁵ rows a new shape runs interpreted the first time; once compiled, every later run
  of it is compiled at any size. Late-break-even shapes (one step, string filters) lose at most
  about 15 ms once at 5×10⁵ rows; 20–50-operation chains break even at 3–7×10⁶.
- **The n=10 allocation breach:** the small-input lookup first hashed through dynamically
  dispatched helpers and pushed `lazy/filter, mutate, select/n=10` over its ADR-0022 allocation
  and memory budgets on 1.13 and 1.10; f946f0d mixes into one accumulator, within budget on both.
- ADR-0003 rule 12 still reads 10⁵ and depth 50 until a dated note points here (text in the
  architect report, for the lead at acceptance; ADR-0003 notes are added at a ★).
- Follow-ups: no kernel for a prefix before a join probe; the renderer ignores `before`/`after`;
  the research note still lacks the proxy-compile-time caveat (reviewer pass 2 n2).

## Verification

- Threshold: docs/research/codegen-phase4.md; evidence (main checkout, gitignored,
  `dirty: false`) `.lanes/reports/lanes/p4-codegen/evidence/codegen-measure-fe71780.txt` and
  `codegen-measure-lts-fe71780.txt`. Caveats: `-t 1` only; a shared machine at 1-minute load
  2.6–3.3; the named stages (multi-column, string, `case_when`) reuse the 2-step family's
  compile median as a proxy (reviewer m4).
- Allocation breach and fix: `bench-check-113-54a1b20.txt`, `bench-check-110-54a1b20.txt`
  (FAILED) against `bench-check-113-f946f0d.txt`, `bench-check-110-f946f0d.txt` (OK), same directory.
- Reviewers (main checkout `.lanes/reports/`): `reviewer-p4-codegen.md`,
  `reviewer-p4-codegen-pass2.md` (APPROVE FINAL at f946f0d), `reviewer-p4-gbfix-pass2.md`
  (whitelist-first and the schema-aware small hash; the `ProbeStep` path read, not run).
- UNVERIFIED until the open condition: TTFX and timings. `.lanes/reports/ttfx-p4-codegen.md`
  (this worktree) measured lane commit 01ad475 only, 1.13 only, at load 8–12: inconclusive,
  with the load median at 450.7 ms against the 500 ms budget.

## Revisit when

- `_KERNEL_DISAGREE` is ever non-zero in CI → interpreter by default until fixed.
- The median per-shape compile time of 1–10-step stages halves or doubles, the interpreter's
  per-step cost moves by more than 2×, or p4-bench's compiled-stage row disagrees with the
  research table by more than 2× → recompute `INTERP_THRESHOLD`.
- A multi-threaded measurement moves the median break-even outside 2.5–10×10⁵ rows.
- The quiet-machine TTFX run breaches ADR-0022 rule 4 → shrink the workload or the machinery.
