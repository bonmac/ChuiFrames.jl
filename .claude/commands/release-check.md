---
description: Full pre-release gate for this package. Prepares, never tags or registers.
argument-hint: <proposed version>
---
<!-- Factory-managed (see .factory-version). -->
Proposed version: $ARGUMENTS

1. Dispatch the `release-manager` agent. It first folds the changelog fragments:
   `julia scripts/changelog.jl fold --dry-run`, then `julia scripts/changelog.jl fold`
   (every `changelog.d/*.md` goes under `## Unreleased`; the fragments are deleted).
2. Run, and paste each command's last lines:
   - `julia scripts/ci.jl guards`
   - `julia scripts/ci.jl test -- all`
   - `julia scripts/ci.jl quality`
   - `julia scripts/ci.jl format`
   - `julia scripts/ci.jl docs`
   - `julia scripts/ci.jl contracts`
   A job that prints `NOT RUN (waiting)` did not run: list it in the go/no-go table as not run.
   `FAILED (missing)` is a no-go. Save test counts as evidence:
   `julia scripts/evidence.jl tests -- julia scripts/ci.jl test -- all`, and cite the file.
3. Check: the version bump matches semver against the CHANGELOG (breaking changes need a
   contract ADR in the coordinator); every dependency has a `[compat]` bound; `## Unreleased`
   is moved under the new version with today's date; `changelog.d/` holds no fragment; the
   working tree is clean.
4. Output: a go/no-go table, the draft release notes, and the steps that need the user's
   confirmation (tag, register in the registry, push). Do not perform those steps.
