# Performance evidence (phase 4)

The measurements behind phase 4's benchmark rows and calibrated constants (spec
[§5](../superpowers/specs/2026-10-26-phase4-joins-groupby-codegen-design.md), ADR-0022): the new
`SUITE` entries and their budget rows, `RADIX_SWITCH`, the broadcast limits, the partition bits,
the order-restoring sort's share, parallel eager probes, and db-benchmark-like comparisons against
the previous `main`, DataFrames.jl, Polars and DuckDB. Date: 2026-10-26. Branch `feat/p4-bench`
on `feat/phase4` at `50dbf18` (joins, fast group-by and sinks, compiled kernels merged). Evidence
IDs P4-01…; files under `.lanes/evidence/` (gitignored, machine-local) are written by
`julia scripts/evidence.jl <kind> -- <cmd>` and named `<kind>-<sha7>.txt`.

**Load rule (the user's decision for this lane).** The machine was shared and loaded: the 1-minute
load average was 4.5–16 during the runs (once 72, noted where it applies). Allocation and memory
numbers do not depend on load and are binding. **Every timing below was taken at a 1-minute load
of 2 or more and is INCONCLUSIVE**; each is listed with its load. Budget time rows were set from
these timings by ADR-0022's formula, as phase 2c did under load; the quiet-machine re-run before
the main merge settles the timing checks.

## P4-01 Machine, versions, method

- Apple M3 Pro, 12 cores, 18 GiB, macOS (Darwin 25.6.0). Julia 1.13.2 (`julia`) and 1.10.12
  (`julia +lts`). BenchmarkTools 1.8.0. The `SUITE` runs on 1 thread (`benchmark/run.jl`);
  calibrations ran at 1 and 6 threads (`-t`).
- Comparators: DataFrames.jl 1.8.2 with Arrow.jl 2.8.1 (Julia 1.13.2, 1 thread); Polars 2.0.0
  and DuckDB 1.5.6 with pyarrow 26.0.0 on Python 3.13.13 through `uv run --no-project` (the pins
  of the differential suite), at 1 thread (`POLARS_MAX_THREADS=1`, `SET threads = 1`) and at each
  tool's default (12 threads).
- `main` is `bc8c97a`: a `git archive` of it was unpacked into the session scratchpad and
  developed into its own environment (no repository was touched); `benchmark/compare/chui.jl`
  ran unchanged against it. It has no joins, so its join cells are empty.
- Calibration scripts: `benchmark/calibrate/` (not in `SUITE`). The evidence files were produced
  by the scratch versions of these scripts in `.lanes/scratch/` (the commands in the files name
  that path); the committed copies are the same logic, reformatted, and were parse-checked but not
  re-run. Calibration evidence says `dirty: true`: `benchmark/compare/` and later
  `benchmark/benchmarks.jl` edits were not yet committed; `src/` was unchanged from the named
  commit in every case.
- What a calibration measures: min of 3 (time) after a warm-up, and the bytes one run allocates
  (`@timed`). The sort-share script uses min of 50 (10⁴ rows) or 5 (10⁶ rows).

## P4-02 Finding: two quadratic concatenations dominate memory (load-independent)

Not a calibration result, but it decides how the calibrations can be read.

1. **Lazy gather** (src/columns.jl `vcat_columns`, called when a stage's morsels are
   concatenated): `reduce(vcat, (c.values for c in cols))` takes a **generator**, so Base folds it
   left to right and copies the growing vector once per morsel. On Julia 1.13.2 and 1.10.12, 61
   vectors of 65,536 Float64: the generator form allocates 945.5 MiB in 106 / 60 ms, the
   `Vector`-of-vectors form 30.5 MiB in 7.3 / 5.9 ms (a 31× difference in bytes; a scratch
   one-liner, quoted here, not an evidence file).
2. **Partitioned join** (src/engine/join_shapes.jl `_partitioned_join`):
   `reduce(vcat, pxs; init = Int[])`. The `init` keyword disables Base's preallocating
   `reduce(vcat, ::Vector{<:AbstractVector})`, so the 2ᵖ partitions' pair vectors fold left to
   right. Bytes grow about 4× per 2 extra partition bits (P4-07): 0.75, 1.2, 2.8, 8.6, 31.1 and
   122.6 GiB for p = 2, 4, 6, 8, 10, 12 (x = 4·10⁶ rows, build 2¹⁴ rows;
   `calib-pbits-p0-t6-99c532f.txt`).

`benchmark/calibrate/patch_concat.jl` re-evaluates both functions **in the measuring process
only** with the linear form (no src change). Measured effect (`calib-bc-p0-*`, `calib-bc-p1-*`,
both `f0590cc`), inner join, x = 4·10⁶ rows, build y = 2¹⁷ narrow rows, 1 thread:

| path | as built: time, bytes | linear concat: time, bytes |
|---|---:|---:|
| eager broadcast | 139 ms, 387 MiB | 115 ms, 381 MiB |
| eager partitioned | 1932 ms, 8447 MiB | 247 ms, 664 MiB |
| lazy broadcast | 398 ms, 4117 MiB | 151 ms, 596 MiB |
| lazy partitioned | 2127 ms, 10963 MiB | 254 ms, 821 MiB |

(load 11–20; times inconclusive, bytes binding.) Both files are outside this lane's scope; the
fix is one line each (drop `init`; build a `Vector` instead of a generator), recommended in
"Open" below. It also explains the lazy join losses in P4-08.

## P4-03 `RADIX_SWITCH`: 2¹⁶ → 2²⁰ (changed)

`benchmark/calibrate/radix_switch.jl`: lazy `group_by(:key) ⨟ summarise(sx = sum(c.x), cnt =
n_rows())` (the hash-aggregate sink), n = 4·10⁶ rows, G groups, limit forced through
`_FORCE_RADIX_SWITCH`. Allocated MiB (binding) at the old limit 2¹⁶, 2¹⁸, 2²⁰ and "never"
(2³⁰):

| key, G | 1 thread (as built) | 6 threads (as built) | 1 thread (linear concat) | 6 threads (linear concat) |
|---|---|---|---|---|
| Int, 10⁴ | 197 / 197 / 197 / 197 | 221 / 221 / 221 / 221 | 192 / 192 / 192 / 192 | 205 / 205 / 205 / 205 |
| Int, 10⁵ | **1408** / 303 / 303 / 303 | **1429** / 520 / 519 / 519 | **761** / 257 / 257 / 257 | **747** / 348 / 348 / 348 |
| Int, 5·10⁵ | **2154** / 1823 / 784 / 775 | **2148** / 1862 / 1674 / 1644 | **1235** / 1185 / 551 / 543 | **1240** / 1173 / 1045 / 1060 |
| Int, 2·10⁶ | 3165 / 3169 / 2914 / 2267 | 3185 / 3198 / 3511 / 3401 | 2073 / 2265 / 2144 / 1722 | 2021 / 2306 / 2522 / 2447 |
| String, 10⁴ | 516 / 518 / 516 / 516 | 542 / 542 / 542 / 542 | 509 / 509 / 509 / 509 | 542 / 542 / 542 / 542 |
| String, 10⁵ | **2049** / 638 / 638 / 638 | **2041** / 935 / 935 / 935 | **2034** / 638 / 638 / 642 | **2042** / 935 / 941 / 935 |
| String, 5·10⁵ | **3145** / 2743 / 1263 / 1254 | **3180** / 2828 / 2472 / 2448 | **3194** / 2784 / 1283 / 1265 | **3203** / 2815 / 2475 / 2480 |
| String, 2·10⁶ | 4603 / 4715 / 4242 / 3335 | 4536 / 4677 / 4801 / 4718 | 4600 / 4753 / 4263 / 3316 | 4574 / 4779 / 4818 / 4749 |

Evidence: `calib-radix-t1-f0590cc.txt` (load 5.6–8.8), `calib-radix-t6-f0590cc.txt` (load
7.5–10.3), `calib-radix-p1-t1-f0590cc.txt` (load 5.8–7.5), `calib-radix-p1-t6-f0590cc.txt` (load
4.5–10.1); each file also has 2¹² and 2¹⁴ and the times.

- Between 10⁵ and 5·10⁵ groups, 2¹⁶ allocated 1.2–4.6× the bytes of 2²⁰ in all 16 cells (both
  thread counts, both key types, with and without the concat patch). At 10⁴ groups the limit is
  never reached. At 2·10⁶ groups the limits are within −8 % to +25 % of each other (2²⁰ is the
  highest at 6 threads with the patch, +25 % over 2¹⁶).
- Times (inconclusive) agree: at 10⁵ groups 2²⁰ ran 1.4–2.9× faster than 2¹⁶ in every run
  (e.g. Int, 1 thread, as built: 216.6 → 89.3 ms; String: 873 → 300 ms); at 2·10⁶ groups the
  runs disagree in sign within ±20 %.
- The `SUITE`'s "many" rows (n = 10⁶, n ÷ 10 = 10⁵ groups) sit in the band where 2¹⁶ is worst.
- **Decision:** `RADIX_SWITCH = 1_048_576` (2²⁰), the only line changed in src/engine/hashagg.jl.
  2¹⁸ was rejected: at 5·10⁵ groups it allocated 2.2–2.3× the bytes of 2²⁰ at 1 thread.
  "Never switch" (2³⁰) allocates least at 2·10⁶ groups on 1 thread, but would remove the
  adaptive switch ADR-0003 rule 9 requires; at 6 threads it is not better than 2²⁰.

## P4-04 Broadcast limits: unchanged (131,072 rows, 4 MiB)

**DataFusion check (the spec's UNVERIFIED item).** `datafusion/common/src/config.rs` (main,
fetched 2026-10-26): `hash_join_single_partition_threshold` default `4 * 1024 * 1024`, "The
maximum estimated size in bytes for one input side of a HashJoin will be collected into a single
partition", and `hash_join_single_partition_threshold_rows` default `1024 * 128`. So the 4 MiB is
an estimate of one **input side's** size, as ChuiFrames uses it. One difference:
`datafusion/physical-optimizer/src/join_selection.rs` `supports_collect_by_thresholds` uses the
byte estimate when it is known and the row count **only when bytes are unknown**
(`total_byte_size < threshold_bytes`, else `num_rows < threshold_rows`, else not collectable);
ChuiFrames requires both (`_broadcast_ok`: rows **and** bytes below). Whether DataFusion's byte
estimate is Arrow's in-memory size of the projected input is UNVERIFIED (read from the doc
comment, not traced).

