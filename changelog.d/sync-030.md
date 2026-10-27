- Synced the ecosystem factory template to 0.3.1 (`.factory-version`; coordinator commit b4aeda3,
  ADR-0015): the `test-writer` role and test-first lanes of 0.3.0, with 0.3.1's fixes (the format
  job selects its own files and skips the tdd fixtures, one TDD ledger per owning repo, unnamed
  TDD dispatches, deletion-only test-fix). New `scripts/tdd.jl` (`red`, `green`,
  `api`, `brief`, `audit`) and its helpers, the `tdd_boundary` and `tdd_commit_post` hooks, dod's
  `tdd` requirement, the `test_writer` body and narrowed `implementer` body, and the updated
  tester and reviewer bodies, `/change-review` and `lane-lifecycle` skill.
- `test/runtests.jl` gains the 0.3.0 `item=` selection and `TDD_MATCHED` record, and the
  template's Supposition and LTS-manifest notes that `CLAUDE.md` cites; `CLAUDE.md` names
  test-first lanes, the `tdd_boundary` hook and the `tdd.jl` commands.
- `JuliaTestItems.toml` excludes `/scripts/test/fixtures/` (the tdd fixture package's items fail on
  purpose), and `.gitignore` ignores that package's Manifests, as the 0.3.0 template does.
- The registry gains the `test_writer` entry and narrows the `implementer` (no `test/**`); the
  law, property and differential testers gain `disallowed_tools` and test-first descriptions.
  `risk.toml` requires `tdd` in T1-T3 and protects the five tdd scripts as T3.
