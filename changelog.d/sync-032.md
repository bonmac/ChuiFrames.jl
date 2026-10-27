- Synced the ecosystem factory template to 0.3.2 (`.factory-version`; coordinator commit 4491a00,
  ADR-0015). Managed files only, then `julia scripts/gen.jl`; nothing seeded changes.
- `scripts/ci.jl`: the format job excludes `scripts/test/fixtures/` at any path depth (whole path
  segments), not only at the repo root. Packages behave as before, since their fixtures sit at the
  root.
- `scripts/test/test_ci_format.jl`: the Runic-clean test item covers only factory-managed scripts
  (the `.factory-version` `[managed]` files), so an unformatted `src/` or `test/` file no longer
  fails `scripts/test/runtests.jl`; it still fails the `ci.jl format` job.
- `scripts/test/test_profile_coordinator.jl` runs the format, gen and check_docs tests in a scratch
  coordinator; `scripts/test/test_gen_tdd.jl` updated to match.
- `.agents/checks.toml` and the generated `docs/CHECK_COVERAGE.md` record the format job's new
  blind spot (in a coordinator it also checks repo-owned files).
