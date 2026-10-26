# Differentials: joins against dplyr, Polars and DuckDB

**Question.** Where do ChuiFrames' joins give different results from dplyr 1.2.0, Polars and
DuckDB on the same data, why, and is each difference intended?

**Date.** 2026-10-26 (lane p4-join; spec
docs/superpowers/specs/2026-10-26-phase4-joins-groupby-codegen-design.md §1.6, §4).

**Tests.**

- `test/engine/differential_join_dplyr_tests.jl`, item "differential: dplyr joins" (tag
  `:differential`): `Rscript --vanilla`, dplyr 1.2.0 and tidyr 1.3.1 (asserted).
- `test/engine/differential_join_polars_duckdb_tests.jl`, item "differential: joins against
  Polars and DuckDB" (tags `:differential`, `:polars_duckdb`):
  `uv run --no-project --python 3.13 --with polars==2.0.0 --with duckdb==1.5.6 --with pyarrow==26.0.0`.

**Results.** PENDING (filled in from the lane's evidence run).

## dplyr

ChuiFrames follows dplyr 1.2.0's join semantics: row order (x order, then y order; unmatched y
rows last), `multiple` (unchosen y rows count as unmatched), `unmatched`, `na_matches`, the
error order (one ascending x pass, then y), `keep`, the suffix rule (dplyr's `join_cols` and
`add_suffixes`, read from its R source with `Rscript`), `nest_join`'s nested tables, and
integer/double keys compared as double. The test passes `suffix = (".x", ".y")` where names clash,
so names compare directly.

Divergences (documented, not encoded as cases):

- **Suffix default** `("_x", "_y")`, not `(".x", ".y")`: `c.v_x` works in Julia, `c."v.x"` does
  not read well. docs/research/parity-dplyr.md.
- **nest_join's default `name`** is `:y`; dplyr deparses the `y` argument (`nest_join(x, yy)`
  names the column `yy`). A Julia function cannot see the argument expression.
- **`multiple = "warning"`** is not offered, and dplyr's default many-to-many `relationship`
  warning is not reproduced.
- **Integer keys above 2^53** joined with float keys (compared as `Float64`, ★ K4) have no dplyr
  counterpart: R integers are 32 bits, and dplyr rejects a `bit64::integer64` key against a
  double. Checked against the oracle only (test/engine/join_k4_tests.jl).
- **Warning added:** a `nest_join` `name` equal to an x column replaces that column as dplyr does
  (checked by the case `nest_clash`); ChuiFrames also logs a `@warn`.

## Polars and DuckDB

PENDING (filled in from the lane's evidence run).
