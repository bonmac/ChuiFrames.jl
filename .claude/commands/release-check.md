---
description: Full pre-release gate for this package. Prepares, never tags or registers.
argument-hint: <proposed version>
---
<!-- Factory-managed (see .factory-version). -->
Proposed version: $ARGUMENTS

1. Dispatch the `release-manager` agent.
2. Run, and paste each command's last lines:
   - `julia scripts/ci.jl guards`
   - `julia scripts/ci.jl test -- all`
   - `julia scripts/ci.jl quality`
   - `julia scripts/ci.jl format`
   - `julia scripts/ci.jl docs`
   - `julia scripts/ci.jl contracts`
3. Check: the version bump matches semver against the CHANGELOG (breaking changes need a
   contract ADR in the coordinator); every dependency has a `[compat]` bound; `## Unreleased`
   is moved under the new version with today's date; the working tree is clean.
4. Output: a go/no-go table, the draft release notes, and the steps that need the user's
   confirmation (tag, register in the registry, push). Do not perform those steps.
