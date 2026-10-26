### Added
- Compiled stage kernels (phase 4, spec §3; ADR-0003 rule 12): the streamed stage of a lazy query
  can run as one fused row loop built from composed closures, cached by shape for the session,
  with literals as runtime values (no `eval`, `invokelatest` or `@generated`). Results, column
  kinds and exception types are those of the interpreter: every filter conjunct and `case_when`
  branch is evaluated, scalar subexpressions once per morsel, passed-through columns keep their
  column objects, and a morsel whose kernel throws re-runs through the interpreter.
- `explain(q; kernel = true)` prints which kernel runs the streamed stage and why.
- Property tests: compiled kernel == interpreter (values bitwise, `typeof` per column, exception
  types, a dictionary column under `group_by(drop = false)`), and the rendered kernel against the
  compiled one; `@test_opt` checks of the row loop.

### Changed
- A stage whose shape is not compiled yet is compiled when the source reports at least
  `INTERP_THRESHOLD = 500_000` rows (was 10⁵ in ADR-0003 rule 12), from measurements on Julia
  1.13 and 1.10 in docs/research/codegen-phase4.md. A precompile workload compiles the kernel
  machinery into the package image.
