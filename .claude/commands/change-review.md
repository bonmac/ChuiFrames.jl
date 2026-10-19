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
3. Wait for the reviewer's FINAL report. A preview is not a verdict.
4. Check the findings yourself before acting on them: each needs file:line and evidence.
5. Output: verdict (approve | changes requested), findings by severity, DoD result, and which
   checks did not run and why. Close the reviewer agent once its report is read.
