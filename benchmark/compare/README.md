# benchmark/compare: db-benchmark-like comparisons (not in `SUITE`)

Phase-4 spec §5: group-by q1–q5 and join q1–q3 in the style of h2oai/db-benchmark, on the same
data, against ChuiFrames' previous code path (`main`), DataFrames.jl, Polars and DuckDB. Results
and method: `docs/research/performance-phase4.md`. data.table, dplyr, Tidier.jl and pandas are
deferred to phase 7 ("Docs and the benchmark report"; docs/agent/BRIEF.md "Benchmarks").

| File | What |
|---|---|
| `gen_data.jl` | writes `G1.arrow` (group-by) and `X.arrow`, `SMALL.arrow`, `MEDIUM.arrow` (join) for N rows |
| `chui.jl` | the queries on ChuiFrames, eager and lazy; joins skipped on a checkout without them |
| `dataframes.jl` | the queries on DataFrames.jl (+ Arrow.jl to read the files) |
| `py_bench.py` | the queries on Polars 2.0.0 and DuckDB 1.5.6 (pins as the differential suite) |

Queries (db-benchmark's definitions; the tables are re-created from its published column
definitions, see `gen_data.jl`): group-by q1 `sum(v1)` by `id1`; q2 `sum(v1)` by `id1, id2`; q3
`sum(v1), mean(v3)` by `id3` (N ÷ 100 groups); q4 `mean(v1, v2, v3)` by `id4`; q5 `sum(v1, v2,
v3)` by `id6` (N ÷ 100 groups). Join q1 x ⋈ small on `id1` (inner); q2 x ⋈ medium on `id2`
(inner); q3 x ⟕ medium on `id2` (left); q1r small ⋈ x on `id1` (inner, small x / large y: the
spec §7 trigger "a small-x/large-y join more than 2× slower than DuckDB").

Every script prints a line per query and writes a TOML file of `[min_s, median_s, rows]`. All
group-by results are sorted by key, as ChuiFrames' always are.

```sh
# environments live outside the repo (the session scratchpad or .lanes/scratch, gitignored)
julia --project=$ENV_CHUI benchmark/compare/gen_data.jl $DATA 10000000
julia --project=$ENV_CHUI benchmark/compare/chui.jl $DATA chui.toml          # -t 1 by default
julia --project=$ENV_MAIN benchmark/compare/chui.jl $DATA chui-main.toml     # ENV_MAIN develops a `git archive` of main
julia --project=$ENV_DF   benchmark/compare/dataframes.jl $DATA df.toml
POLARS_MAX_THREADS=1 uv run --no-project --python 3.13 --with polars==2.0.0 --with duckdb==1.5.6 \
    --with pyarrow==26.0.0 python -I benchmark/compare/py_bench.py $DATA py-t1.toml 1
```
