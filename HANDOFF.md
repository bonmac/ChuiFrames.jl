# Handoff

The one handoff file for this repo. Update it before stopping, before a compaction, and at
every checkpoint. Keep it short; history lives in git and in ADRs.

## State

- **Branch:** `feat/phase3-lazy`, in worktree `.worktrees/phase3-lazy`, from `main` `5896de6`.
  **Not merged**; the lead merges after review.
- **Phase:** phase 3 (lazy engine), first milestone. Spec
  `docs/superpowers/specs/2026-10-20-phase3-lazy-design.md`, plan
  `docs/superpowers/plans/2026-10-20-phase3-lazy.md`.
  - **Part A** (user decisions at the phase-2c ★):
    - `var`/`std` of fewer than two values are `missing`;
    - `group_by(drop = nothing)` inherits the input's flag (breaking);
    - ADR-0002 rule 10 gains the `case_when` line;
    - `frame_equal` is documented as weaker than `isequal`;
    - AirspeedVelocity is documented and not filed.
  - **Part B:**
    - `lazy`/`collect`/`optimize`/`explain`/`code_lowered`, and verbs on a `Source`;
    - the plan IR with the ChuiCore R6 stand-ins;
    - the rule passes under the R-total rule (spec §1);
    - pushdown into `Tables.Scan`, and pruning with the NaN/`missing` rules (sub-lane p3-pred);
    - the streamed stage per morsel, parallel when stateless;
    - a sequential limit with early stop;
    - eager replay of failing runs;
    - the rendered kernel;
    - lazy == eager properties at `-t 1` and `-t 4` (sub-lane p3-prop).
- **Upstream:** unchanged. ChuiCore and ChuiTypes are not released, so the stand-ins stay
  (ADR-0014). The R6 stand-ins (`fmap`, `cata`, `para`, `ana`) mirror ChuiCore main.

## Open lanes

| Lane | Agent | File scope | Status | Report |
|---|---|---|---|---|
| phase3-lazy | the phase-3 lane (lead's teammate) | `src/**`, `ext/**`, `test/**`, `Project.toml`, `docs/**`, `benchmark/**`, `HANDOFF.md`, `changelog.d/phase3-lazy.md`, `.gitignore`, `JuliaTestItems.toml` | in review | to the lead |

Sub-lanes `p3-pred` and `p3-prop` are merged (`--no-ff`, lane audit OK) and their worktrees are
removed; the branches are kept.

## Evidence (`.lanes/evidence/`)

- **Full suites at this HANDOFF commit:**
  - 1.13.2: `tests-<sha>.txt`;
  - 1.10.12 with `CI_STABLE=false`: `tests-lts-<sha>.txt`;
  - `JULIA_NUM_THREADS=4`: `tests-t4-<sha>.txt`.
  - The sha and the counts are in the lane report.
- **Earlier, at `48c7e52`:**
  - 1.13: 8507 pass;
  - LTS: 8469 pass;
  - `-t 4`: 8508 pass.
- **Budgets at `0734789`:**
  - `bench-check-113-0734789.txt` and `bench-check-110-0734789.txt`: 52/52 within budget.
  - Five new `lazy/*` rows come from `bench-11{3,0}-48c7e52.txt`.
- **TTFX at `0734789` (`ttfx-check-113-0734789.txt`):**
  - load 421.1 ms against a 500 ms budget;
  - load plus first call 451.7 ms;
  - load average 8.3–9.0, so this was NOT a quiet machine. The lead re-runs it.
- **Review:** reviewer passes 1 (REQUEST CHANGES), 2 (APPROVE WITH CONDITIONS) and 3 (**APPROVE,
  FINAL**, at `0734789`).

## Decisions at the phase-3 ★ (2026-10-20)

- **Eager replay** is CF-008's exception-type mechanism, including returning the eager result
  when only the lazy run fails. Lead's decision; recorded as a dated note on ADR-0003 rule 7.
- **R-total** is accepted for v0 (user). Moving filters past provably total `mutate`s is a
  later optimization.
- **Grouped summaries and window sinks** are deferred to phase 4 (user).
- **A `-t 4` CI job** is approved (user). The lead makes it as a separate T3 change; this lane
  does not edit CI.
- **Lazy budget rows** follow ADR-0022 rule 2's formula, not rule 3's eager cap (user). Recorded
  as a dated note on ADR-0022 rule 3.

## Phase 4 (and later)

- Hash-aggregate and grouped-window sinks, with parallel partial aggregation (`foldparts`).
  Until then, grouped summaries and windows run on the gathered frame through the eager
  operators.
- The adaptive group-by, radix partitioning, joins, codegen kernels and the 10⁵ threshold.
- Pushing filters past provably total `mutate`s (a later optimization under R-total).
- `source_ordering` is not used to skip sorts yet (ADR-0004 rule 6).
- `test -- all` and ttfx on a quiet machine, both re-run by the lead.

## Next action

The lead's merge (reviewer pass 3: APPROVE, FINAL).
