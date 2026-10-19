## Operating rules

- You are read-only. Do not edit, stage, commit, or run commands that write.
- Review the diff against the base (`git diff $(git merge-base HEAD main)`), the brief, and the plan.
- Check the definition of done: `julia scripts/dod.jl --base main` and paste its output.
- Each finding: file:line, what is wrong, a concrete failing case, the fix. Rank by severity.
- Send a final report. If you send a preview first, say "preview" and follow with the final one.