**Measurements** (`benchmark/calibrate/broadcast_limits.jl` part A): inner join, x = 4·10⁶ rows
(keys from 1:b), build y = b distinct keys, broadcast (shape a) vs partitioned (shape c), narrow
(16 nominal bytes per row) and wide (72) build sides.

As built (`calib-bc-p0-t1`, `calib-bc-p0-t6`, `calib-bcast-t1`, `calib-bcast-t6`, all
`f0590cc`, load 7–21, 45 at the end of `calib-bcast-t6`): partitioned was 1.1–24× slower than broadcast at every b from 2¹² to 2²²
except two lazy wide cases (b = 2²¹ and 2²² rows, 144–288 MiB nominal), and allocated 8.2–9.7 GiB
eager against 0.34–1.0 GiB for broadcast. That is P4-02's quadratic concat, not the strategy.

With the linear concat (`calib-bc-p1-t1`, `calib-bc-p1-t6`, load 8.6–17), partitioned/broadcast
time ratios (inconclusive):

| build rows | narrow eager 1t | narrow lazy 1t | narrow eager 6t | narrow lazy 6t | wide eager 1t | wide lazy 1t | wide eager 6t | wide lazy 6t |
|---|---:|---:|---:|---:|---:|---:|---:|---:|
| 2¹⁴ | 2.20 | 1.97 | 1.18 | 3.13 | 1.87 | 1.61 | 1.23 | 2.68 |
| 2¹⁶ | 2.18 | 1.70 | 1.30 | 2.83 | 1.67 | 1.26 | 0.76 | 2.61 |
| 2¹⁷ | 2.15 | 1.69 | 0.86 | 2.27 | 1.42 | 0.88 | 0.88 | 2.08 |
| 2¹⁸ | 1.98 | 1.41 | 0.89 | 2.11 | 1.91 | 0.74 | 1.07 | 1.46 |
| 2²⁰ | 1.00 | 0.86 | 0.47 | 1.16 | 1.17 | 0.68 | 0.64 | 0.97 |
| 2²² | 0.80 | 0.84 | 0.38 | 0.69 | 1.08 | 0.82 | 0.54 | 0.93 |

