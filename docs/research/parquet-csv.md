# Parquet and CSV backends: what can back a built-in source and sink

- **Date:** 2026-10-20
- **Lane:** phase1-research (researcher). Input to the source/sink ADR; this file decides nothing.
- **Question.** (1) Which Julia Parquet package, Parquet.jl or Parquet2, can back a built-in
  Parquet source and sink: row-group listing, single column-chunk reads, statistics, decoding,
  writing, concurrent reads? (2) Which CSV.jl versions can back the built-in CSV reader, given
  CSV 1.x needs Parsers 3 and DuckDB.jl reaches Parsers 2.7 through FixedPointDecimals?

## Versions and method

| Item | Value | Source |
|---|---|---|
| Julia | 1.13.2 and 1.10.12 (`julia +lts`), `--startup-file=no`; Apple M3 Pro, 12 cores | PQ-01 |
| Parquet.jl | 0.8.6 (latest registered); julia compat `1.3` | PQ-01 |
| Parquet2 | 0.2.37 (latest registered); julia compat `1.10` | PQ-01 |
| CSV | 1.1.0 (release notes: "Released September 21, 2026") and 0.10.17 (latest 0.10) | PQ-12, PQ-14 |
| DuckDB / FixedPointDecimals | 1.5.5 / 0.4.2 or 0.6.5, depending on the resolve | PQ-12, PQ-13 |
| Reference writer | pyarrow 26.0.0 (also 14.0.2, 16.1.0, 18.1.0, 20.0.0, 22.0.0) via `uv run ... python -I` | PQ-02, PQ-04 |

Context7 has no entry for either Julia package (it resolves "Parquet2" to the Rust crate
`/jorgecarleitao/parquet2`), so API facts come from the installed sources and from running code.

Reference file: pyarrow `write_table(row_group_size=10, compression=snappy|zstd,
write_statistics=True, use_dictionary=True)`, 30 rows in 3 row groups. Columns: `i` Int64 with
nulls, `f` Float64 with a NaN and nulls, `s` string with nulls, `d` dictionary-encoded string,
`dt` date32, `ts` timestamp[us]. Every column chunk is dictionary-encoded
(`PLAIN, RLE, RLE_DICTIONARY`). For (b), a "poisoned" copy overwrites every column chunk except
row group 2 / column `i` with `0xFF`; pyarrow itself then fails a full read but still reads that
chunk. For (f), an 800 000-row zstd file in 8 row groups (columns `i`, `f`, `s`).

## Capability table

Results were identical on Julia 1.13.2 and 1.10.12 unless a cell says otherwise.

