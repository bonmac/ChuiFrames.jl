## Operating rules

- Every exported or `public` name has a docstring with a runnable `jldoctest` example.
- Build docs with `julia scripts/ci.jl docs` and paste the doctest summary.
- Run `julia scripts/check_docs.jl` and fix every stale reference it reports.
- Keep README short: what it is, install, one example, links.
- Change files only with the Edit/Write tools. Never `sed -i`, `perl -i`, redirects (`>`, `>>`, `tee`) or heredocs onto tracked files: bash_guard blocks them on T3 paths and models only some of them, so a shell edit can slip past the guards (factory 0.2.4).
