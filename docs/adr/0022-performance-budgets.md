# ADR-0022: ChuiFrames' performance budgets: per-entry time and allocation budgets, a load-plus-first-call budget, informational targets against DataFrames.jl and Polars

- **Status:** Proposed
- **Date:** 2026-10-20
- **Deciders:** the user at the phase-2c ★ (the policy items marked ★ below), the lead (the
  measured numbers)
- **Scope:** ChuiFrames.jl

## Context

- ADR-0003 rule 2 (eager fast path) leaves the per-verb overhead budget to "the performance
  ADR", and its Consequences owe one: target ratios per benchmark family, the eager per-verb
  overhead and TTFX. Ecosystem ADR-0011: `benchmark/benchmarks.jl` defines a BenchmarkTools
  `SUITE`, AirspeedVelocity compares PRs with `main` (warning-only at first), the tolerance is
  `ratchets.toml` `bench.time_tolerance` (0.10), and budgets come from each package's
  performance ADR. ChuiCore ADR-0009 is the model (3× → 1-2-5 time budgets, tighten-only).
- Measurements at `717d8cc` (suite at `6250cad`; Apple M3 Pro, 1 thread, **a shared machine at
  load average 7-89**; evidence in [performance.md](../research/performance.md)):
  - Suite (PF-02, PF-03): 47 entries. On 10-row frames a verb costs 2.8-36 μs (1.13.2) and
    3.0-33 μs (1.10.12). At 10^6 rows: `filter` 76 ms, `mutate` 51 ms, `arrange` 2.9-5.8 s,
    grouped `summarise` 144-990 ms, window 256 ms.
  - Allocations grow with the row count (PF-11): 2 per row for `filter`, 3 for `mutate` and
    `summarise`, 12 for the window, 83-104 for `arrange`; `slice_head(n = 10)` copies 8 bytes per
    input row. They are deterministic per Julia version.
  - Load and TTFX (PF-04, warm medians of 10 fresh processes at load average ≈10): `using
    ChuiFrames` 448 [404, 527] ms (1.13.2), 626 [587, 715] ms (1.10.12); first call of the
    workload 33 ms / 58 ms; precompile 16.5 s / 14.1 s (41.8 s / 26.6 s at load average 56-90).
    The PrecompileTools workload changes the first call by 0-10 ms (PF-05).
  - Against the same operations on the same data (PF-06 to PF-10): from 10^4 rows on ChuiFrames
    is 3.5-43× slower than DataFrames.jl 1.8.2 for every row-wise family except `distinct`
    (1.1-1.5×), and 13-126× slower than single-threaded Polars 2.0.0 at 10^6 rows. On 10-row
    frames the grouped verbs are 2-5× faster than DataFrames.jl. TTFX: 0.48 s to a first result
    against DataFrames + CSV + Arrow's 8.8 s.
  - AirspeedVelocity 0.6.6 cannot build ChuiFrames' benchmark environment: it adds JSON3, which
    caps Parsers at 2.8.8, and CSV 1.x needs Parsers 3 (PF-12).

## Decision

1. **The benchmark set** is `benchmark/benchmarks.jl` (public API only, fixed seed, inputs
   interpolated): `filter`, `select`, `mutate`, `arrange` (Float64, two keys, String),
   `group_by ⨟ summarise` (sum/mean/n; Int and String keys; 10 and n ÷ 10 groups), grouped
   window (`row_number`, `cumsum`), `distinct`, `slice_head`, `count_by`, a 3-verb pipeline, at
   10, 10^4 and 10^6 rows ("many groups" skips 10 rows), and `read_csv`/`write_csv`/
   `read_arrow`/`write_arrow` of a 10^5-row frame. A new hot path (a verb, a kernel, a reader)
   **must** add a `SUITE` entry and budget rows for every Julia version table in the same PR.
