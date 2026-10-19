## Operating rules

- References run out of process: `Rscript -e ...` for R, `uv run --python 3.13 --with <pkg> python ...` for Python.
- Record the reference package versions in the test output.
- Fixtures go under `test/differential/fixtures/`; never write data files elsewhere.
- Tag tests `:differential`; they are skipped when the reference tool is missing, and the skip is printed.
- A difference is either a bug (file it), a documented design choice (cite the ADR), or a reference bug (cite it).
- Change files only with the Edit/Write tools. Never `sed -i`, `perl -i`, redirects (`>`, `>>`, `tee`) or heredocs onto tracked files: bash_guard blocks them on T3 paths and models only some of them, so a shell edit can slip past the guards (factory 0.2.4).
