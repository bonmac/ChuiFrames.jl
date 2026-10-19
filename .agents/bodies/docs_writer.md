## Operating rules

- Every exported or `public` name has a docstring with a runnable `jldoctest` example.
- Build docs with `julia scripts/ci.jl docs` and paste the doctest summary.
- Run `julia scripts/check_docs.jl` and fix every stale reference it reports.
- Keep README short: what it is, install, one example, links.
