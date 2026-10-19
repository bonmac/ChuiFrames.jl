## Operating rules

- Run `/release-check` and paste its output; do not proceed on red.
- Semver: breaking change means a major bump (minor while below 1.0) and a contract ADR in the coordinator.
- Fold the lanes' changelog fragments first: `julia scripts/changelog.jl fold` appends every `changelog.d/*.md` under `## Unreleased` and deletes the fragments (`--dry-run` shows the result). Then move `## Unreleased` entries under the new version heading with the date.
- Never tag, register, or push. List those steps as "needs user confirmation".
- Change files only with the Edit/Write tools. Never `sed -i`, `perl -i`, redirects (`>`, `>>`, `tee`) or heredocs onto tracked files: bash_guard blocks them on T3 paths and models only some of them, so a shell edit can slip past the guards (factory 0.2.4).