| Capability | Parquet2 0.2.37 | Parquet.jl 0.8.6 |
|---|---|---|
| Opens current pyarrow output | **Yes**, pyarrow 26.0.0 (PQ-03) | **No.** Footer parse throws `KeyError: key 16` (pyarrow 20.0.0) or `key 7` (22.0.0, 26.0.0); unknown Thrift fields are not skipped. Opens pyarrow 14.0.2, 16.1.0, 18.1.0 output (PQ-04) |
| (a) row groups and row counts | Yes: `ds = Parquet2.Dataset(path)`, `length(ds)`, `DataAPI.nrow(ds[k])` -> `[10, 10, 10]` | Yes: `Parquet.rowgroups(Parquet.File(path))`, `rg.num_rows` -> `[10, 10, 10]` (pyarrow 18 file) |
| (b) one column of one row group alone | Yes: `Parquet2.load(ds[2]["i"])` reads the chunk from the poisoned file; `ds[2]["s"]` fails as expected (PQ-05) | Yes, through unexported low-level API: `Parquet.ColumnChunkPageValues(par, Parquet.columns(par, rg, ["i"])[1], Int64)` (values plus definition levels; caller rebuilds nulls). `Parquet.ColCursor(par, ["i"]; rows=11:20)` fails on the poisoned file because it reads ahead into row group 3 (PQ-05) |
| (c) row-group min / max / null count | Yes, typed: `Parquet2.ColumnStatistics(ds[1]["dt"])` -> `min=Date("2024-01-01")`, `n_null`; all six columns (PQ-03) | Raw only: `cc.meta_data.statistics.min_value` is a `Vector{UInt8}` the caller must decode by physical and logical type; `null_count` is an Int (PQ-06) |
| (d) nulls, dictionary pages, snappy, zstd | Yes, all six columns, both codecs; NaN kept distinct from `missing`. Date -> `Date`, timestamp -> `DateTime`. Columns come back as `Parquet2.PooledVector` (dictionary chunks) (PQ-03) | Yes for nulls, dictionary, snappy, zstd. Logical types are **not** mapped by default: `dt` -> `Int32` days, `ts` -> `Int64` microseconds (PQ-06) |
| (e) write several row groups with statistics, read back by pyarrow | **Partly.** `Parquet2.writefile(path, Tables.partitioner(parts); compression_codec=:zstd, compute_statistics=true)` gives 3 row groups, Date/DateTime columns, snappy/zstd; pyarrow reads values correctly and sees `null_count`, but `has_min_max` is false for **every** column. Parquet2 drops min/max whenever a chunk has a `missing` (`extrema` on a missing column), and pyarrow ignores the min/max it does write (PQ-07, PQ-08) | **No.** `write_parquet(path, tbl; compression_codec="ZSTD")` writes one row group (`TODO do multiple row_groups` in the writer), no statistics, PLAIN only; rejects `Date` and `DateTime` columns. pyarrow reads the Int/Float/String file correctly (PQ-07) |
| (f) concurrent row-group reads, `-t 4` | Yes: 24 chunk loads via `Threads.@spawn` on one `Dataset`, 10/10 runs equal to sequential; min 0.013 s vs 0.042 s sequential (1.10: 0.012 s vs 0.042 s) (PQ-09) | Yes with one shared `Parquet.File`: 10/10 equal; min 0.021 s vs 0.031 s (1.10: 0.014 s vs 0.028 s). Page fetches go through a `ReentrantLock` in `PageLRU` (PQ-09) |
| Load time, 3 runs (`@elapsed using`) | 1.50 / 1.43 / 1.25 s on 1.13; 1.36 / 1.46 / 1.14 s on 1.10 (PQ-10) | 0.12 / 0.12 / 0.12 s on 1.13; 0.25 / 0.26 / 0.34 s on 1.10 (PQ-10) |
| First full read of the 30-row file, 3 runs | 1.91 / 1.83 / 1.76 s on 1.13; 1.68 / 2.01 / 1.65 s on 1.10 (PQ-10) | 3.98 / 4.27 / 4.19 s on 1.13; 3.16 / 3.03 / 3.13 s on 1.10 (PQ-10) |
| Dependencies (manifest entries, fresh env) | 93 (incl. Transducers, LazyArrays, DecFP, JSON, LightBSON, Thrift2) | 68 (incl. Thrift, CategoricalArrays, Decimals) |

## CSV comparison

**Resolution.** The premise "CSV 1.x cannot sit next to DuckDB 1.5.5" holds only for some
resolves. DuckDB 1.5.5 allows `FixedPointDecimals = 0.4-0.6`; FixedPointDecimals 0.4.0–0.4.2 have
**no** Parsers dependency, 0.4.3 and later need `Parsers 2.7` (PQ-11).

| Environment (fresh, `CSV = "0.10, 1"`) | Resolves to | Source |
|---|---|---|
| CSV alone | CSV 1.1.0, Parsers 3.0.0 (both Julia versions) | PQ-12 |
| `Pkg.add(["CSV", "DuckDB"])` | CSV 1.1.0, DuckDB 1.5.5, FixedPointDecimals **0.4.2**, Parsers 3.0.0; a `DECIMAL(10,2)` query returns `FixedDecimal{Int64,2}(1.25)` | PQ-12, PQ-13 |
| CSV + DuckDB 1.5.5 + FixedPointDecimals 0.6 | CSV **0.10.17**, Parsers 2.8.8 | PQ-13 |

So `CSV = "0.10, 1"` gives 1.1.0 alone and, next to DuckDB, either 1.1.0 (old FixedPointDecimals)
or 0.10.17 (current FixedPointDecimals or an existing manifest that already holds it, as in SS-12
of the source-sink research).

**API, same call on both versions** (PQ-14). `CSV.File(path; delim=';', header=1,
select=[:id, :x, :day], types=Dict(:id => Int32, :x => Float64), missingstring="NA",
dateformat="dd/mm/yyyy", limit=5)` gives the same values on 0.10.17 and 1.1.0; `ntasks=4`,
`CSV.Chunks(path; ntasks=3)` and `CSV.write(path, file)` run on both, and the written heads match.
Output on Julia 1.10.12 equals 1.13.2 for each CSV version.

Column types differ (PQ-14):

| Column (inferred) | CSV 0.10.17 | CSV 1.1.0 |
|---|---|---|
| Int, no missing | `Vector{Int64}`; `ChainedVector{Int64}` with `ntasks=4` | `Vector{Int64}` for any `ntasks` |
| Float with missing | `SentinelArrays.SentinelVector{Float64,...}`; `ChainedVector` of those with `ntasks=4` | `Vector{Union{Missing, Float64}}` |
| Text | `Vector{String15}`, `SentinelVector{String7,...}` (InlineStrings) | `DataStrings.StringVector{DataStrings.DataString}` (with missing: `{Union{Missing, DataString}}`) |
| Low-cardinality text | `PooledVector{String1, UInt32}` (default pool policy) | not pooled; `pool=true` gives `PooledVector{String, UInt32}` |
| `stringtype=String` | `Vector{String}` / `SentinelVector{String, UndefInitializer, Missing}` / `PooledVector{String}` | `Vector{String}` / `Vector{Union{Missing, String}}` |
| `CSV.Chunks(big; ntasks=3)` | 3 chunks of `CSV.File` | 1 chunk: in 1.1.0 a batch is a byte window (`chunkbytes`, default 64 MiB), `ntasks` is not a batch count |

