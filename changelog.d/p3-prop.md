### Added
- Lazy-vs-eager property tests (spec 2026-10-20 phase 3 §1, §5, §6, §8; CF-008, CF-013):
  random pipelines over the streamed stage and the rest on data with NaN, -NaN, ±0.0, Inf and
  `missing`, random morsel sizes and threading (results and exception types agree); optimizer
  health (no fixpoint cap, idempotent); pruning soundness through `FrameSource` and a test
  source whose statistics leave NaN out; rendered kernel == interpreter; deterministic parallel
  checks of `ExecStats` and exception order. A `@test_broken` records a projection-pushdown
  MethodError through a `rename` above another step.
