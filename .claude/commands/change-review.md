---
description: Review a lane's change before it lands, using the read-only reviewer agent.
argument-hint: [branch or lane name; default the current branch]
---
<!-- Factory-managed (see .factory-version). -->
Review target: $ARGUMENTS (empty means the current branch)

1. Dispatch the `reviewer` agent (read-only) with: the branch, its base, the brief or plan, and
   the file scope. For a T2/T3 change also dispatch the `critic` on the design.
2. The reviewer runs and pastes:
   - `git diff --stat $(git merge-base HEAD main)..HEAD`
   - `julia scripts/dod.jl --base main` (definition of done)
   - `julia scripts/ci.jl guards`
   - for a worktree lane: `scripts/lane audit <lane> --reported <file>`, where the file is the
     changed-file list the lane reported (one path per line). It fails when the diff touches a
     path outside the lane's owned globs (`scripts/lane new <lane> --owns ...`) or differs from
     the reported list. A lane created without `--owns` fails it: pass `--owns` to audit.
   - for a test-first lane (a `TDD:` or `TDD-Mode:` trailer on the branch), in the lane:
     `julia scripts/tdd.jl audit --base main --ledger <owning repo main>/.lanes/ledger.jsonl` (the
     main checkout of the repo that owns the lane; the default when `--ledger` is left out) and
     `julia scripts/dod.jl --base main`, and reads the saved dispatch prompts under
     `<main>/.lanes/briefs/<lane>/` (`dispatched/` holds what was actually sent) against the
     lane-lifecycle brief templates. Then the reviewer body's test-first checklist.
3. Wait for the reviewer's FINAL report. A preview is not a verdict.
4. Check the findings yourself before acting on them: each needs file:line and evidence.
   Every blocker carries a `Reproducer:` command; it is closed only when the reviewer quotes that
   command RED before the fix and GREEN after. Same for a cross-repo request.
5. Output: verdict (approve | changes requested), findings by severity (each with its
   Reproducer and its red/green runs), DoD result, the lane audit, and which checks did not run
   and why (a `NOT RUN (waiting)` CI job did not run). Close the reviewer agent once its report is read.
