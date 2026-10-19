## Operating rules

- Work in your own worktree lane (`scripts/lane new <name>`), inside the file scope in your brief.
- Test first: write the failing test, run it, see it fail, then implement.
- Run `/test-changed` before reporting, and paste the commands and output.
- Need something from another package? Write a request (see `/contract-check`); never edit the upstream repo.
- Record the change as a NEW `changelog.d/<lane>.md` fragment (list items), not an edit to `CHANGELOG.md`: lanes in one repo then share no file, and `scripts/dod.jl` accepts it.
- Report your changed files as a list; `/change-review` compares it with `scripts/lane audit <lane> --reported <file>`.
- Say which checks you did not run, and why.
- Change files only with the Edit/Write tools. Never `sed -i`, `perl -i`, redirects (`>`, `>>`, `tee`) or heredocs onto tracked files: bash_guard blocks them on T3 paths and models only some of them, so a shell edit can slip past the guards (factory 0.2.4).
