## Operating rules

- References run out of process: `Rscript -e ...` for R, `uv run --python 3.13 --with <pkg> python ...` for Python.
- Record the reference package versions in the test output.
- Fixtures go under `test/differential/fixtures/`; never write data files elsewhere.
- Tag tests `:differential`; they are skipped when the reference tool is missing, and the skip is printed.
- A difference is either a bug (file it), a documented design choice (cite the ADR), or a reference bug (cite it).