From the CSV 1.1.0 `migration.md` (installed docs; not run here): pool default changed from
`(0.2, 500)` to `false`; date-time inference gives `Timestamp{Nanosecond}` (Durations.jl) instead of
`DateTime` (pass `types=DateTime`); `types`, `select`, `drop`, `pool` no longer accept functions;
`limit` is exact at every thread count; empty unquoted fields are always `missing`; parse problems
are collected (`CSV.problems(file)`, `on_error=`); 1.x requires Julia 1.10; new `CSV.lazy` and
`Tables.Scan` projection/filter pushdown (`scan=` keyword). InlineStrings, SentinelArrays are no
longer dependencies of 1.x (PQ-11).

## Implications (not a decision)

- Parquet.jl 0.8.6 cannot open files from pyarrow 20 or later, writes one row group without
  statistics and rejects dates. It cannot back a built-in source or sink without patches.
- Parquet2 covers (a)–(d) and (f) on both Julia versions. Its writer is the gap: min/max
  statistics are lost for nullable chunks and not accepted by pyarrow at all, so a ChuiFrames sink
  would need its own statistics path or an upstream fix. Its load time (~1.3 s) and 93-entry
  manifest argue for a package extension rather than a hard dependency.
- A built-in CSV reader written against both 0.10 and 1.x must normalise column types
  (SentinelArrays / InlineStrings / pooled in 0.10; `DataString` / plain vectors in 1.x), pass
  `pool` and `stringtype` explicitly, and not rely on `CSV.Chunks` batch counts.

## UNVERIFIED

- Why pyarrow 26 ignores Parquet2's min/max even for chunks without nulls (candidates: no
  `column_orders` in the footer, which Parquet2 leaves `nothing`, or the `created_by` string
  `"Parquet2.jl"`). Not isolated.
- Release dates of Parquet.jl 0.8.6, Parquet2 0.2.37, CSV 0.10.17 and CSV 1.0.0; maintenance status.
- Whether DuckDB 1.5.5 is fully correct with FixedPointDecimals 0.4.2 beyond one DECIMAL query.
- Timings on a loaded laptop; single machine, no BenchmarkTools. Parquet.jl first-read times are
  on the pyarrow 18 file, Parquet2's on the pyarrow 26 file.
- CSV migration-guide statements other than the column types and `Chunks` behaviour shown in PQ-14.

## Also noticed

- SS-12 in the source-sink research says CSV 1.1.0 and DuckDB 1.5.5 cannot share an env; PQ-12/13
  show they can when FixedPointDecimals resolves to 0.4.2. That line needs a correction.
- CSV 1.1.0 ships `AGENTS.md` and `SKILL.md` in the package root.

## Evidence

Scripts and outputs live in the session scratchpad `parquet/` folder (not in the repo).

**PQ-01** `Pkg.add("Parquet")`, `Pkg.add(["Parquet2","Tables","DataAPI"])` in four scratch envs:
`Parquet v0.8.6`, `Parquet2 v0.2.37`; Project.toml compat `julia = "1.3"` / `julia = "1.10"`.

**PQ-02** `uv run --python 3.13 --with pyarrow python -I mkref.py data`: `pyarrow 26.0.0`,
`snappy row_groups 3 [10, 10, 10]`, rg1 `i ... 0 9 1`, encodings `('PLAIN', 'RLE', 'RLE_DICTIONARY')`.

**PQ-03** `julia --project=env/pq2-v113 pq2_probe.jl data` (and `+lts`, diff of outputs: `SAME`):
`(a) nrowgroups = 3 rows = [10, 10, 10]`; `(b) rg2 col i: ...[missing, 11, 12, 13, 14, 15, 16,
missing, 18, 19]`; `(c) rg1 dt stats: min=Date("2024-01-01") max=Date("2024-01-10") nulls=0`;
`(d) f Union{Missing, Float64} n=30 nmissing=6 first4=[0.0, 1.5, NaN, 4.5]`; `ts ... DateTime`.

