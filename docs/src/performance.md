# Performance

ChuiFrames 0.0.1 (phase 2, eager and single-threaded) is **fast to start and fast on small
frames, and slow on large ones**. On a 10-row frame most verbs cost 3-36 μs, and grouped verbs are
2-5× faster than DataFrames.jl. From 10^4 rows on, every row-wise verb except `distinct` (and
`slice_head` at 10^4 rows) is 3.4-43× slower than DataFrames.jl, and at 10^6 rows 13-126×
slower than single-threaded Polars (`distinct`: 2.5×). The engine work of later phases targets that gap
(ADR-0003; budgets and targets in ADR-0022). The numbers below come from
`docs/research/performance.md` (evidence PF-01 to PF-13).

!!! warning "Measured on a shared machine"
    Apple M3 Pro, Julia 1.13.2, 1 thread, 2026-10-20, with other jobs running (load average 8-16
    during the comparison runs). Absolute times are inflated and noisy; ratios measured minutes
    apart are more reliable. UNVERIFIED on a quiet machine and on Linux.

## Start-up

Fresh processes, median [min, max] of 10 warm runs. "First call" builds a 4-row frame, runs
`filter |> mutate |> group_by |> summarise |> arrange`, prints the result, and writes and reads
it back as Arrow IPC and CSV.

| | load (`using`) | first call | load + first call |
|---|---:|---:|---:|
| ChuiFrames, Julia 1.13.2 | 448 [404, 527] ms | 33 [28, 41] ms | 481 [438, 559] ms |
| ChuiFrames, Julia 1.10.12 | 626 [587, 715] ms | 58 [54, 77] ms | 683 [642, 789] ms |
| DataFrames.jl 1.8.2 + CSV + Arrow, 1.13.2 | 581 [534, 664] ms | 8.28 [7.66, 8.62] s | 8.83 [8.30, 9.22] s |

Precompiling ChuiFrames itself takes about 16 s on 1.13.2 and 14 s on 1.10.12.

## Speed against DataFrames.jl, Polars and DuckDB

The same operations on the same data (columns `id`, `x` normal, `y` uniform, `k`/`s` with 10
groups, `kk`/`ss` with n ÷ 10 groups; seed 20261020). The ratio is ChuiFrames' median divided by
the other tool's median: **above 1, ChuiFrames is slower**.

- DataFrames.jl 1.8.2 (CSV 1.1.0, Arrow 2.8.1), same Julia session type. Its `select` copies the
  columns while ChuiFrames' shares them, so that row is not like-for-like.
- Polars 2.0.0 (Python 3.13), eager API, once with 1 thread (`POLARS_MAX_THREADS=1`, **the
  like-for-like run**: ChuiFrames phase 2 is single-threaded) and once with its default 12 threads.
- DuckDB 1.5.6 with 1 thread; each query materializes its result into a table.

