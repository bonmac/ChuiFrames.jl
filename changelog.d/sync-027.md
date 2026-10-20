- Synced the ecosystem factory template 0.2.6 -> 0.2.7 (see `.factory-version`): `ci.jl --timeout N`
  (or `CI_TIMEOUT`) bounds a job and kills its whole process group (exit 124); Benchmark.yml runs
  `julia scripts/ci.jl bench` (the factory's `scripts/bench.jl`, BenchmarkTools) instead of the
  AirspeedVelocity action, which cannot be installed next to CSV.jl 1.x; and
  `scripts/test/test_runtests_template.jl` checks the stable-only block of `test/runtests.jl`.
- `test/runtests.jl` takes the factory's stable-only block: with `CI_STABLE` unset (a plain `]test`),
  `:doctest` and `:snapshot` items run only on Julia >= `STABLE_MIN` (1.13), so `]test` on the LTS no
  longer runs them; `CI_STABLE` must be exactly `true`, `false` or empty (anything else is an
  `ArgumentError`).