2. **Time, allocation and memory budgets** live in `benchmark/budgets.toml`, one table per kind
   and Julia version (`[time."1.13"]`, `[allocs."1.10"]`, …; other versions use the 1.10
   tables), one row per `SUITE` key. `julia benchmark/run.jl --check` fails when a median trial
   is over any of its three budgets, or when the `SUITE` keys and the rows of any table differ.
   - ★ time = 3× that version's median, rounded **up** to the 1-2-5 series (3× to 7.5×), floor
     10 μs. It catches a lost specialization, a type instability or an O(n²) step, not a
     10-50 % drift (that is the regression gate's job, rule 6).
   - ★ allocations and memory = 1.5× the measured count, rounded up to 2 significant digits
     (floors 100 allocations, 16 KiB). Counts do not depend on load, so the margin can be tight:
     one new allocation per row in a hot loop moves a 10^6-row entry by 10^6.
3. **The per-verb overhead budget** (ADR-0003 rule 2) is the `n=10` rows of rule 2. Every
   single eager verb on a 10-row frame **must** stay within its row; the largest single-verb row
   is 200 μs (`mutate` on 1.13.2, measured 36 μs), and the 3-verb pipeline's is 100 μs.
4. **Load and TTFX budgets** (warm medians of `--runs` fresh processes, `benchmark/ttfx.jl
   --check`; `using` timed inside the process, Julia's startup excluded):
   | Measure | 1.13 (stable) | 1.10 (LTS, and other versions) |
   |---|---|---|
   | `using ChuiFrames` (★ ADR-0005 rule 5's values) | ≤ 500 ms | ≤ 800 ms |
   | load + first call of the TTFX workload | ≤ 700 ms | ≤ 1000 ms |
   | precompile of ChuiFrames alone (`Base.compilecache`) | ≤ 60 s | ≤ 60 s |
   The TTFX workload mirrors the `@compile_workload` in `src/ChuiFrames.jl`; a change to one
   changes the other in the same PR.
5. ★ **Budgets may only tighten** without an amendment of this ADR; loosening one needs an
   amendment with the measurement that forces it. A `src/` change that moves an allocation row
   is re-measured and the row tightened when the count falls by more than half.
6. ★ **Where checks run.** `run.jl --check` and `ttfx.jl --check`, on 1.13 and `+lts`, are run
   by the lane that changes the engine, a kernel, the I/O path or the precompile workload, and at
   release (`/release-check`); they are not CI jobs (the baselines are from an M3 Pro, not the CI
   runners). The PR regression gate is `julia scripts/ci.jl bench` (HEAD vs merge base,
   `bench.time_tolerance`), warning-only in CI until the baselines settle (ADR-0011). It replaces
   AirspeedVelocity in `Benchmark.yml` until AirspeedVelocity resolves with CSV 1.x (PF-12).
7. **Target ratios** (informational, for the engine work of phase 4; not checked): medians at
   10^6 rows, single-threaded, against the same operations of PF-06/PF-08.
   | Family | now vs DataFrames.jl | target | now vs Polars 1 thread | target |
   |---|---:|---:|---:|---:|
   | `filter`, `mutate`, pipeline | 23-37× | ≤ 2× | 24-84× | ≤ 3× |
   | `select` (shares buffers; DataFrames copies) | 0.012× | ≤ 1× | 0.3× | ≤ 1× |
   | `arrange` | 4-29× | ≤ 2× | 15-62× | ≤ 3× |
   | grouped `summarise`, `count_by` | 3.4-38× | ≤ 1.5× | 13-38× | ≤ 3× |
   | grouped window | 22× | ≤ 2× | 19× | ≤ 3× |
   | `distinct`, `slice_head` | 1.1×, 34× | ≤ 1× | 2.5×, 126× | ≤ 2× |
   | CSV / Arrow IPC read and write (10^5 rows) | 0.9-5.8× | ≤ 1.5× | 2.2-5.4× | ≤ 3× |
   | any verb at 10 rows | 0.2-2.9× | ≤ 1× | 0.1-3.7× | ≤ 1× |

## Alternatives rejected

| Alternative | Why rejected |
|---|---|
| Time budgets as `@test` assertions | Wall time in the test suite flakes on shared machines and CI runners. |
| One table for both Julia versions | Up to 2× apart per entry (PF-03); one table would be loose on one of them. |
| Time budgets only, no allocation budgets | Allocations are deterministic and catch the regressions PF-11 shows; time at 3× misses a 2× slowdown. |
| Budgets from the 10^6 rows only | The per-verb overhead (ADR-0003 rule 2) is a 10-row property. |
| Blocking ratio targets now | Every large-frame family misses them by 4-126×; they would fail every PR until phase 4. |
| AirspeedVelocity as the PR gate now | It cannot resolve the environment (PF-12). |

## Consequences

- New: `benchmark/{Project.toml,benchmarks.jl,run.jl,ttfx.jl,budgets.toml}`,
  `docs/src/performance.md` (user-facing tables, wins and losses), `docs/research/performance.md`.
- The budgets fix the current slowness as a ceiling, not a goal: a phase-4 rewrite will tighten
  most rows by 10× or more, each in its own PR (rule 5).
- Lanes changing `src/` re-run both checks; the full suite takes 4-5 minutes per Julia version.
- `Benchmark.yml` (T3) still calls AirspeedVelocity; on this package that job fails at
  environment setup and, being warning-only, reports nothing. Replacing it is the user's ★.

## Verification

- `julia benchmark/run.jl --check` and `julia +lts benchmark/run.jl --check`;
  `julia benchmark/ttfx.jl --check` and `julia +lts benchmark/ttfx.jl --check` (PF-14).
- `julia scripts/ci.jl bench` (PF-13); the AirspeedVelocity attempt (PF-12).
- UNVERIFIED: every number on a quiet machine and on CI runners; the cause of the per-row
  allocations (PF-11); why the precompile workload barely changes the first call (PF-05).

## Revisit when

- The engine work of phase 4 lands (tighten the rows; re-measure the ratios).
- A quiet-machine or CI baseline exists (tighten TTFX and time budgets; consider a CI check).
- AirspeedVelocity resolves with CSV 1.x (move the PR gate back to it, ADR-0011).
- A downstream package reports a hot path missing from the set.
