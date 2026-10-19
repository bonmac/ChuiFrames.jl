- Synced the ecosystem factory template to 0.2.4 (`.factory-version`): changelog fragments in
  `changelog.d/` (`scripts/changelog.jl`), `scripts/check_claims.jl`, `scripts/evidence.jl`,
  split bash guard hooks, and a seeded `test/contracts/` environment. Widened the T3 protected
  paths in `risk.toml`, raised the lane cap (`max_open`) to 6, and refreshed the vendored
  ecosystem rules, package brief and ChuiCore/ChuiTypes contracts (coordinator commit ff0100a).
- Aligned with ChuiCore.jl's 0.2.4 setup: `test/runtests.jl` never runs `:contract` items (not
  even under `-- all`; they run in `test/contracts/` via `julia scripts/ci.jl contracts`),
  `test/jet/Project.toml` bounds `TOML = "1"` and `julia = "1.12"`, and `.gitignore` covers
  `test/contracts/Manifest*.toml` and the machine-local `.agents/factory.local.toml` and
  `.claude/hooks/read-only-roots.txt` (the latter is no longer tracked). Provenance headers now
  cite coordinator commit ff0100a (content unchanged; the old commit ids were rewritten away).
