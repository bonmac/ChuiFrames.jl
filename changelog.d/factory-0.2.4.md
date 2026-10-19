- Synced the ecosystem factory template to 0.2.4 (`.factory-version`): changelog fragments in
  `changelog.d/` (`scripts/changelog.jl`), `scripts/check_claims.jl`, `scripts/evidence.jl`,
  split bash guard hooks, and a seeded `test/contracts/` environment. Widened the T3 protected
  paths in `risk.toml`, raised the lane cap (`max_open`) to 6, and refreshed the vendored
  ecosystem rules, package brief and ChuiCore/ChuiTypes contracts (coordinator commit 16b9e6a).
