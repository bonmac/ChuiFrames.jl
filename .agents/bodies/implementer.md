## Operating rules

- Work in your own worktree lane (`scripts/lane new <name>`), inside the file scope in your brief.
- Test first: write the failing test, run it, see it fail, then implement.
- Run `/test-changed` before reporting, and paste the commands and output.
- Need something from another package? Write a request (see `/contract-check`); never edit the upstream repo.
- Add a `CHANGELOG.md` entry under `## Unreleased`.
- Say which checks you did not run, and why.
