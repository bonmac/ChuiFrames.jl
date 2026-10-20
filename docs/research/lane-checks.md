# Lane-owner checks (phase 1)

Small checks the phase-1 lane owner ran to confirm the researchers' claims that the ADRs rely on
most, or to fill a gap. Date: 2026-10-20. Julia 1.13.2 (`julia`) and 1.10.12 (`julia +lts`),
both with `--startup-file=no`, run in the session scratchpad.

## LC-01 A module exporting its own `filter` hides Base's (re-runs PJ-08)

Script:
```julia
module M; export filter; filter(x::Int) = x; end
using .M
try; println(filter(iseven, 1:4)); catch e; println(typeof(e), ": ", sprint(showerror, e)[1:min(end,120)]); end
```
Output on 1.13.2:
```
UndefVarError: UndefVarError: `filter` not defined in `Main`
Hint: It looks like two or more modules export different bindings with thi
```
Output on 1.10.12:
```
WARNING: both M and Base export "filter"; uses of it in module Main must be qualified
UndefVarError: UndefVarError: `filter` not defined
```
Conclusion: on both versions, a new exported binding of a Base name breaks unqualified use of
Base's function. CF-009's rule (add methods, never new bindings) is necessary, not stylistic.

## LC-02 InvertedIndices has no registered dependencies

Extracted `I/InvertedIndices` from the local General registry tarball:
- `Versions.toml`: latest `1.3.1`.
- `Deps.toml`: only `["1.0"] Test = …` (the 1.0 line only); 1.1 and later have no dependencies.
- `Compat.toml`: `["1.3-1"] julia = "1.6.0-1"`, so 1.3.x supports Julia 1.10.

Its export list (`InvertedIndex`, `InvertedIndices`, `Not`) and `[1,2,3][Not(2)] == [1, 3]` are
GR-07 in [grammar.md](grammar.md).

## LC-03 Statistics and Dates standard libraries on both Julia versions

Script: `using Statistics, Dates`, then print `pkgversion` of each and the Statistics exports that
Base also exports.
```
1.13.2 Statistics 1.11.2 Dates 1.11.0
Statistics exports with Base clash? Symbol[]
1.10.12 Statistics 1.10.0 Dates nothing
Statistics exports with Base clash? Symbol[]
```
Statistics carries a version on both, so a `[compat]` entry can bound it. Dates has no package
version on 1.10.12. Whether Pkg accepts and enforces a `Dates` compat entry on 1.10 was not
checked (UNVERIFIED).

## LC-04 Polars writes string views by default, and Arrow.jl reads its IPC files as empty

