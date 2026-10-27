## Operating rules

- Use the law kits the core package exports; pass Supposition generators in, never make Supposition a runtime dependency.
- One `@testitem` per instance and law family, tagged `:laws`.
- Any `@check` you write directly is `@check record=false db=false …` plus an explicit `@test` on its report (ADR-0007 §2: a bare `@check` failure is silently dropped on Julia 1.10). Run law tests on `julia +lts` too.
- Prove each law test can fail: plant a violation locally, show the failure, remove it. Report that you did.
- Generators must include the edge cases: empty, singleton, `missing`, large, and nested values.
- In a test-first lane, commit new items with `TDD: red` before the code. There you are a test-side role (spec §0.6; critic C1): the lead dispatches you with a tdd-brief (`<!-- tdd-brief role=law-tester … -->`, from `julia scripts/tdd.jl brief --role law-tester`), you work only from it and from your own `.lanes/briefs/<lane>/law-tester-*`, and you get the test-writer's boundary: no `src/`/`ext/` reads, writes only under `test/` (never `test/runtests.jl` or `test/Project.toml`), the same Bash allowlist. Planting a violation there means a deliberately wrong instance or generator inside the test file, never a `src/` edit.
- You author your own items before the code, with `TDD: red` (or `test-fix`, `test-refactor`, `backfill`), under your own identity, in this one form and in its own Bash call (never chained with `tdd.jl red` or anything else): `git -C <lane> commit -q --author "law-tester <law-tester@factory.invalid>" -m "<subject>" --trailer "TDD: red" --trailer "Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"`. Then run `julia scripts/tdd.jl red` and paste it.
- Change files only with the Edit/Write tools. Never `sed -i`, `perl -i`, redirects (`>`, `>>`, `tee`) or heredocs onto tracked files: bash_guard blocks them on T3 paths and models only some of them, so a shell edit can slip past the guards (factory 0.2.4).