| benchmark | ChuiFrames | DataFrames.jl | ratio | Polars 1 thread | ratio | Polars default | ratio | DuckDB 1 thread | ratio |
|---|---:|---:|---:|---:|---:|---:|---:|---:|---:|
| arrange/Float64/n=10 | 5.2 μs | 3.0 μs | 1.7× | 7.8 μs | 0.7× | 40.7 μs | 0.1× | 148.7 μs | 0.035× |
| arrange/Float64/n=10^4 | 18.9 ms | 516.1 μs | 37× | 157.8 μs | 120× | 327.4 μs | 58× | 1.4 ms | 13× |
| arrange/Float64/n=10^6 | 2.93 s | 162.1 ms | 18× | 47.4 ms | 62× | 22.3 ms | 132× | 145.8 ms | 20× |
| arrange/Int, desc Float64/n=10 | 7.3 μs | 5.3 μs | 1.4× | 15.0 μs | 0.5× | 45.3 μs | 0.2× | 156.0 μs | 0.047× |
| arrange/Int, desc Float64/n=10^4 | 35.8 ms | 825.2 μs | 43× | 905.8 μs | 40× | 541.1 μs | 66× | 1.5 ms | 23× |
| arrange/Int, desc Float64/n=10^6 | 5.83 s | 204.0 ms | 29× | 224.2 ms | 26× | 45.7 ms | 128× | 150.6 ms | 39× |
| arrange/String/n=10 | 5.1 μs | 3.2 μs | 1.6× | 11.9 μs | 0.4× | 39.3 μs | 0.1× | 149.5 μs | 0.034× |
| arrange/String/n=10^4 | 23.6 ms | 1.9 ms | 12× | 1.5 ms | 16× | 590.8 μs | 40× | 1.6 ms | 15× |
| arrange/String/n=10^6 | 3.58 s | 862.6 ms | 4.1× | 246.6 ms | 15× | 48.5 ms | 74× | 159.9 ms | 22× |
| count_by/String few/n=10 | 20.2 μs | 42.7 μs | 0.5× | 34.5 μs | 0.6× | 132.1 μs | 0.2× | 128.5 μs | 0.2× |
| count_by/String few/n=10^4 | 1.4 ms | 297.3 μs | 4.8× | 213.0 μs | 6.7× | 633.5 μs | 2.3× | 204.8 μs | 7.0× |
| count_by/String few/n=10^6 | 175.9 ms | 40.0 ms | 4.4× | 6.1 ms | 29× | 1.9 ms | 91× | 7.5 ms | 23× |
| distinct/Int, String/n=10 | 13.1 μs | 8.1 μs | 1.6× | 31.9 μs | 0.4× | 141.4 μs | 0.093× | 100.2 μs | 0.1× |
| distinct/Int, String/n=10^4 | 204.8 μs | 135.6 μs | 1.5× | 217.5 μs | 0.9× | 219.9 μs | 0.9× | 192.7 μs | 1.1× |
| distinct/Int, String/n=10^6 | 37.9 ms | 35.7 ms | 1.1× | 15.0 ms | 2.5× | 6.1 ms | 6.2× | 9.2 ms | 4.1× |
| filter/x > 0/n=10 | 8.1 μs | 13.6 μs | 0.6× | 63.0 μs | 0.1× | 41.8 μs | 0.2× | 105.1 μs | 0.077× |
| filter/x > 0/n=10^4 | 388.0 μs | 46.0 μs | 8.4× | 53.9 μs | 7.2× | 52.1 μs | 7.5× | 614.9 μs | 0.6× |
| filter/x > 0/n=10^6 | 76.4 ms | 3.1 ms | 25× | 3.2 ms | 24× | 1.9 ms | 40× | 51.0 ms | 1.5× |
| io/read_arrow/n=10^5 | 2.4 ms | 655.1 μs | 3.7× | 760.7 μs | 3.2× | 916.5 μs | 2.7× | — | — |
| io/read_csv/n=10^5 | 51.4 ms | 8.8 ms | 5.8× | 9.5 ms | 5.4× | 3.3 ms | 16× | — | — |
| io/write_arrow/n=10^5 | 6.5 ms | 7.6 ms | 0.9× | 1.2 ms | 5.4× | 1.2 ms | 5.4× | — | — |
| io/write_csv/n=10^5 | 26.3 ms | 18.1 ms | 1.5× | 11.8 ms | 2.2× | 4.2 ms | 6.3× | — | — |
| mutate/z = 2x + y/n=10 | 35.8 μs | 12.3 μs | 2.9× | 14.0 μs | 2.6× | 14.0 μs | 2.6× | 111.6 μs | 0.3× |
| mutate/z = 2x + y/n=10^4 | 419.1 μs | 30.1 μs | 14× | 18.6 μs | 23× | 17.9 μs | 23× | 947.6 μs | 0.4× |
| mutate/z = 2x + y/n=10^6 | 50.9 ms | 2.2 ms | 23× | 975.9 μs | 52× | 916.8 μs | 56× | 83.9 ms | 0.6× |
| pipeline/filter, mutate, select/n=10 | 31.1 μs | 31.8 μs | 1.0× | 65.8 μs | 0.5× | 98.3 μs | 0.3× | 83.6 μs | 0.4× |
| pipeline/filter, mutate, select/n=10^4 | 843.2 μs | 74.7 μs | 11× | 76.2 μs | 11× | 114.3 μs | 7.4× | 182.9 μs | 4.6× |
| pipeline/filter, mutate, select/n=10^6 | 295.1 ms | 7.9 ms | 37× | 3.5 ms | 84× | 2.0 ms | 147× | 10.3 ms | 29× |
| select/2 columns/n=10 | 5.0 μs | 5.8 μs | 0.9× | 23.9 μs | 0.2× | 25.9 μs | 0.2× | — | — |
| select/2 columns/n=10^4 | 4.7 μs | 8.4 μs | 0.6× | 14.4 μs | 0.3× | 27.4 μs | 0.2× | — | — |
| select/2 columns/n=10^6 | 4.5 μs | 370.3 μs | 0.012× | 14.2 μs | 0.3× | 27.9 μs | 0.2× | — | — |
| slice_head/n = 10/n=10 | 2.8 μs | 2.6 μs | 1.1× | 750.0 ns | 3.7× | 750.0 ns | 3.7× | — | — |
| slice_head/n = 10/n=10^4 | 4.0 μs | 2.6 μs | 1.5× | 750.0 ns | 5.3× | 750.0 ns | 5.3× | — | — |
| slice_head/n = 10/n=10^6 | 89.2 μs | 2.6 μs | 34× | 709.0 ns | 126× | 833.0 ns | 107× | — | — |
| summarise/Int few/n=10 | 26.1 μs | 107.8 μs | 0.2× | 36.4 μs | 0.7× | 90.1 μs | 0.3× | 149.0 μs | 0.2× |
| summarise/Int few/n=10^4 | 2.0 ms | 157.4 μs | 13× | 159.0 μs | 12× | 597.0 μs | 3.3× | 185.9 μs | 11× |
| summarise/Int few/n=10^6 | 166.0 ms | 4.3 ms | 38× | 4.4 ms | 38× | 1.6 ms | 103× | 4.4 ms | 37× |
| summarise/Int many/n=10^4 | 2.7 ms | 121.5 μs | 22× | 193.1 μs | 14× | 359.5 μs | 7.6× | 220.1 μs | 12× |
| summarise/Int many/n=10^6 | 361.0 ms | 9.7 ms | 37× | 26.2 ms | 14× | 8.7 ms | 41× | 21.3 ms | 17× |
| summarise/String few/n=10 | 21.5 μs | 133.8 μs | 0.2× | 41.3 μs | 0.5× | 143.9 μs | 0.1× | 158.0 μs | 0.1× |
| summarise/String few/n=10^4 | 1.5 ms | 395.8 μs | 3.8× | 218.2 μs | 6.8× | 703.4 μs | 2.1× | 254.0 μs | 5.8× |
| summarise/String few/n=10^6 | 144.3 ms | 42.5 ms | 3.4× | 7.5 ms | 19× | 2.3 ms | 62× | 10.2 ms | 14× |
| summarise/String many/n=10^4 | 3.1 ms | 884.0 μs | 3.5× | 318.5 μs | 9.8× | 547.5 μs | 5.7× | 370.8 μs | 8.5× |
| summarise/String many/n=10^6 | 990.1 ms | 156.1 ms | 6.3× | 78.7 ms | 13× | 14.8 ms | 67× | 35.5 ms | 28× |
| window/row_number, cumsum by Int few/n=10 | 26.2 μs | 116.7 μs | 0.2× | 47.8 μs | 0.5× | 116.2 μs | 0.2× | 382.3 μs | 0.069× |
| window/row_number, cumsum by Int few/n=10^4 | 1.7 ms | 382.4 μs | 4.4× | 226.8 μs | 7.4× | 330.4 μs | 5.1× | 3.4 ms | 0.5× |
| window/row_number, cumsum by Int few/n=10^6 | 256.1 ms | 11.8 ms | 22× | 13.3 ms | 19× | 11.3 ms | 23× | 370.8 ms | 0.7× |

