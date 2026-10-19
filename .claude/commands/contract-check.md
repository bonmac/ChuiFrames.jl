---
description: Check this package's use of upstream ecosystem APIs against test/contracts/, and draft a cross-repo request when something is missing.
argument-hint: [upstream package name]
---
<!-- Factory-managed (see .factory-version). -->
Upstream: $ARGUMENTS (empty means every upstream in `test/contracts/upstreams.toml`)

1. Dispatch the `contract-steward` agent.
2. Refresh each upstream's contract file named in `test/contracts/upstreams.toml`
   `[contract_files]` from the coordinator's `contracts/<package>.md` (from inside the
   coordinator, `--contracts ../contracts` reads them in place).
3. Run `julia scripts/contract_usage.jl --strict` (add `--contracts DIR` when step 2 read the
   files in place) and paste its output. It cross-checks
   `test/contracts/USED.md` (`- <ID> [— note]` lines) against the `@testitem "<ID> ..."` items
   in `test/contracts/`, against the contract files (the ID exists; retired is an error,
   deprecated a warning), and against the qualified upstream names grepped from `src/` and
   `ext/`, mapped to IDs through the contracts' `names:` lines. Upstreams grepped: every key of
   `[upstreams]` and `[contract_files]`.
4. Fix each error:
   - ID listed but untested: add one `:contract` test item named `"<ID> <what it checks>"`,
     following the entry's `test:` line. Test it for real; no `@test_skip` placeholders.
   - Test for an unlisted ID: the package relies on it (list it) or no longer does (propose
     removing the test).
   - Name covered by an unlisted ID: list the ID and add its test.
   - Retired ID: move to the replacement entry.
   - ID in no contract file: refresh the contract files (step 2); if it is still missing, the ID
     is wrong or not yet promised (drop it, or request the entry: step 6).
   - Used upstream with no contract file: add it to `[contract_files]` and copy its file in.
   - Contract item not tagged `:contract`, or `@test_skip`/`@test_broken` in one: tag it /
     test it for real.
   - Invalid or duplicate entry in a contract file: the contract is malformed; refresh it, and
     if the coordinator's copy is wrong, report it (step 6) instead of editing the copy.
   An unmapped name (a warning without `--strict`) means reliance on PROVISIONAL or unpromised
   API: propose a contract entry (step 6) or stop using it. The grep misses names reached
   through a bare `using Upstream`, a module alias (`import Up as U`, `const U = Up`) or
   macros, so check those by hand; a name mentioned in a docstring counts as used.
5. Run `julia scripts/ci.jl contracts` (latest upstream release, blocking) and, if time allows,
   `julia scripts/ci.jl contracts -- main` (upstream main, warning only). Paste both outputs.
6. Missing upstream API: do NOT edit the upstream repo. Draft the request text for the
   coordinator's `requests/<from>-to-<to>-<slug>.md`: the need, the proposed API, the urgency,
   the contract affected, and a `- **Reproducer:**` line: a command in this repo that is RED
   until the upstream change lands. Closing the request quotes that command RED (before) and
   GREEN (after). Then continue behind an adapter.
7. Output: the contract_usage.jl output before and after, tests changed, run results,
   requests drafted.