Bytes (binding): broadcast allocated less than partitioned in every cell (e.g. narrow 2¹⁷: eager
381 vs 664 MiB, lazy 596 vs 821 MiB; wide 2²⁰ lazy: 1288 vs 1303 MiB).

- Eager at 6 threads favours partitioned from 2¹⁷ rows because the eager broadcast probe runs on
  one task (P4-07) while the eager partitioned join spawns tasks: a parallelism gap, not a limit.
- Lazy (parallel probe) at 6 threads favours broadcast up to 2¹⁸ rows narrow (4 MiB nominal) and
  wide (18 MiB nominal), and is at parity near 2²⁰ rows. At 1 thread the crossover is near 2²⁰
  rows narrow and 2¹⁷ rows wide.
- **Decision: no change.** The as-built data are distorted by P4-02; the patched data put the
  crossover at or above the current limits but disagree between thread counts and paths, at load
  ≥ 8. After the concat fix, re-run part A on a quiet machine; the patched data suggest
  `BROADCAST_MAX_ROWS = 2¹⁸` and `BROADCAST_MAX_BYTES = 16 MiB` are the next candidates (UNVERIFIED).
- The 16-byte nominal width of non-bits columns was not recalibrated (no string-keyed or
  string-payload build side was measured): UNVERIFIED, as in ADR-0023.