**PQ-04** `pq1_probe.jl data` -> `KeyError: key 7 not found` (in `read_container(...Statistics)`);
`write_statistics=False` file -> `KeyError: key 16 not found` (in `ColumnMetaData`). Open test per
pyarrow version: 16.1.0 and 18.1.0 `opened rowgroups=3`; 20.0.0 `FAIL KeyError 16`; 22.0.0
`FAIL KeyError 7`; 14.0.2 full probe runs.

**PQ-05** `poison.py` -> `pyarrow full read fails as expected: OSError`, `pyarrow rg2/i: [None, 11,
...]`. Parquet2 (1.13, 1.10): `rg2/i: [missing, 11, 12, 13, 14, 15, 16, missing, 18, 19]`,
`rg2/s fails as expected: MethodError`. Parquet.jl `ColCursor`: `BoundsError` from `setrow` while
advancing past row 20; `poison_pq1_low.jl` (1.13, 1.10): `nonmissing=[11, 12, 13, 14, 15, 16,
18, 19] defn_levels=Int32[0, 1, 1, 1, 1, 1, 1, 0, 1, 1]`.

**PQ-06** `pq1_probe.jl data_pa18.1.0` (1.13 vs 1.10: `SAME`): `rg1 i raw stats:
min_value=UInt8[0x00, ...] max_value=UInt8[0x09, ...] null_count=1`; `(d) dt ...{Union{Missing,
Int32}} first4=[19723, ...]`, `ts ...{Union{Missing, Int64}} first4=[1704110400000000, ...]`.

**PQ-07** `write_probe.jl` both packages, both Julia versions, then `check_written.py`.
Parquet.jl: `with dt/ts FAILED: "Column whose eltype is Date is not supported..."`; pyarrow:
`created_by: Parquet.jl 0.7.0 | row groups: 1 [30]`, `rg1: i:nostats; f:nostats; s:nostats`,
values correct. Parquet2: `row groups: 3 [10, 10, 10]`, `dt: date32[day] not null`,
`rg1: i:None,nulls=1,ZSTD; ... dt:None,nulls=0,ZSTD`, values correct.

**PQ-08** `pq2_stats_rt.jl`: Parquet2 reading its own file: `i rg1: min=nothing max=nothing nulls=1`,
`dt rg1: min=Date("2024-01-01")`; `column_orders field: nothing`; no-missing table
`a: min=1 max=10` in Parquet2 but pyarrow `a:None,nulls=0`. Source: `Meta.Statistics` in
Parquet2's write.jl calls `extrema(v)` and stores `nothing` when the result is `missing`.

**PQ-09** `julia -t 4 threads_probe.jl pq2|pq1 big/...`: Parquet2 `concurrent runs equal to
sequential: 10/10`, `seq=0.042s par=0.013s` (1.10 `0.042s`/`0.012s`); Parquet.jl `10/10`,
`seq=0.031s par=0.021s` (1.10 `0.028s`/`0.014s`).

**PQ-10** `ttfx.jl`, fresh process per run, values as in the table.

**PQ-11** Registry query (`regq.jl`, Pkg on 1.10.12): `DuckDB 1.5.5 FixedPointDecimals => 0.4-0.6`;
`FixedPointDecimals 0.4.2 Parsers => no dep`, `0.4.3 ... 0.6.5 Parsers => 2.7.0-2`;
`CSV 0.10.17 Parsers => 2.5.0-2`, `CSV 1.1.0 Parsers => 3`; `CSV 1.1.0 InlineStrings => no dep`,
`SentinelArrays => no dep`.

**PQ-12** `Pkg.add("CSV"); Pkg.compat("CSV", "0.10, 1"); Pkg.resolve()` -> `CSV v1.1.0`,
`Parsers v3.0.0`; with `Pkg.add(["CSV","DuckDB"])` -> `CSV v1.1.0`, `DuckDB v1.5.5`,
`FixedPointDecimals v0.4.2`, `Parsers v3.0.0` (both Julia versions).

**PQ-13** `duck_smoke.jl`: `CSV 1.1.0 DuckDB 1.5.5 FPD 0.4.2 -> (x = FixedDecimal{Int64, 0x02}[...(1.25)],
y = [42])` (1.13, 1.10). `Pkg.add([CSV, DuckDB@1.5.5, FixedPointDecimals@0.6])` -> `CSV v0.10.17`,
`FixedPointDecimals v0.6.5`, `Parsers v2.8.8` (both Julia versions).

**PQ-14** `julia -t 4 csv_probe.jl csv` for CSV 1.1.0 and 0.10.17 on 1.13.2 and 1.10.12 (per-version
diffs: `SAME110`, `SAME010`); type lines as in the table; 1.1.0 `nchunks=1`, 0.10.17 `nchunks=3`;
both `written head: "id,x,name,grp,day | 1,0.5,name_1,b,2024-01-02 | ..."`.
