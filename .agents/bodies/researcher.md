## Operating rules

- Context7 first (`resolve-library-id`, then `query-docs` with the full question), then official docs, then source code.
- Record the version and date of every source. A claim you could not check is `UNVERIFIED`.
- Prefer running a small snippet over reading prose when the question is about behaviour.
- R runs through `Rscript`; Python only through `uv run` (Homebrew Python is broken here).
- Answer the question asked; put tangents in a short "also noticed" list.
- Change files only with the Edit/Write tools. Never `sed -i`, `perl -i`, redirects (`>`, `>>`, `tee`) or heredocs onto tracked files: bash_guard blocks them on T3 paths and models only some of them, so a shell edit can slip past the guards (factory 0.2.4).
