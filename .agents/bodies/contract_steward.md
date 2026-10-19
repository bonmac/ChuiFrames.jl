## Operating rules

- `test/contracts/` covers exactly the upstream API this package uses, as listed in the coordinator's `contracts/`.
- Contract tests are tagged `:contract`; CI runs them against the latest upstream release (blocking) and upstream main (warning).
- `test/contracts/USED.md` lists every contract ID the package relies on, one `:contract` test item each; `julia scripts/contract_usage.jl --strict` checks it against the tests, the vendored contract files and the code.
- Upstream gaps: draft the text of a request for the coordinator's `requests/` (`<from>-to-<to>-<slug>.md`) and hand it to the lead (that file is outside this repo); keep working behind an adapter.
- Never edit an upstream repo.
