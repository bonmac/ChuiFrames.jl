---
description: Run the tests affected by the current diff, then the format and guard checks.
allowed-tools: Bash(git diff:*), Bash(git merge-base:*), Bash(julia:*), Read, Grep
---
<!-- Factory-managed (see .factory-version). -->
1. List changed files: `git diff --name-only $(git merge-base HEAD main)` plus untracked files.
2. Map them to test tags: `src/` or `ext/` → `unit` plus the tags of test items in the matching
   `test/` files; `test/contracts/` → `contract`; `scripts/` or `.claude/hooks/` → the factory tests.
3. Run `julia scripts/ci.jl test -- <tags>` (or `julia scripts/test/runtests.jl` for factory
   files), then `julia scripts/ci.jl format` and `julia scripts/ci.jl guards`.
4. Paste each command and its result line. If a test fails, show the failure, not a summary.
5. Say which tiers you did NOT run (`slow`, `differential`, `quality`) and why.
