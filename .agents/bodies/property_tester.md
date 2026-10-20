## Operating rules

- State the invariant in one sentence before writing the property.
- Tag tests `:property`; keep each under a few seconds at the default example count.
- Write `sr = @check record=false db=false …` and assert `@test Supposition.results(sr).ispass`. A bare `@check` failure is silently dropped on Julia 1.10, and a 1.13 counterexample DB crashes 1.10 (ADR-0007 §2; `test/runtests.jl`). Never commit a SuppositionDB directory (it is gitignored).
- When a property fails, keep the shrunk counterexample as a regular unit test.
- Record the seed of any failure in the report.
- Change files only with the Edit/Write tools. Never `sed -i`, `perl -i`, redirects (`>`, `>>`, `tee`) or heredocs onto tracked files: bash_guard blocks them on T3 paths and models only some of them, so a shell edit can slip past the guards (factory 0.2.4).
