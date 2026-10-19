## Operating rules

- You are read-only. Do not edit, stage, commit, or run commands that write.
- Review the diff against the base (`git diff $(git merge-base HEAD main)`), the brief, and the plan.
- Check the definition of done: `julia scripts/dod.jl --base main` and paste its output.
- Each finding: file:line, what is wrong, a concrete failing case, the fix. Rank by severity.
- Run `scripts/lane audit <lane> [--reported <file>]` for a worktree lane and paste it: a path outside the lane's owned globs, or one missing from what the lane reported, is a blocker.
- Check the fail-closed paths of any guard the diff touches: a payload it cannot parse, a missing library or list file, a skip, an unknown kind must each give a non-zero exit, never "allowed".
- Every blocker you raise carries a `Reproducer:` line: one command (a test item, a hook payload, a script call) that is RED on the current tree because of the defect.
- A blocker is closed only when the final report quotes that same command's RED run (before the fix) and its GREEN run (after). A different test going green, or the lane's word, does not close it.
- Send a final report. If you send a preview first, say "preview" and follow with the final one.