## P4-05 The new `SUITE` rows (1 thread)

`julia benchmark/run.jl --toml …` at `23881b4`: `.lanes/evidence/bench-113-23881b4.txt` (Julia
1.13.2, exit 0, suite wall time 695.5 s, load 6.6 before / 9.8 after) and
`.lanes/evidence/bench-110-23881b4.txt` (Julia 1.10.12, exit 0, 707.6 s, load 11.2 / 12.9). 138
entries (86 new; `bench-check-113-5689c2e.txt` ends `OK (138 benchmarks within budget)`). Every row: the evidence files and `benchmark/budgets.toml` (each row's comment
is its baseline).

Group-by, 1.13.2 medians (allocs) at 10⁶ rows; eager Int/String are the existing `summarise/*`
rows:

| key | eager few | lazy few | eager many | lazy many |
|---|---:|---:|---:|---:|
| Int | 9.11 ms (477) | 10.66 ms (2,920) | 161.3 ms (2,798,684) | 71.3 ms (800,261) |
| String | 15.33 ms (507) | 31.47 ms (1,003,338) | 234.8 ms (2,998,686) | 191.2 ms (3,195,434) |
| Dict String | 9.29 ms (492) | 11.12 ms (3,068) | 187.9 ms (2,798,755) | 137.4 ms (1,100,504) |
| Int, String | 19.17 ms (606) | 34.98 ms (1,004,116) | 238.9 ms (2,998,882) | 297.3 ms (3,196,359) |

- **The lazy sink allocates once per row for String keys** (1,003,338 allocations for 10⁶ rows,
  Int and dictionary keys 2,920–3,068; same on 1.10) and 87 % more bytes than eager (String few:
  128.5 vs 68.8 MiB). Few groups: the sink is slower than eager at 10⁴ rows for every key kind
  on 1.13 and for all but Int on 1.10, and at 10⁶ rows for String and two-column keys on both
  (inconclusive times; the allocation gap is binding). ADR-0024's trigger "the sink slower than the gathered eager path at
  any measured size" is met: see P4-10.
- Joins at 10⁶ rows, eager, 1.13.2: 1:1 broadcast build y 159.8 ms, build x 202.0 ms, partitioned
  207–223 ms; 1:n broadcast build y 81.4 ms, build x 50.6 ms, partitioned 139–155 ms. Partitioned
  joins allocate 1.3–1.4 GiB at 10⁶ rows against 0.15–0.37 GiB broadcast (P4-02). `nest_join`
  10⁶ rows: 1.02 s, 16,010,027 allocations (16 per x row: one `Frame` each). `cross_join`
  10³ × 10³: 7.98 ms.
- Small x (10³) / large y (10⁶), `:auto`: eager 18.0 ms, lazy 22.5 ms.
- Compiled stage `mutate ⨟ filter ⨟ select` at 10⁶ rows: compiled 14.9 ms (3,887 allocations)
  vs the same stage forced to the interpreter 58.2 ms (3,990,269): 3.9×. ADR-0025's gauge (the
  phase-3 `lazy/filter, mutate, select` forced to the interpreter): 53.7 ms (2,490,662) vs 38.0 ms
  (996,855) under `:auto`.
- `n=10` per-verb rows (ADR-0022 rule 3): `group_by` alone 5.9–7.4 μs; eager group-by with
  `summarise` on dictionary and two-column keys 24–25 μs; every join verb 3.3–11.5 μs (1.13.2;
  1.10.12: 4.1–12.2 μs). All budget rows are ≤ 100 μs, within rule 3's 200 μs cap.