What the table says:

- **Wins:** small frames (10 rows: grouped `summarise`, grouped `mutate`, `count_by` and `filter`
  beat DataFrames.jl and Polars); `select` (shared buffers); `write_arrow` (on par with
  DataFrames + Arrow.jl); `distinct` (within 1.1-1.6× of DataFrames.jl at every size); and the
  time to a first result.
- **Losses:** everything row-wise from 10^4 rows on. The worst is `arrange` (2.9 s for 10^6
  Float64 rows; Polars 47 ms single-threaded). The allocation counts grow with the row count (2
  per row for `filter`, 3 for `mutate`, 83 for `arrange`), so the eager interpreter does per-row
  boxed work; `slice_head` copies O(n) bytes. See PF-11.

## Running the benchmarks

```sh
julia benchmark/run.jl              # the table (median, min, max, samples, allocs, memory)
julia benchmark/run.jl --check      # against benchmark/budgets.toml (ADR-0022)
julia benchmark/ttfx.jl --check     # load, first call, precompile in fresh processes
julia +lts benchmark/run.jl --check # the same on the LTS (its own manifest)
julia scripts/ci.jl bench           # HEAD against the merge base (regression gate)
```

The suite is `benchmark/benchmarks.jl` (a BenchmarkTools `SUITE`, public API only). The full
suite takes about 4-5 minutes.
