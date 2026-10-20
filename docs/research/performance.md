# Performance evidence (phase 2c)

The measurements behind ADR-0022 (performance budgets): ChuiFrames' benchmark suite on Julia
1.13.2 and 1.10.12, load time, TTFX and precompile time, and the same operations on the same data
in DataFrames.jl, Polars and DuckDB. Date: 2026-10-20. Base: ChuiFrames `717d8cc` (the suite was
committed on top of it at `6250cad`; no `src/` change). Evidence IDs PF-01…; files under
`.lanes/evidence/` are written by `julia scripts/evidence.jl <kind> -- <cmd>` and are keyed to
the commit (gitignored, machine-local). The comparison scripts and their raw outputs stayed in the
lane's session scratchpad (`p2c-bench/scripts/`, `p2c-bench/out/`), as in the phase-1 notes.

**Read every absolute number with PF-01's caveat:** the machine was shared with other lanes'
test runs (load average 7 to 89 during these runs). Ratios measured minutes apart are more
trustworthy than absolute times, and the budgets are set loose for that reason (ADR-0022).

## PF-01 Machine, versions, method

- Apple M3 Pro, 12 cores (`Sys.CPU_THREADS` reports 12 on 1.13.2 and 6 on 1.10.12, on the same
  host), 18 GiB, macOS (Darwin 25.6.0). Julia 1.13.2 (`julia`, juliaup `release`) and 1.10.12
  (`julia +lts`), `--startup-file=no`, 1 thread. BenchmarkTools 1.8.0.
- `benchmark/run.jl` develops the checkout into a scratch copy of `benchmark/Project.toml`, runs
  `tune!(SUITE)` and `run(SUITE)`, and reports the median trial (time, allocations, memory) with
  min, max and the sample count. Each entry runs for 1 s (10 and 10^4 rows) or 3 s (10^6 rows and
  I/O). The 10^6-row `arrange` entries fit 1-2 samples in 3 s, so their medians are single runs.
- Inputs: `bench_columns(n)` in `benchmark/benchmarks.jl`, seed 20261020 (`Xoshiro`): `id`, `x`
  (normal), `y` (uniform), `k`/`s` (10 groups, Int/String), `kk`/`ss` (n ÷ 10 groups). I/O uses
  a 10^5-row frame (`id`, `x`, `y`, `k`, `ss` as `s`).
- Comparisons used the same data: DataFrames.jl rebuilt it with the same function and seed in
  the same Julia version; Polars and DuckDB read Arrow IPC files that ChuiFrames wrote from the
  same frames (`export_data.jl`).

## PF-02 ChuiFrames suite, Julia 1.13.2

`julia scripts/evidence.jl bench-113 -- julia benchmark/run.jl` →
`.lanes/evidence/bench-113-6250cad.txt` (exit 0, suite wall time 273 s, load average 9.4 before,
12.4 after). 47 entries. Selected medians (all rows: the evidence file and `docs/src/performance.md`):

| entry | n=10 | n=10^4 | n=10^6 | allocs at 10^6 |
|---|---:|---:|---:|---:|
| filter | 8.1 μs | 388 μs | 76.4 ms | 2 000 190 |
| select | 5.0 μs | 4.7 μs | 4.5 μs | 47 |
| mutate | 35.8 μs | 419 μs | 50.9 ms | 2 999 672 |
| arrange Float64 | 5.2 μs | 18.9 ms | 2.93 s | 82 884 300 |
| summarise, Int few | 26.1 μs | 1.97 ms | 166 ms | 2 989 745 |
| window (row_number, cumsum) | 26.2 μs | 1.69 ms | 256 ms | 11 962 606 |
| slice_head(n = 10) | 2.8 μs | 4.0 μs | 89.3 μs | 90 |

## PF-03 ChuiFrames suite, Julia 1.10.12