Polars 2.0.0 through `uv run --no-project --python 3.13 --with polars --with pyarrow`: a frame with
string columns `a = ["x","yy"]`, `b = ["y","zz"]` written with `write_ipc` (file),
`write_ipc(…; compat_level = pl.CompatLevel.oldest())` and `write_ipc_stream`; schemas read back
with pyarrow 26:
```
polars 2.0.0 write_ipc schema: a: string_view / b: string_view
compat oldest: a: large_string / b: large_string
stream: a: string_view / b: string_view
parquet: a: large_string / b: large_string
```
pyarrow reads the default file as 1 record batch of 2 rows. Arrow.jl 2.8.1 (Julia 1.13.2):
```
pv/f.arrow => KeyError: KeyError: key :a not found      # Arrow.Table: names=Symbol[] len=0
pv/c.arrow => KeyError: KeyError: key :a not found      # also empty with large_string
pv/s.arrow => Union{Missing, String}["x", "yy"] Union{Missing, String}["y", "zz"]
```
Conclusion: Arrow.jl 2.8.1 returns a table **with no columns and no error** for Polars IPC
*file*-format output, whichever string layout is used. It reads this stream file correctly.
**Limit:** every string here is at most 12 bytes, so it is stored inline and no variadic data
buffers exist. This does **not** test the case that fails in ST-03 (#590). The storage critic
also found that reading the file as a stream from byte 9 (`Arrow.Stream`) finds no batches, and
that the file has no stream-style message prefix after its magic bytes (hex dump). A reader must
use the footer. The cause was not traced (UNVERIFIED). Polars is
one of the brief's differential and benchmark references, so this is a silent-wrong-result risk
for the read path.

## LC-05 The concrete `StringView` element type

StringViews 1.3.7 (the version Arrow.jl 2.8.1 allows), Julia 1.13.2:
`StringView(view(d, 1:5))` with `d::Vector{UInt8}` has type
`StringView{SubArray{UInt8, 1, Vector{UInt8}, Tuple{UnitRange{Int64}}, true}}`, which is concrete;
it compares `==` and hashes equal to the `String` `"hello"`.

## LC-06 Engine probes P1–P5 (from the engine critic, re-run by the lane owner)

The script was written by the engine critic in the session scratchpad (`critic-engine/probes.jl`)
and re-run here with `julia --startup-file=no -t 4 probes.jl` and `julia +lts --startup-file=no -t 4
probes.jl`. It checks:
- P1: the exception type through `fetch` and `@sync`;
- P2: NaN and signed-zero key semantics against a multiplicative hash of the raw bits;
- P3: whether two closure kernels lower to the same code;
- P4: whether Base exports anything about cancellation;
- P5: string concatenation when one task folds morsels 1 and 3.

```
1.13.2 threads=4
P1 eager=ArgumentError fetch=TaskFailedException @sync=CompositeException
P2 isequal(NaN,-NaN)=true bits equal=false bits(0/0)==bits(NaN)=true hash equal=true
P2 Dict groups=1
P2 radix part NaN=9135551844121051136 -NaN=18358923880975826944
P2 0.0==-0.0 true isequal false
P3 code_lowered identical for shapes A and B: true
P4 Base has cancel-ish: Symbol[]
P5 ReduceM(*) strings: 125634 vs 123456
1.10.12 threads=4
P1 eager=MethodError fetch=TaskFailedException @sync=CompositeException
(P2–P5 identical to 1.13.2)
```
(The P2 "radix part" line prints the shifted product without masking to 6 bits; the two values
differ, which is the point: the raw-bit hash splits `NaN` and `-NaN`.)

## LC-07 dplyr 1.2.0: NaN/NA order, signed zeros, `!=` on NaN, non-logical predicates

`Rscript lc7.R` (scratchpad), dplyr 1.2.0, R 4.4.2:
```
arrange(x)       i: 3 1 2 4 5  is.nan: FALSE FALSE TRUE TRUE FALSE     # x = NA NaN 2 NaN NA
arrange(desc(x)) i: 3 1 2 4 5
signed zeros arrange i: 1 2 3 4                                        # x = 0 -0 0 -0
filter(x != 1) i: 3                                                    # x = 1 NaN 2
int predicate: ℹ In argument: `f`. Caused by error: ! `..1` must be a logical vector, not a double vector.
```
Julia 1.13.2: `sortperm([0.0,-0.0,0.0,-0.0]) == [2, 4, 1, 3]`;
`union((x=[1,2],),(x=[2,3],)) == [[1, 2], [2, 3]]` (Base's `union`);
`findall(x->x===true,[1,0,1]) == Int64[]`.

Conclusions:
- dplyr treats NaN and NA as **one tie class**, last in both directions, in input order.
- dplyr ties `0` and `-0`, where Julia's `isless` orders `-0.0` first.
- dplyr's `!=` drops NaN rows.
- dplyr rejects a non-logical predicate.
- Base's `union` takes plain Tables.jl inputs to Base's own method.

## LC-09 The proposed core dependency set resolves together and loads in about 0.23 s (1.13.2) and 0.41 s (1.10.12)

Script `core_budget.jl` (scratchpad): a fresh project on each Julia version, adding Tables,
DataAPI, InvertedIndices, StringViews (`1`), Arrow (`2.8`), PrecompileTools, CSV (`1`),
TranscodingStreams, CodecZstd and CodecLz4, then counting manifest entries.
```
1.13.2 manifest entries=61 non-jll=51 jll=10 stdlib(unversioned)=0
Tables@1.14.0 DataAPI@1.16.0 InvertedIndices@1.3.1 StringViews@1.3.7 Arrow@2.8.1 PrecompileTools@1.3.4 CSV@1.1.0 TranscodingStreams@0.11.3 CodecZstd@0.8.7 CodecLz4@0.4.6
1.10.12 manifest entries=60 non-jll=51 jll=9 stdlib(unversioned)=12
Tables@1.14.0 DataAPI@1.16.0 InvertedIndices@1.3.1 StringViews@1.3.7 Arrow@2.8.1 PrecompileTools@1.2.1 CSV@1.1.0 TranscodingStreams@0.11.3 CodecZstd@0.8.7 CodecLz4@0.4.6
```
Load, three warm runs after a first (precompiling) run: `@time using Tables, DataAPI,
InvertedIndices, StringViews, Arrow, PrecompileTools, CSV, TranscodingStreams, CodecZstd,
CodecLz4, Statistics, Dates`:
```
1.13.2:  0.226 s, 0.238 s, 0.224 s   (322.45 k allocations: 23.140 MiB)
1.10.12: 0.390 s, 0.442 s, 0.416 s   (568.36 k allocations: 46.369 MiB)
```
On 1.13.2, "manifest entries" counts the stdlibs too, so it reports 0 unversioned. On 1.10.12,
12 stdlibs have no version.

Pitfall seen while setting this up: `Pkg.add` with no version constraint picked **Arrow 2.7.4**
so that it could install StringViews 2.0.1. The compat entries must be in place when packages
are first added (ADR-0009).

## LC-08 Coexistence with DataFrames 1.8.2 (the grammar critic's probe, re-run on 1.13.2)

The probe `critic-grammar/p2.jl` (scratchpad) loads a stand-in module that follows ADR-0002 rules
1–7: it re-exports `DataAPI.Cols/Between/All` and `InvertedIndices.Not`, and exports `select`,
`rename`, `lag`, `lead`, `c`, `desc` and `across`. The probe also loads DataFrames 1.8.2,
DataAPI 1.16.0, InvertedIndices 1.3.1 and ShiftedArrays 2.0.0, all in a scratch environment.
`julia --startup-file=no --project=env p2.jl`:
```
VERSION 1.13.2
ShiftedArrays exports lag/lead: false false
DataFrames.Not === InvertedIndices.Not: true
DataFrames.Cols === DataAPI.Cols: true; Between: true; All: true
DataFrames.nrow === DataAPI.nrow: true; ncol: true
DataAPI owns select/rename? false false
DataFrames.select owner module: DataFrames; rename: DataFrames
DataAPI functions: … antijoin … crossjoin … describe … groupby … innerjoin … leftjoin … ncol nrow outerjoin … refarray refpool … rownumber semijoin unwrap
Cols -> ok (DataAPI)   Between -> ok (DataAPI)   All -> ok (DataAPI)   Not -> ok (InvertedIndices)
select   -> UndefVarError: `select` not defined in `Main`
rename   -> UndefVarError: `rename` not defined in `Main`
lag, lead, c, desc, across -> ok (the stand-in)
DataFrames select with Not after loading CF: ["b"]
```
The critic reports the same results on 1.10.12, with 1.10's "both … export" warning for
`select`/`rename`. The lane owner's re-run on 1.10 failed: the scratch environment had been
instantiated for 1.13, so it did not resolve on 1.10. Its 1.10 results are the critic's only.

Conclusions:
- Re-exported selectors coexist with DataFrames.
- `select` and `rename` collide with DataFrames' own bindings: DataAPI does not own them.
- DataAPI does own `innerjoin`/`leftjoin`/…, `groupby`, `describe` and `rownumber`. A ChuiFrames
  verb with one of those names would extend DataAPI's function rather than clash.

## LC-10 Tables.jl 1.14.0 has a pushdown protocol (`Tables.Scan`); LZ4 decompression needs `initialize`

Source read: `Tables/qGyu7/src/scan.jl` in the installed Tables 1.14.0, included from
`Tables.jl` line 709.
- `Tables.Scan(; select, filter, limit, offset, validate)` is a plain-data request with no
  `Function` fields.
- Filters are built from `Tables.col`, `colcmp`, `colin`, `isnull`, string predicates, and/or/not
  nodes, and `OpNode` for extensions.
- "A row is kept iff the predicate evaluates to exactly `true` (`missing` excludes, SQL-style)".
- The source answers with a **residual** `Scan`, never a capability advertisement. Axes strip in
  a fixed order (filter → row bounds → projection), and "a reader that cannot consume the filter
  must leave `limit`/`offset` in the residual too".
- `Tables.scan(table, scan)` is the generic executor.

Re-running the I/O critic's probes (scratchpad `critic-io/`) with the core-budget environment
(`cb113`, Julia 1.13.2):
```
p12.jl:  CSV.File scan => (x = [20000.0, 19999.5, 20000.5],)
         Tables.scan generic on NamedTuple => (y = [2],)
         Tables compat note: Scan defined since this version: 1.14.0
p4_codec.jl:  instance transcode w/o initialize: ok true
              second call same instance: ok true
              lz4 instance ERR CodecLz4.LZ4Exception: LZ4F_dctx: Uninitialized decompression context
```
Not checked: whether `Scan` exists in any Tables version before 1.14.0 (the probe only reports
the installed version), and how `Scan`'s comparisons treat NaN. From the source they use Julia's
operators, but that was not run.

## LC-11 Min/max pruning would drop NaN rows from a pyarrow Parquet file

`critic-io/p6_pq2nan.jl` on `critic-io/data/nan.parquet` (written by pyarrow 26.0.0 through
`mknan.py`), with Parquet2 0.2.37 on Julia 1.13.2:
```
rg1 f stats min=1.0 max=2.0 n_null=0 values=[1.0, NaN, 2.0]
   would prune `!(f <= 2.0)` on min/max? true; rows matching: 1
rg2 f stats min=nothing max=nothing n_null=0 values=Union{Missing, Float64}[NaN, NaN]
   would prune `!(f <= 2.0)` on min/max? false; rows matching: 2
```
Julia: `NaN > 2.0 == false`, `!(NaN <= 2.0) == true`. pyarrow leaves NaN out of min/max, so
bounds that are not NaN do not mean the partition holds no NaN.

## LC-12 CodecLz4 load time; whether Zstd_jll is a standard library

`@time using CodecLz4`, three runs in the core-budget environments of LC-09:
```
1.13.2 (cb113):  0.036 s, 0.024 s, 0.025 s   (26.31 k allocations: 2.039 MiB)
1.10.12 (cblts): 0.041 s, 0.033 s, 0.025 s   (19.32 k allocations: 2.371 MiB)
```
`isdir(joinpath(Sys.STDLIB, "Zstd_jll"))`: `true` on 1.13.2 and `false` on 1.10.12. On 1.10,
Zstd_jll is a registered JLL.
