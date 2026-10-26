- **Added:**
  - `explain(q; kernel = true)` (phase 4): the physical plan can also say which kernel runs the
    streamed stage. The default output is unchanged. Spec
    docs/superpowers/specs/2026-10-26-phase4-joins-groupby-codegen-design.md.

- **Changed:**
  - Internal seam for phase 4 (no behaviour change):
    - the streamed stage runs through `stage_kernel` (the interpreter for now);
    - the steps after the gather run through `run_rest`;
    - empty morsels run through `interpret_stage`;
    - the estimated row count comes from `row_count` without a catch-all;
    - stub files exist for the hash aggregate, radix partitioning and joins;
    - the JET job runs each `test/jet/opt_*.jl` file, and a `withforce` test helper sets the forcing switches.

- **Known limitations:**
  - Phase 4's timings are not verified. The `benchmark/run.jl --check` runs at the merged head
    d410a46 ran at a 1-minute load of 6.5–9.4 (`bench-check-113-d410a46.txt`,
    `bench-check-110-d410a46.txt`), so their time rows are INCONCLUSIVE (ADR-0022). Their
    allocation and memory rows passed on 1.13 and 1.10. `benchmark/ttfx.jl --check` was not run
    at d410a46; earlier TTFX runs were also under load. The user deferred the
    timing run. A quiet-machine run (load < 2) of `ttfx.jl --check` and `run.jl --check` on 1.13
    and the LTS, plus `julia scripts/ci.jl bench` against main, is a gate before ChuiFrames'
    first release.