`julia scripts/evidence.jl bench-110 -- julia +lts benchmark/run.jl` →
`.lanes/evidence/bench-110-6250cad.txt` (exit 0, 262 s, load average 10.9 before, 49.3 after).
The env resolves its own manifest (a fresh scratch project per run). Medians are within 0.3-2× of
1.13's (e.g. filter 10^6 53.6 ms, mutate 10^6 26.8 ms, arrange Float64 10^6 3.35 s, summarise
String many 10^6 1.21 s). Much of that spread is load noise: the 1.13 pipeline at 10^6 rows took
148 ms in a trial run an hour earlier and 295 ms in PF-02. Allocation counts match 1.13's within
a few per cent, except the grouped verbs (`summarise`, `count_by`, window: one more allocation
per row on 1.10).

## PF-04 Load, TTFX and precompile time

`benchmark/ttfx.jl --runs 10`: fresh processes; `using ChuiFrames` timed inside the process;
"first call" is the workload that mirrors the `@compile_workload` (build a 4-row frame,
`filter |> mutate |> group_by |> summarise |> arrange`, `show`, Arrow IPC and CSV round trips);
precompile is `Base.compilecache` of ChuiFrames alone (3 compiles). Warm = median [min, max] of 10.

| Julia | load avg | load | first call | load + first call | cold (load + first call) | precompile | evidence |
|---|---|---:|---:|---:|---:|---:|---|
| 1.13.2 | 8-11 | 448 [404, 527] ms | 32.9 [28.4, 41.2] ms | 481 [438, 559] ms | 1186 + 36 ms | 16.5 [15.9, 16.9] s | `ttfx-113-b-6250cad.txt` |
| 1.13.2 | 56-88 | 662 [552, 983] ms | 56.9 [40.5, 166] ms | 741 [622, 1054] ms | 1370 + 51 ms | 41.8 [39.5, 47.1] s | `ttfx-113-6250cad.txt` |
| 1.10.12 | 10-11 | 626 [587, 715] ms | 57.7 [54.4, 77.0] ms | 683 [642, 789] ms | 1294 + 57 ms | 14.1 [13.9, 15.1] s | `ttfx-110-b-6250cad.txt` |
| 1.10.12 | 35-90 | 640 [567, 774] ms | 58.8 [52.2, 104] ms | 697 [620, 844] ms | 1370 + 68 ms | 26.6 [16.0, 36.9] s | `ttfx-110-6250cad.txt` |

Process startup (`julia -e nothing`): 75 ms (1.13), 137 ms (1.10). ADR-0005 rule 5's load budget
(0.5 s / 0.8 s) holds at load average ≈10, with 10 % headroom on 1.13 (the max sample, 527 ms,
is over); at load average 56-88 the 1.13 median is over it. HANDOFF's earlier 0.361 s / 0.551 s
(`@time using`, after the phase-2b merge) used a different method and a quieter machine.

## PF-05 The precompile workload buys little first-call time

`ttfx.jl --no-workload` writes `precompile_workloads = false` to the scratch environment's
`LocalPreferences.toml`; `Base.get_preferences` confirms the setting is read.
- 1.13.2: first call 33.7 [31.9, 38.3] ms without the workload (`ttfx-113-noworkload-6250cad.txt`,
  load average 20-35) vs 32.9 ms with it (PF-04); precompile 17.9 s vs 16.5 s.
- 1.10.12: 67.6 [63.8, 76.4] ms without (`ttfx-110-noworkload-6250cad.txt`) vs 57.7 ms with.
- `--trace-compile` of the first-call script in a fresh depot compiled without the workload: 25
  entries, **0** naming ChuiFrames (with the workload: 22 entries, 0 ChuiFrames). Why ChuiFrames'
  methods are already compiled without the workload is UNVERIFIED.
- Pitfall: a preference change alone did not invalidate the package cache. In a project with the
  preference set, `using ChuiFrames` loaded the same `.ji` as without it
  (`Base.pkgorigins[...].cachepath`), so `PrecompileTools` reads this preference without recording
  it as a compile-time preference (UNVERIFIED as the mechanism). `ttfx.jl` measures correctly
  because it compiles into its own scratch depot first in `DEPOT_PATH`.

## PF-06 DataFrames.jl 1.8.2, same operations

