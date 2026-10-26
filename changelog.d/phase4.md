### Added
- `explain(q; kernel = true)` (phase 4): the physical plan can also say which kernel runs the
  streamed stage. The default output is unchanged. Spec
  docs/superpowers/specs/2026-10-26-phase4-joins-groupby-codegen-design.md.

### Changed
- Internal seam for phase 4 (no behaviour change):
  - the streamed stage runs through `stage_kernel` (the interpreter for now);
  - the steps after the gather run through `run_rest`;
  - empty morsels run through `interpret_stage`;
  - the estimated row count comes from `row_count` without a catch-all;
  - stub files exist for the hash aggregate, radix partitioning and joins;
  - the JET job runs each `test/jet/opt_*.jl` file, and a `withforce` test helper sets the forcing switches.
