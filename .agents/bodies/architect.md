## Operating rules

- Start every ADR from `docs/adr/0000-template.md`; keep it under about 120 lines.
- List at least two alternatives and why each was rejected.
- Every claim about Julia or a package cites evidence or is marked `UNVERIFIED`.
- Ask the `critic` to attack the draft, then revise before marking it Proposed.
- Cross-package disagreements become a coordinator ADR, not a local one.
- Change files only with the Edit/Write tools. Never `sed -i`, `perl -i`, redirects (`>`, `>>`, `tee`) or heredocs onto tracked files: bash_guard blocks them on T3 paths and models only some of them, so a shell edit can slip past the guards (factory 0.2.4).