Scratch env (latest registered: DataFrames 1.8.2, CSV 1.1.0, Arrow 2.8.1, BenchmarkTools 1.8.0),
Julia 1.13.2, 1 thread, load average 9-16; `dataframes_bench.jl`, raw `out/df113.toml`. Spellings:
`subset(df, :x => (x -> x .> 0))`, `select(df, :x, :k)` (copies the columns: not like-for-like;
ChuiFrames' `select` shares buffers), `transform`, `sort` (`order(:x, rev = true)`),
`combine(groupby(df, key; sort = true), ...)` (ChuiFrames sorts groups too), grouped `transform`
with `eachindex`/`cumsum`, `unique(select(df, :k, :s))`, `first(df, 10)`, `CSV.read`/`CSV.write`,
`DataFrame(Arrow.Table(read(path)))` (ChuiFrames' reader also reads the whole file) and
`Arrow.write`. Ratios: PF-10.

## PF-07 DataFrames.jl load and TTFX

`df_ttfx.jl`, 10 fresh processes, Julia 1.13.2, load average 7-10, the PF-04 workload in
DataFrames spelling: `using DataFrames` 356 [338, 397] ms; `using DataFrames, CSV, Arrow` 581
[534, 664] ms; first call **8.28 [7.66, 8.62] s**; cold 580 ms + 8.73 s. Parts of one first call
(3 runs): verbs + `show` 2.2-2.7 s, `Arrow.write` 3.0-3.3 s, Arrow read 1.6 s, `CSV.write` 0.1 s,
`CSV.read` 2.0-2.4 s. ChuiFrames' load + first call (481 ms) is about 18× faster to a first
result; its load alone is 1.3× DataFrames' alone and 0.8× DataFrames + CSV + Arrow.

## PF-08 Polars 2.0.0

`uv run --no-project --python 3.13 --with polars==2.0.0 python -I polars_bench.py`, Python
3.13.13, eager API, timed with `perf_counter_ns` (warm-up call, then repeat for 1 s / 3 s, median).
Run twice: `POLARS_MAX_THREADS=1` (`thread_pool_size() = 1`) and default (12 threads). **The
1-thread run is the like-for-like one**: ChuiFrames phase 2 is single-threaded (ADR-0003 rule 18).
Spellings: `filter`, `select`, `with_columns`, `sort(..., maintain_order=True)` (stable, as
`arrange`), `group_by(key).agg(...).sort(key)`, `int_range(1, len + 1).over("k")` and
`cum_sum().over("k")`, `unique(maintain_order=True)`, `head(10)`, `group_by("s").len().sort("s")`,
`read_csv`/`write_csv`, `read_ipc(path)`/`write_ipc` (uncompressed). Polars 2.0 has no
`memory_map` argument on `read_ipc`; whether it maps the file is UNVERIFIED. Raw
`out/polars_t1.toml`, `out/polars_tN.toml` (load average 8-12).

## PF-09 DuckDB 1.5.6 (optional)

`duckdb_bench.py` with `SET threads = 1`; the data loaded into a native table; each query runs as
`CREATE OR REPLACE TEMP TABLE o AS <query>`, so it includes materializing the result (the other
tools return a frame). No `select`, `slice_head` or I/O rows. Raw `out/duckdb_t1.toml`.

## PF-10 Ratios ChuiFrames / other (1.13.2 medians; > 1 means ChuiFrames is slower)

| family | n=10: DF | Polars 1t | n=10^6: DF | Polars 1t | Polars 12t | DuckDB 1t |
|---|---:|---:|---:|---:|---:|---:|
| filter | 0.6 | 0.1 | 25 | 24 | 40 | 1.5 |
| select (DF copies) | 0.9 | 0.2 | 0.012 | 0.3 | 0.2 | — |
| mutate | 2.9 | 2.6 | 23 | 52 | 56 | 0.6 |
| arrange Float64 | 1.7 | 0.7 | 18 | 62 | 132 | 20 |
| arrange Int, desc Float64 | 1.4 | 0.5 | 29 | 26 | 128 | 39 |
| arrange String | 1.6 | 0.4 | 4.1 | 15 | 74 | 22 |
| summarise Int few | 0.2 | 0.7 | 38 | 38 | 103 | 37 |
| summarise String few | 0.2 | 0.5 | 3.4 | 19 | 62 | 14 |
| summarise Int many | — | — | 37 | 14 | 41 | 17 |
| summarise String many | — | — | 6.3 | 13 | 67 | 28 |
| window | 0.2 | 0.5 | 22 | 19 | 23 | 0.7 |
| distinct | 1.6 | 0.4 | 1.1 | 2.5 | 6.2 | 4.1 |
| slice_head | 1.1 | 3.7 | 34 | 126 | 107 | — |
| count_by | 0.5 | 0.6 | 4.4 | 29 | 91 | 23 |
| 3-verb pipeline | 1.0 | 0.5 | 37 | 84 | 147 | 29 |

I/O at 10^5 rows (DF / Polars 1t): `read_csv` 5.8 / 5.4, `write_csv` 1.5 / 2.2, `read_arrow`
3.7 / 3.2, `write_arrow` 0.9 / 5.4. The 10^4 column and every row are in
`docs/src/performance.md`.

**Wins:** per-verb overhead on 10-row frames: grouped `summarise`, grouped `mutate`, `count_by`
and `filter` are 2-5× faster than DataFrames.jl and faster than Polars; `select` shares buffers;
`write_arrow` matches DataFrames + Arrow.jl; `distinct` is within 1.1-1.6× of DataFrames at every
size; TTFX (PF-07).
**Losses:** from 10^4 rows on, every row-wise family except `distinct` (and `slice_head` at
10^4 rows, 1.5×) is 3.4-43× slower than DataFrames.jl, and at 10^6 rows 13-126× slower than
single-threaded Polars (`distinct`: 2.5×); `arrange` is the worst (2.9 s for 10^6 Float64 rows,
DataFrames 0.16 s, Polars 0.047 s); `slice_head` costs O(n) (PF-11).

## PF-11 Allocation profile: the interpreter allocates per row

From PF-02 (10^6 rows): `filter` 2.0 allocations per row, `mutate` 3.0, `summarise` 3.0 (1.10:
4.0), grouped window 12, `arrange` 83 (Float64) to 104 (two keys), `slice_head(n = 10)` 90
allocations but 8.0 MB (8 bytes per input row; the time grows with n: 2.8 μs → 89 μs). The
per-row counts are exact multiples of n, which points at boxed per-element work in the eager
interpreter (dynamic dispatch on each element) rather than at the algorithms. That diagnosis is
UNVERIFIED (no profile was taken; `src/` is out of this lane's scope); it is the first thing the
engine work of phase 4 should check (`@code_warntype`/`Profile` on `filter(c.x .> 0)`).

## PF-12 AirspeedVelocity 0.6.6 cannot build ChuiFrames' benchmark environment

Installed in a scratch env (`Pkg.add("AirspeedVelocity")` → 0.6.6). Its Julia API,
`benchmark("ChuiFrames", ["dirty", "feat/p2c-bench"]; path = <worktree>, filter_benchmarks =
["slice_head", "select"])`, found `benchmark/benchmarks.jl` and `benchmark/Project.toml` and failed
while adding its own packages:
```
ERROR: Unsatisfiable requirements detected for package Parsers [69de0a69]:
 ├─restricted by compatibility requirements with CSV [336ed68f] to versions: 3.0.0
 │   └─restricted to versions 1 by ChuiFrames [a485ff65], leaving only versions: 1.0.0 - 1.1.0
 └─restricted by compatibility requirements with JSON3 [0f8b85d8] to versions: 0.3.0 - 2.8.8 — no versions left
```
AirspeedVelocity adds `BenchmarkTools`, `JSON3`, `Pkg`, `TOML` to every benchmark environment
(its source file Utils.jl, function `_benchmark`). JSON3 1.14.3 (latest, marked deprecated in the registry)
caps Parsers at 2.8.8, and CSV 1.1.0 needs Parsers 3. Reproduced without ChuiFrames:
`Pkg.add(["CSV", "JSON3"])` resolves CSV 0.10.17, and `Pkg.add(name = "CSV", version = "1.1")`
then fails with the same conflict. So AirspeedVelocity cannot benchmark ChuiFrames (or any
package that needs CSV 1.x) until it drops JSON3 or JSON3 widens its Parsers bound.
Documented and not filed (user decision, 2026-10-20):
[upstream-airspeedvelocity-json3.md](upstream-airspeedvelocity-json3.md).
Its conventions, read from the 0.6.6 source (so no longer UNVERIFIED for ADR-0011): the script is
`benchmark/benchmarks.jl` and must define `SUITE::BenchmarkGroup`, included inside a module
`AirspeedVelocityRunner`; `benchmark/Project.toml` is copied into the environment when present;
`--filter` keeps the entries whose `/`-joined key contains one of the given substrings; tuning is
off unless `--tune`; it adds a `time_to_load` entry of its own.

## PF-13 The factory gate, `julia scripts/ci.jl bench`

`.lanes/evidence/ci-bench-6250cad.txt`: `bench.jl: no benchmarks at the merge base; nothing to
compare`, `ci.jl bench: OK` (2.2 s). The merge base with `main` has no `benchmark/`, so the gate
compares nothing on this branch; it runs once the suite is on `main`.

The gate's noise floor, with the suite on both sides: `julia scripts/bench.jl --base 6250cad` at
`ad2f852` (no `src/` or `benchmark/benchmarks.jl` difference between the two trees; load average
7.6-7.8) → `.lanes/evidence/bench-gate-vs-6250cad-ad2f852.txt`, exit 1 in 457 s:
```
  REGRESSION io/write_arrow/n=10^5: 1.2x the merge base
  REGRESSION summarise/Int few/n=10^6: 1.138x the merge base
  REGRESSION filter/x > 0/n=10^6: 1.129x the merge base
  REGRESSION io/write_csv/n=10^5: 1.124x the merge base
bench.jl: 4 regressions beyond tolerance 0.1
```
All four are noise: on this shared machine a 10 % tolerance fails identical code, so the gate must
stay warning-only until it runs on a quieter runner (ADR-0011, ADR-0022 rule 6).

## PF-14 The budget checks at 7f0d685 (budgets committed)

| Command | Evidence | Result |
|---|---|---|
| `julia benchmark/run.jl --check` | `bench-check-113-7f0d685.txt` | `run.jl --check: OK (47 benchmarks within budget)` |
| `julia +lts benchmark/run.jl --check` | `bench-check-110-7f0d685.txt` | `run.jl --check: OK (47 benchmarks within budget)` |
| `julia benchmark/ttfx.jl --check` | `ttfx-check-113-7f0d685.txt` | exit 1: load 508.9 [419.0, 579.4] ms, **over** the 500 ms budget; load + first call 542.7 ms OK; precompile 17.4 s OK |
| `julia +lts benchmark/ttfx.jl --check` | `ttfx-check-110-7f0d685.txt` | exit 0: load 617.5 ms, load + first call 693.9 ms, precompile 14.8 s |

The 1.13 load check ran at load average 7.3-7.8 (startup 94 ms against 75 ms in PF-04), so the
1.13 load budget has 0-10 % headroom on this machine. Part of it is the method: `ttfx.jl` stacks
a scratch depot in front of the user depot (so that it can delete and time ChuiFrames' cache).
Five alternating `@time using ChuiFrames` runs in the same environment, with and without such a
stacked depot, gave 0.430-0.459 s with it and 0.392-0.437 s without (about +40 ms and +30 k
allocations with it). The "evidence" files of the ttfx-check runs say DIRTY because docs were
being edited at the time; `benchmark/` was committed.

## UNVERIFIED

- Every absolute number on a quiet machine or on CI runners (x86-64 Linux).
- The cause of the per-row allocations (PF-11) and of the workload's small effect (PF-05).
- Whether Polars 2.0 memory-maps `read_ipc(path)`.
- Medians of the 10^6-row `arrange` entries are 1-2 samples each.