- Existing rows moved by phase 4 (1.13.2, phase-2c/3 baseline → now): `summarise/Int few/n=10^6`
  166 → 9.1 ms, `String few` 144 → 15.3 ms, `Int many` 361 → 161 ms, `String many` 990 → 235 ms;
  `count_by/String few/n=10^6` 176 → 12.4 ms; `lazy/filter, mutate, select/n=10^6` 49.6 →
  38.0 ms (now compiled). Allocations fell by more than half in these rows, so ADR-0022 rule 5
  tightened them (table below). The window row fell 25 % (11,962,606 → 8,973,338), not enough.

**Rule 5 tightening** (allocations and memory only; budget = the rule-2 formula of the new count):

| table | row | budget before → after | baseline → measured |
|---|---|---|---|
| allocs 1.13 | count_by/String few/n=10^4, n=10^6 | 30,000 → 520; 4,500,000 → 520 | 19,608 / 2,989,608 → 345 |
| allocs 1.13 | lazy/filter, mutate, select/n=10^4, n=10^6 | 37,000 → 16,000; 3,800,000 → 1,500,000 | 24,479 → 10,284; 2,490,650 → 996,855 |
| allocs 1.13 | summarise/Int few/n=10^4, n=10^6 | 30,000 → 720; 4,500,000 → 720 | 19,745 / 2,989,745 → 477 |
| allocs 1.13 | summarise/Int many/n=10^6 | 8,700,000 → 4,200,000 | 5,787,602 → 2,798,684 |
| allocs 1.13 | summarise/String few/n=10^4, n=10^6 | 30,000 → 770; 4,500,000 → 770 | 19,775 / 2,989,775 → 507 |
| allocs 1.10 | count_by/String few/n=10^4, n=10^6 | 44,000 → 470; 6,000,000 → 470 | 29,061 / 3,989,061 → 309 |
| allocs 1.10 | lazy/filter, mutate, select/n=10^4, n=10^6 | 37,000 → 16,000; 3,800,000 → 1,500,000 | 24,440 → 10,250; 2,489,491 → 996,516 |
| allocs 1.10 | summarise/Int few/n=10^4, n=10^6 | 44,000 → 660; 6,000,000 → 660 | 29,196 / 3,989,196 → 439 |
| allocs 1.10 | summarise/Int many/n=10^4, n=10^6 | 83,000 → 41,000; 11,000,000 → 4,200,000 | 55,197 → 26,670; 6,786,996 → 2,798,586 |
| allocs 1.10 | summarise/String few/n=10^4, n=10^6 | 44,000 → 710; 6,000,000 → 710 | 29,230 / 3,989,230 → 473 |
| allocs 1.10 | summarise/String many/n=10^6 | 11,000,000 → 4,500,000 | 6,986,919 → 2,998,592 |
| memory 1.10 | summarise/Int few/n=10^6 | 150,000,000 → 61,000,000 | 95,854,160 → 40,065,760 |

No existing row was over its budget in either run (allocations, memory or time), so the memory
rise the ADR-0024 writeup feared for String and two-key `group_by` inputs is not over any budget.

## P4-06 The order-restoring sort's share (★ K2; spec §7 trigger 25 %)

`benchmark/calibrate/sort_share.jl` (`sortshare-t1-f0590cc.txt`, 1 thread, load 6.6–7.1): the
sort's own time plus two gathers by its permutation, as a share of the whole eager join, on the
`SUITE`'s `join_inputs`.

| join, rows | shape (b) build x | shape (c) build y | shape (c) build x | shape (a) (no sort) |
|---|---:|---:|---:|---:|
| inner 1:1, 10⁶ | 8.4 % of 130.2 ms | 5.4 % of 133.8 ms | 5.9 % of 137.6 ms | 113.5 ms |
| inner 1:n, 10⁶ | 17.0 % of 45.9 ms | 6.8 % of 80.9 ms | 5.9 % of 75.1 ms | 76.3 ms |
| left 1:1, 10⁶ | 7.2 % of 128.0 ms | 4.7 % of 158.4 ms | 7.6 % of 127.8 ms | 110.9 ms |
| left 1:n, 10⁶ | 20.4 % of 43.6 ms | 7.0 % of 89.2 ms | 6.0 % of 77.0 ms | 63.2 ms |
| inner 1:1, 10⁴ | 10.0 % | 11.2 % | 6.9 % | 0.35 ms |
| inner 1:n, 10⁴ | 7.6 % | 18.7 % | 14.4 % | 0.23 ms |
| left 1:1, 10⁴ | 18.2 % | 19.0 % | 7.2 % | 0.37 ms |
| left 1:n, 10⁴ | 12.1 % | **27.7 %** of 0.36 ms | 15.0 % | 0.23 ms |

