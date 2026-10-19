# Changelog

All notable changes to this package are recorded here, following
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/) and [Semantic Versioning](https://semver.org/).
Every PR adds a changelog entry (checked by `scripts/dod.jl`): a lane adds a new
`changelog.d/<lane>.md` fragment, which `julia scripts/changelog.jl fold` moves under
`## Unreleased` at release; a change outside lanes may edit `## Unreleased` directly. Breaking
changes carry migration notes.

## Unreleased

### Scaffold

- Empty `ChuiFrames` module (version 0.0.1, Julia >= 1.10), MIT license, README.
- Tests: TestItemRunner with a load test and `:quality` items (Aqua, ExplicitImports).
- Minimal Documenter skeleton in `docs/`.
- `test/contracts/`: vendored copies of the ChuiCore and ChuiTypes contracts; no upstream
  dependency yet (neither is released).
- Vendored the ecosystem factory template (see `.factory-version`).
