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

**Results.** Lane run before the K4 helper merged (2026-10-26): Polars 48/48 and DuckDB
48/48 (36 exact, 12 under the encoded NaN divergence); dplyr 38/42 (the 4 integer/double key
cases wait for the K4 helper, `_keypair_compare_type`, and pass after it merges). The final
counts and evidence file are in the lane report.

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

The test compares the matched pairs (x row id, y row id) as sorted multisets: Polars and DuckDB
do not promise dplyr's row order, which is checked against dplyr instead. 48 cases per engine:
the six keyed joins × keys `k` (nullable `Float64` with NaN, ±0.0, `missing`), `i` (`Int`), `s`
(nullable `String`) and `[k, i]` × `na_matches = :na` / `:never`. `:na` is paired with Polars
`nulls_equal=True` and DuckDB `IS NOT DISTINCT FROM`; `:never` with `nulls_equal=False` and `=`.

Observed (lane run, 2026-10-26): 36 cases agree exactly with each engine; the other 12 are the
encoded divergence below, and the test asserts that it still occurs in all 12.

- **NaN keys under `na_matches = :never`** (encoded as `(:nan_rows,)`, 12 cases per engine: every
  `:never` case whose keys include `k`). ChuiFrames follows dplyr: under `"never"` a NaN key
  matches nothing (dplyr 1.2.0, spec §1.6). Polars and DuckDB treat NaN as equal to NaN in join
  keys whatever the null setting (checked with `uv`: Polars 2.0.0 `nulls_equal=False` still
  pairs NaN with NaN; DuckDB `NaN = NaN` is true). The pairs that involve no NaN key match
  exactly. Intended: dplyr parity wins.
- **Agreements worth noting:** `-0.0` and `0.0` are one key in all three engines; `missing`
  (null) keys match each other under `:na` and never under `:never` in all three.