The counting sort itself costs 1.4–6.6 ms per 10⁶ pairs. At 10⁶ rows the share is 4.7–20.4 %
in every case. One 10⁴-row case is above 25 % (27.7 %, 0.10 ms of 0.36 ms, at load 6.7), within
the noise of a sub-millisecond timing on a loaded machine.

## P4-07 Parallel eager probes, the spawn trigger, partition bits

**Parallel eager broadcast probe** (`benchmark/calibrate/broadcast_limits.jl` part B,
`calib-parprobe-t6-f0590cc.txt`, 6 threads, load 14.8–16.0, inconclusive): the shape-(a) probe
on k tasks over contiguous x slices (including the cost of slicing x and concatenating), against
one task:

| probe rows | build 2¹⁰ rows: best speed-up | build 2¹⁷ rows |
|---|---:|---:|
| 16,384 | 0.96× | 1.08× |
| 65,536 | 1.36× | 1.35× |
| 262,144 | 1.49× | 1.60× |
| 10⁶ | 1.89× | 1.76× |
| 4·10⁶ | 1.51× | 1.91× |

Recommendation: probe in parallel above 65,536 probe rows when `Threads.nthreads() > 1`, as the
spec's §1.2 "Eager" note says, splitting x into contiguous ranges (ADR-0003 rule 6) and
concatenating in order; below that, keep the calling task (no gain at 16,384 rows). The slicing in
this experiment is a `take` per column; an implementation inside the probe would avoid it, so the
measured speed-ups are a lower bound (UNVERIFIED).

**Eager partitioned spawn trigger** (`nx + ny >= 65_536`): keep it as a sum. The partitioned work
(hash, partition, per-partition build and probe) scales with nx + ny, and the probe experiment
above shows parallelism paying from about 65,536 rows of work. Under `:auto` an eager join is
partitioned only when its build side passes the broadcast limits (≥ 131,072 rows or ≥ 4 MiB), so
the sum is always above the trigger there; a per-side trigger would change only forced joins.
What is worth adding is a floor per task: `nt = min(nthreads, 2^p, (nx + ny) ÷ 32_768)` (about
16 k rows per task, from the 16,384-row probe result), so small forced joins do not spawn idle
tasks.

**Partition bits p** (`benchmark/calibrate/partition_bits.jl`: `_partitioned_join` called with a
chosen p, inner join, x = 4·10⁶ rows, build y = b rows):

- As built (`calib-pbits-p0-t6-99c532f.txt`, load 6.1–8.5): bytes grow 4× per 2 bits from p = 4:
  b = 2¹⁷: 1.2 GiB at p = 4, 8.3 GiB at p = 8 (today's formula for 4·10⁶ rows), 122.7 GiB at
  p = 12. Today's formula picks p = 8 for any larger side of 2²¹ rows or more, the worst choice
  until P4-02 is fixed.
- With the linear concat (`calib-pbits-p1-t1-99c532f.txt`, `calib-pbits-p1-t6-99c532f.txt`, load
  6.2–7.2): p = 4 was fastest for b ≤ 2²⁰ at both thread counts (1 thread: 124–204 ms against
  233–303 ms at p = 8) and allocated the least except p = 12; at b = 2²² rows and 6 threads p = 8
  to 12 were 11–17 % faster than p = 4.
- Recommendation (not implemented; src/engine/join.jl's `_partition_bits` and join_shapes.jl are
  out of scope): first fix P4-02; then compute p from the **build** side, not the larger side:
  `p = build_rows < 2^21 ? 4 : clamp(ceil(Int, log2(build_rows)) - 14, 4, 10)`, and keep
  `2^p ≥ nthreads` so every task gets a partition range. Re-measure on a quiet machine.

## P4-08 db-benchmark-like group-by and join at 10⁷ rows

`benchmark/compare/` (README there for the queries and commands), N = 10⁷ (no fallback needed:
the runs fit in memory). Data: `cmp-gen-99c532f.txt`. ChuiFrames: `cmp-chui-99c532f.txt` (load
6.0–8.1); `main`: `cmp-main-99c532f.txt` (6.6–8.5); DataFrames.jl: `cmp-df-99c532f.txt`
(6.9–8.3); Polars and DuckDB: `cmp-py-t1-99c532f.txt` (6.7–7.5), `cmp-py-tn-99c532f.txt`
(6.4). Minimum of 3 runs after a warm-up; every number inconclusive (load ≥ 6). Ratios use
ChuiFrames' faster path (eager or lazy) over the other tool; **above 1, ChuiFrames is slower**.

| query | Chui eager | Chui lazy | main eager | main lazy | DataFrames | Polars 1t | DuckDB 1t | Polars 12t | DuckDB 12t | Chui / DF | / Polars 1t | / DuckDB 1t |
|---|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|
| groupby q1 | 149 ms | 297 ms | 920 ms | 2.71 s | 178 ms | 56 ms | 97 ms | 9 ms | 19 ms | 0.8× | 2.7× | 1.5× |
| groupby q2 | 406 ms | 566 ms | 1.53 s | 4.04 s | 341 ms | 230 ms | 190 ms | 80 ms | 31 ms | 1.2× | 1.8× | 2.1× |
| groupby q3 | 640 ms | 765 ms | 1.40 s | 4.27 s | 1.14 s | 599 ms | 213 ms | 107 ms | 79 ms | 0.6× | 1.1× | 3.0× |
| groupby q4 | 193 ms | 91 ms | 827 ms | 2.96 s | 24 ms | 44 ms | 40 ms | 7 ms | 7 ms | 3.9× | 2.1× | 2.3× |
| groupby q5 | 529 ms | 224 ms | 1.07 s | 3.72 s | 48 ms | 258 ms | 142 ms | 78 ms | 75 ms | 4.7× | 0.9× | 1.6× |
| join q1 | 486 ms | 3.49 s | — | — | 540 ms | 124 ms | 765 ms | 40 ms | 94 ms | 0.9× | 3.9× | 0.6× |
| join q2 | 717 ms | 3.82 s | — | — | 120 ms | 127 ms | 879 ms | 52 ms | 93 ms | 6.0× | 5.6× | 0.8× |
| join q3 | 684 ms | 4.68 s | — | — | 191 ms | 140 ms | 888 ms | 60 ms | 117 ms | 3.6× | 4.9× | 0.8× |
| join q1r (small x) | 714 ms | 3.87 s | — | — | 63 ms | 105 ms | 725 ms | 61 ms | 87 ms | 11.4× | 6.8× | 1.0× |

- **Wins.** Against `main`, eager group-by is 2.0–6.2× faster (q1 920 → 149 ms) and lazy
  group-by 5.6–33× faster (q4 2.96 s → 91 ms). Group-by q1 and q3 beat DataFrames.jl; q3 and q5
  are within 1.1× of single-threaded Polars (q5 lazy 224 ms vs 258 ms); eager joins q1–q3 beat
  single-threaded DuckDB (which also materializes its result into a table) and q1 matches
  DataFrames.jl.
- **Losses.** Group-by q4 and q5 are 3.9–4.7× slower than DataFrames.jl (24 and 48 ms for 100 and
  10⁵ Int groups); every query is 1.1–6.8× slower than single-threaded Polars except q5, and
  3–17× slower than the faster of Polars and DuckDB at their default 12 threads (ChuiFrames ran on
  1 thread). Joins q2,
  q3 and q1r are 3.6–11.4× slower than DataFrames.jl. **Lazy joins are 5–7× slower than eager
  joins** (3.5–4.7 s): at 10⁷ rows the lazy gather concatenates about 150 morsels through P4-02's
  quadratic fold. Lazy group-by q1–q3 (String keys) is slower than eager (P4-05's per-row
  allocation).
- data.table, dplyr, Tidier.jl and pandas are deferred to phase 7 ("Docs and the benchmark
  report"; spec §5, brief "Benchmarks").

## P4-09 Load, TTFX and the budget checks

`benchmark/ttfx.jl` at `3b27d7f` (no change to the precompile workload in this lane; the
`benchmark/ttfx.jl` mirror of `src/ChuiFrames.jl`'s workload was checked and is in sync):


| Julia | load avg | load | first call | load + first call | cold | precompile | evidence |
|---|---|---:|---:|---:|---:|---:|---|
| 1.13.2 | 8.1–11.4 | 420.7 [409.7, 457.9] ms | 38.1 [37.4, 39.7] ms | 458.8 [447.2, 497.6] ms | 1487 + 48.5 ms | 16.6 [16.6, 16.8] s | `ttfx-113-3b27d7f.txt` |
| 1.10.12 | 8.2–10.8 | 597.5 [586.9, 614.3] ms | 72.5 [71.2, 73.7] ms | 670.1 [658.8, 687.8] ms | 1507 + 75.7 ms | 16.6 [15.7, 16.8] s | `ttfx-110-3b27d7f.txt` |

Warm medians [min, max] of 10 fresh processes; all within the ADR-0022 rule 4 budgets
(500 / 700 ms on 1.13, 800 / 1000 ms on 1.10, 60 s precompile), at load ≥ 8 (inconclusive).
Against phase 2c (PF-04): load 448 → 421 ms (1.13) and 626 → 598 ms (1.10); first call 33 →
38 ms and 58 → 73 ms (the workload now includes a compiled lazy collect).

The `--check` runs of `benchmark/run.jl` and `benchmark/ttfx.jl` on both versions at the lane's
final commit are listed, with their evidence names and load averages, in the lane report
(`.lanes/reports/p4-bench.md`); allocation and memory rows must pass there, and time rows are
recorded with their load.

## P4-10 Revisit triggers (spec §7; ADRs 0023–0025)

| trigger | measured | verdict |
|---|---|---|
| order-restoring sort > 25 % of a shape-(b)/(c) join (ADR-0023) | 4.7–20.4 % at 10⁶ rows; one 10⁴ case 27.7 % (0.10 of 0.36 ms) | not met at 10⁶; the 10⁴ case is inconclusive (sub-ms, load 6.7): re-run on a quiet machine |
| small-x/large-y join > 2× slower than DuckDB (ADR-0023) | q1r: eager 714 ms vs DuckDB 1 thread 725 ms (1.0×); lazy 3.87 s (5.3×); vs DuckDB 12 threads: eager 8.2× | **met for lazy** (single-threaded like for like); the cause is P4-02's gather, not shapes (b)/(c): eager, which uses the same shape, is at parity |
| join behind a non-key `mutate` > 1.5× slower than without (ADR-0023) | `lazy/inner join, non-key mutate before` vs `after`, 10⁶ rows: 106.6 vs 114.3 ms (1.13), 49.1 vs 58.0 ms (1.10); bytes 650 vs 469 MiB (1.13) | not met (0.85–0.93×; +39 % bytes) |
| lazy group-by sink slower than the gathered eager path at any size (ADR-0024) | few groups at 10⁴ rows: every key kind on 1.13, all but Int on 1.10; String and two-column keys at 10⁶ on both | **met** (times inconclusive; the String-key sink's 1 allocation per row and +87 % bytes are binding) |
| `drop = false` over pruned partitions > 2× slower than `drop = true` (ADR-0024) | 5.12 vs 4.90 ms (1.13), 4.57 vs 4.77 ms (1.10) | not met (~1.0×) |
| interpreter per-step cost moved > 2× (ADR-0025) | the gauge row 53.7 ms at 10⁶ rows (3 steps, ~18 ns/row/step, half of the rows past the filter) vs codegen-phase4.md's ~20 ns/row/step | not met (no baseline row existed; this row is the baseline) |
| compiled-stage row disagrees with the research table > 2× (ADR-0025) | 14.9 ms per 10⁶ rows for a 3-step stage with a filter (≈ 15 ns/row) vs the table's 15.7 ns/row (3 steps) | not met |

## Open (for the lead)

1. Fix P4-02 (two one-line changes outside this lane: src/columns.jl `vcat_columns`, and
   src/engine/join_shapes.jl `_partitioned_join`), then re-run
   `benchmark/calibrate/broadcast_limits.jl` and `partition_bits.jl` on a quiet machine before
   changing `BROADCAST_MAX_*` or `_partition_bits`.
2. The String-key hash-aggregate sink allocates per row (P4-05); ADR-0024's trigger asks for the
   routing or the sink to change.
3. Parallel eager broadcast probes above 65,536 probe rows (P4-07).

## UNVERIFIED

- Every timing (load ≥ 2 throughout). The quiet-machine re-run settles them.
- DataFusion's byte estimate as Arrow in-memory size; ChuiFrames' 16-byte nominal width.
- The speed-up of a native parallel probe (P4-07 measured a slice-and-concatenate stand-in).
- The committed `benchmark/calibrate/` copies were parse-checked, not re-run (P4-01).
