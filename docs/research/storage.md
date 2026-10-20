# Storage research: Arrow.jl vs own buffers

- **Date:** 2026-10-20
- **Lane:** phase1-research (researcher). Input to the storage ADR; this file decides nothing.
- **Questions:** BRIEF "Engine: Arrow memory and semantics: validity bitmaps for nulls, dictionary
  encoding, string views". What Arrow.jl gives on read and write, what an own-buffers column
  needs, what each costs (measured), and what Tables.jl requires.

## Versions and setup

| Item | Value | Source |
|---|---|---|
| Julia | 1.13.2 (benchmarks, all reads); 1.10.12 (`julia +lts`, load times only) | ST-01 |
| Hardware | Apple M3 Pro, 12 cores, 18 GiB; benchmarks single-threaded (`Threads.nthreads() == 1`) | ST-01 |
| Arrow.jl | **2.8.1** (latest registered; GitHub release 2026-01-14); julia compat `[1.9, 2)` | ST-01, DP-01 |
| Resolved with Arrow 2.8.1 | StringViews 1.3.7 (held below 2.0.1 by Arrow), InlineStrings 1.4.6 (held below 2.0.1 by TimeZones, WeakRefStrings), TimeZones 1.22.3, SentinelArrays 1.4.10 | ST-16 |
| Others | PooledArrays 1.4.3, CategoricalArrays 1.1.1, WeakRefStrings 2.0.0, StringViews 2.0.1 (registered), Tables 1.14.0, BenchmarkTools 1.8.0 | ST-01 |
| Cross-check producer | pyarrow 26.0.0 via `uv run --no-project --python 3.13 --with pyarrow==26.0.0` | ST-02 |

Scratch environment and scripts (not in the repo): the session scratchpad `storage/` folder
(`env/`, `bench.jl`, `read_files.jl`, `read2.jl`, `py/make_files*.py`, outputs `*.out`).

## Method

1. pyarrow writes one small IPC file per layout (Utf8View, BinaryView, LargeUtf8, LargeList,
   ListView, run-end encoded, Decimal128/256, dictionary, a 200-element Float64 with a known
   null pattern); Arrow.jl reads each (ST-02..ST-04).
2. Source reading of Arrow.jl 2.8.1 (the installed copy under `~/.julia/packages/Arrow/4zFuR`) and its issue tracker
   via `gh` (ST-13).
3. BenchmarkTools `@benchmark`, 4 s budget per case, 10M rows, ~10% missing (seeded Xoshiro),
   median plus min/q25/q75/max (ST-08..ST-10). A first run was taken while package
   precompilation ran in parallel and had 10-100x spreads; it was discarded and everything
   below is the rerun on a quiet machine.

## Findings

### A1. Arrow.jl 2.8.1 on read

**In-memory types** (ST-02). Every column of a multi-batch file is a
`SentinelArrays.ChainedVector` of per-batch arrays; a single-batch file gives the array directly.

| Arrow layout | Arrow.jl array type | eltype | Result |
|---|---|---|---|
| primitive (Float64, ...) | `Arrow.Primitive{Union{Missing,T},Vector{T}}` | `Union{Missing,Float64}` | correct |
| Utf8 / LargeUtf8 | `Arrow.List{String,Int32 or Int64,Vector{UInt8}}` | `Union{Missing,String}` | correct |
| **Utf8View** (one column) | `Arrow.View{Union{Missing,String}}` | `Union{Missing,String}` | correct, incl. inline (≤12 B) and out-of-line strings, UTF-8 |
| **Utf8View** (two columns) | read fails | | **`UndefRefError`** (ST-03; upstream issue #590, fix PR #612 open) |
| BinaryView | `Arrow.View` | `Union{Missing,Base.CodeUnits}` | correct |
| LargeList | `Arrow.List` of `SubArray` views | `Union{Missing,SubArray{...}}` | correct |
| ListView | read fails | | `MethodError: getindex(::Nothing, ::Int64)` |
| Run-end encoded | read fails | | `MethodError: no method matching juliaeltype(::Field, ::RunEndEncoded, ::Bool)`; issue #476 open |
| Decimal128 / Decimal256 | `Arrow.Primitive` | `Arrow.Decimal{10,2,Int128}` / `{40,2,Int256}` | correct (raw scaled integers) |
| Dictionary | `Arrow.DictEncoded{String,Int16 or Int32,...}` | `Union{Missing,String}` | correct when buffers are exact; **wrong length** for sliced batches (ST-04) |

**Utf8View answer.** Read: yes for a single view column (`Arrow.View`, elements decoded through
StringViews). With two or more view columns the reader mis-indexes the variadic buffer counts
(Int32 instead of Int64; diagnosis in PR #612, not yet merged) and fails (reproduced, ST-03).
Write: **no**. The writer maps `String` to `Meta.Utf8` only; `utf8ViewStart`/`binaryViewStart`
are never called outside the generated schema file, and `Arrow.write`'s docstring has no view
option (ST-12).

**Dictionary bug found here** (ST-04). pyarrow writes a 4-row batch sliced from a 6-row
dictionary array with the un-truncated 6-entry indices buffer (legal: the node length governs).
Arrow.jl sizes `DictEncoded` from the buffer (`reinterp` uses `buf.length`) and returns 6 rows;
pyarrow reads 4. Primitive columns are not affected. No matching issue found by `gh search`
(UNVERIFIED whether already reported). Separate open issue #610: `Arrow.Table` applies the last
replacement dictionary to all batches.

**Zero copy / mmap** (ST-05). `Arrow.Table(path)` mmaps the file (`tobytes(io::IOStream) =
Mmap.mmap(io)`); uncompressed primitive columns are `unsafe_wrap`ped views into the mmapped blob
(pointer check true). Opening a 10M-row file costs median 0.031 ms. Columns are read-only:
`setindex!` raises `ReadOnlyMemoryError`. Compressed (LZ4/Zstd) buffers are decompressed into new
memory (source: `reinterp` -> `uncompress`), so they are not zero-copy.

**Nulls** (ST-05, ST-06). Validity is an `Arrow.ValidityBitmap(bytes, pos, ℓ, nc)` over the
Arrow LSB-numbered bitmap; eltype is `Union{Missing,T}` whenever the field is nullable.
`getindex` returns `missing` via the bitmap; the data buffer keeps whatever the producer put in
null slots.

**Construct and write from own buffers** (ST-12). `Arrow.write` takes any Tables.jl source; a
custom `AbstractVector{Union{Missing,Float64}}` round-trips. `Arrow.DictEncode(v)` writes a
dictionary column (pyarrow reads it as `dictionary<values=string, indices=int8>`), and a
`PooledArray` is written as a dictionary column automatically. Writing iterates the values;
there is no public API to hand Arrow.jl existing values/bitmap buffers without a copy
(UNVERIFIED beyond the docstring and `write.jl`).

**Thread safety** (ST-11, ST-13). `Arrow.Table` decodes record batches in concurrent tasks
(`@wkspawn`), guarding shared dictionary state with `Lockable`/`ReentrantLock`. Decompressors are
per-`threadid()` slots each wrapped in a `Lockable`. Measured with `-t 4`: 32 concurrent
`Arrow.Table` opens of one Zstd file and 32 concurrent reductions over one shared table all gave
the reference sum; 16 concurrent string scans agreed. A check, not a proof.

**Load time** (DP-03, DP-04; ST-14 is the first-read run, whose own `using` lines show
0.254 / 0.131 / 0.157 s in the shared `env`). `using Arrow`: 0.150 / 0.171 / 0.149 s (1.13, own
env), 0.241 / 0.309 / 0.266 s (1.10). *Corrected 2026-10-20 by the lane owner after review.* The first `Arrow.Table` call adds ~0.96-1.02 s (99.9% compilation),
the first `sum(skipmissing)` 0.07 s. Closure: 13 direct, 28 transitive registered packages,
including TimeZones, CodecLz4, CodecZstd, BitIntegers (DP-02).

**Maintenance** (ST-13). 2.8.0 was 2024-12-08 and 2.8.1 2026-01-14. `main` has unreleased fixes
(StringViews 2.0 support, 2026-06-11). Draft PR #609 "Rewrite Arrow.jl internals for 3.0"
(+61,992/−46,804 lines, 225 files, updated 2026-10-04) replaces the internals and the table
facade, so the 2.x types listed above may not survive 3.0.

### A2. What an own-buffers column needs

Minimum shape: `struct Col{T} <: AbstractVector{Union{Missing,T}}` holding a values `Vector{T}`
(or `Memory{T}` on 1.11+, behind a `VERSION` gate per the minimum-Julia ADR) and a validity bitmap,
with `getindex` returning `missing` when the bit is 0. Strings need offsets + data (or views);
categoricals need codes + a dictionary.

**BitVector is byte-compatible with Arrow's bitmap on little-endian** (ST-06). For 200 elements
with a known null pattern, `reinterpret(UInt8, bv.chunks)[1:25]` equals pyarrow's validity buffer
byte for byte (`f6f3bd7e…f53e`), and `ENDIAN_BOM == 0x04030201`. Both use LSB-first bit
numbering inside little-endian words, so `BitVector.chunks` can be written as an Arrow validity
buffer without repacking. Mapping an Arrow bitmap into a `BitVector` without a copy is not
possible through public API: `chunks` is a `Vector{UInt64}` owned by the BitVector, and Arrow
bitmaps may start at a bit offset or be 8- not 64-bit aligned (UNVERIFIED that no public
constructor exists).

**Base `Vector{Union{Missing,Float64}}`** (ST-07). Stored inline: 8 B data per element plus one
type-tag byte per element. `Base.summarysize` = 90,000,040 B for 10M (= 9N + 40);
`sizeof` = 80,000,000 (tags excluded). Values + `BitVector` = 81,250,120 B (8N + N/8), which
equals the Arrow file size (77.486 MiB). Values + `Vector{Bool}` = 9N, the same as the Union
array.

**Sum of non-missing, 10M Float64, 10.0% missing, ms** (ST-08):

| Layout / kernel | median | min | q25 | q75 | max |
|---|---|---|---|---|---|
| Union vector, `sum(skipmissing)` | 12.556 | 12.044 | 12.477 | 12.805 | 17.611 |
| Union vector, `@simd` loop with `ismissing` | **1.414** | 1.303 | 1.361 | 1.493 | 4.554 |
| values + BitVector, generic `getindex` | 7.658 | 7.467 | 7.553 | 7.878 | 12.370 |
| values + BitVector, branchless `ifelse(valid[i], v[i], 0)` | 2.456 | 2.432 | 2.445 | 2.477 | 3.740 |
| values + BitVector, naive 64-bit word walk | 7.724 | 7.639 | 7.679 | 7.824 | 9.371 |
| values only, nulls zeroed (invariant we could impose) | **1.132** | 1.010 | 1.078 | 1.227 | 4.527 |
| Arrow.jl column, `sum(skipmissing)` | 15.617 | 15.357 | 15.516 | 15.859 | 27.081 |
| Arrow.jl column, loop with `ismissing` | 9.929 | 9.694 | 9.750 | 10.076 | 14.435 |
| Arrow.jl `data` + `validity`, branchless | 6.854 | 6.742 | 6.801 | 6.950 | 8.604 |

Reading: Julia's Union layout vectorises well (1.4 ms). A packed bitmap costs ~1.7x in a scalar
kernel (2.5 ms) unless null slots are zeroed, which removes the bitmap from sums (1.1 ms).
Arrow.jl's `ValidityBitmap` `getindex` is ~2.8x slower than `BitVector` in the same branchless
kernel (6.9 vs 2.5 ms), and its generic path is 7-11x slower than the Union loop.

**Filter (`x > 0.5`, missing dropped) and gather (1M random indices), ms** (ST-09):

| Operation | Union vector | values + BitVector | Arrow.jl column |
|---|---|---|---|
| predicate mask | 1.405 (q25-q75 1.329-1.684) | 5.646 (5.541-5.853) | 16.840 (16.623-17.182) |
| apply mask (~45% kept) | 29.147 (29.019-29.469) | **13.269** (13.178-13.419) | 30.800 (30.195-31.409), copies to a Union vector |
| gather 1M | 5.342 (5.105-5.612) | 5.797 (5.578-6.066) | 8.860 (8.620-9.210) |

### A3. Dictionary encoding and strings

| Option | What it is | Fit |
|---|---|---|
| `Arrow.DictEncoded` | indices + shared `DictEncoding`; read-only, from IPC | read path only; sliced-batch length bug (ST-04), replacement-dictionary bug #610 |
| PooledArrays 1.4.3 | `refs::Vector{UInt8/16/32}` + `pool` + `invpool`; mutable; written by Arrow.jl as a dictionary | 1 registered dep (DataAPI) |
| CategoricalArrays 1.1.1 | refs + `CategoricalPool` with levels and ordering | 4 registered deps incl. Requires; heavier semantics (forcats-like levels) |
| `Vector{String}` | one pointer per row + heap strings | simple; hashing per row |
| Arrow offsets + data | `Arrow.List{String}`; `getindex` allocates a new `String` (10M allocations, ST-10) | read path |
| InlineStrings (`String31` etc.) | fixed-size bits; 32 B/row for `String31` | hashing no faster than `String` here; 4x the memory |
| WeakRefStrings 2.0.0 | `WeakRefString`, `StringVector` (and re-exports InlineStrings) | legacy CSV.jl storage |
| StringViews.jl | **registered**, latest 2.0.1 (2026-06-11), 0 deps; `StringView(bytes)` is an `AbstractString` over any byte vector, hashes equal to `String` | the natural element type for an own offsets/views string column; Arrow.jl 2.8.1 caps it at 1.x |

**Group-key hashing, 10M rows, 1,000 distinct keys (4-20 chars), ms** (ST-10):

| Key column | Kernel | median | q25-q75 | allocs / mem |
|---|---|---|---|---|
| `Vector{String}` | `Dict` lookup per row -> group id | 114.170 | 112.683-115.643 | 25 / 38.2 MiB |
| `Vector{String31}` | same | 108.179 | 107.363-109.693 | 26 / 38.3 MiB |
| Arrow.jl Utf8 column | same (each `getindex` allocates a `String`) | 284.928 | 280.788-298.315 | 10,000,025 / 386.7 MiB |
| `PooledArray` refs (UInt16) | counts per code | **2.896** | 2.826-3.016 | 3 / 8 KiB |
| `Arrow.DictEncoded` indices (Int16) | counts per code | **2.914** | 2.827-3.035 | 3 / 8 KiB |
| one-off encode `PooledArray(Vector{String})` | | 128.967 | 127.300-131.198 | 48 / 28.7 MiB |

Memory: `Vector{String}` 76.3 MiB (shared strings counted once), `PooledArray` 19.1 MiB,
`Vector{String31}` 305.2 MiB. A dictionary-encoded key is ~40x cheaper to group by than hashing
strings, and encoding once costs about one string-hash pass.

### A4. Tables.jl interop

Required (Context7 `/juliadata/tables.jl`, ST-15): `Tables.istable`; either
`Tables.columnaccess` + `Tables.columns` returning an `AbstractColumns`
(`Tables.getcolumn(x, ::Symbol)`, `Tables.getcolumn(x, ::Int)`, `Tables.columnnames`), or
`Tables.rowaccess` + `Tables.rows` returning `AbstractRow`s. Optional:
`Tables.schema` (a `Tables.Schema` or `nothing`), `Tables.materializer` (round-trip sink),
`Tables.partitions` (iterator of same-schema tables; default is the table itself as one
partition) and `Tables.partitioner` (mark an iterable, or lazily materialize, as partitions).

Arrow.jl (ST-11): `Arrow.Table <: Tables.AbstractColumns` with a schema
(`:x Union{Missing,Float64}, :s Union{Missing,String}`). `Tables.partitions(::Arrow.Table)`
returns `Arrow.TablePartitions`, one partition per record batch (20 for a 20-batch file,
100,000 rows each); it has no `length` method (`collect` fails; iterate instead).
`Arrow.Stream` is also a partition iterator (20 batches). `Arrow.write` consumes
`Tables.partitions(source)` and writes one record batch per partition.

## Own buffers vs Arrow.jl: trade-offs (for the ADR; not a decision)

| Concern | Own buffers (values + BitVector/bitmap, codes + dictionary, offsets/views + StringViews) | Arrow.jl 2.8.1 as the in-memory engine |
|---|---|---|
| Null representation | Arrow-compatible bitmap (`BitVector.chunks` bytes equal Arrow's, ST-06) | the real Arrow bitmap |
| Scalar kernels | branchless sum 2.5 ms; 1.1 ms with zeroed nulls (ST-08) | 6.9 ms best, 9.9-15.6 ms generic (ST-08) |
| Filter apply / gather | 13.3 ms / 5.8 ms (ST-09) | 30.8 ms (materializes) / 8.9 ms |
| Memory | 8N + N/8 (equals the Arrow file) | the same plus zero-copy mmap; 0.031 ms to open 10M rows |
| Mutability | ours to define | read-only (`ReadOnlyMemoryError`); `copy` to mutate |
| String views | design our own (StringViews 2.x) | read one view column only; two fail (#590); never writes views |
| Dictionaries | PooledArrays-like codes, 2.9 ms group counts | same speed; length bug on sliced batches (ST-04) and #610 |
| REE, ListView | ours to add | unsupported on read |
| IPC read | still need a reader: either Arrow.jl as an I/O dependency (copy or wrap its buffers) or our own | built in |
| Dependencies / load | 0 to 2 small packages (StringViews 0 deps; PooledArrays 1) | 28 transitive incl. TimeZones; `using` 0.15 s + ~1 s first read; pins StringViews 1.x and (via TimeZones) InlineStrings 1.x |
| Upstream risk | none | 3.0 rewrite in a draft PR may change every type above |
| Julia 1.10 | `Vector` works on 1.10; `Memory` needs 1.11 (VERSION gate) | compat `[1.9, 2)`; loads on 1.10.12 (0.24-0.31 s) |

A middle option the numbers allow: own buffers in memory, and Arrow.jl (or our own reader) only
at the IPC boundary, copying out of the mmap into our types. That costs one copy per read and
gives up zero-copy mmap, which A1 measures as nearly free to open.

## UNVERIFIED

- Whether the dictionary sliced-batch length bug (ST-04) is already reported upstream (no hit
  for three `gh search issues` queries).
- That no public API lets Arrow.jl write existing values/bitmap buffers without a copy (only the
  docstring and `write.jl` were read).
- That no public `BitVector` constructor wraps an existing UInt64 buffer (not searched beyond Base
  knowledge).
- Thread safety in general: ST-11 is one 4-thread run, not a proof.
- Benchmarks were not run on Julia 1.10 or with more than one thread.
- Whether PR #612 fixes the two-view-column failure seen here (same symptom family; not tested).

## Also noticed

- Arrow.jl 2.8.1's own env resolves StringViews 1.3.7; a package that also wants StringViews 2
  cannot co-install the released Arrow.jl.
- `Tables.partitions(::Arrow.Table)` lacks `length`; sinks that `collect` partitions fail.

## Evidence

**ST-01** versions and hardware. `julia --startup-file=no --project=env bench.jl data`:
`Julia 1.13.2 | threads 1 | CPU Apple M3 Pro | Arrow 2.8.1 | PooledArrays 1.4.3 | InlineStrings 1.4.6 | BenchmarkTools 1.8.0`;
`sysctl -n hw.ncpu hw.memsize` -> `12`, `19327352832`.

**ST-02** layouts. `uv run --no-project --python 3.13 --with pyarrow==26.0.0 python -I py/make_files.py data`
(`pyarrow 26.0.0`) then `julia --project=env read_files.jl data <hex>`:
```
utf8view => SentinelArrays.ChainedVector eltype Union{Missing, String}
     ["a", missing, "short12chars", "this string is longer than twelve bytes", "", missing, "ünïcödé long string over 12", "x"]
binaryview => SentinelArrays.ChainedVector eltype Union{Missing, Base.CodeUnits}
listview => READ ERROR: TaskFailedException ... MethodError: no method matching getindex(::Nothing, ::Int64)
ree => READ ERROR: ... no method matching juliaeltype(::Arrow.Flatbuf.Field, ::Arrow.Flatbuf.RunEndEncoded, ::Bool)
decimal256 => Arrow.Primitive eltype Union{Missing, Arrow.Decimal{40, 2, BitIntegers.Int256}}
utf8view multi-batch column type: SentinelArrays.ChainedVector{Union{Missing, String}, Arrow.View{Union{Missing, String}}}
```

**ST-03** two view columns. `py/make_files2.py` (1,000 rows, two `string_view` columns, long
strings) then `julia -t 4 --project=env read2.jl data`: `two_views READ ERROR: UndefRefError: access to undefined reference`.
`gh api repos/apache/arrow-julia/pulls/612`: "`variadicBufferCounts` is an Int64 vector ... the
reader uses Int32 entries" (open, 2026-09-22); issue #590 open (2026-03-20).

**ST-04** dictionary length. pyarrow writes `t6.slice(0,4)` of a 6-row dictionary column:
```
pyarrow dict_sliced rows 4 ['a', 'b', None, 'a']
dict_sliced length 6 Union{Missing, String}["a", "b", missing, "a", "c", "b"]   # Arrow.jl
prim_sliced length 4 Union{Missing, Float64}[1.0, missing, 3.0, 4.0]            # Arrow.jl, primitive OK
```
Arrow.jl source, file table.jl, lines 816-838: `reinterp` sizes the array as `div(buf.length, sizeof(T))`.

**ST-05** mmap and nulls. `read_files.jl`:
```
primitive col type: Arrow.Primitive{Union{Missing, Float64}, Vector{Float64}} data Vector{Float64}
Arrow.Table(file) column memory inside mmapped blob: (Vector{UInt8}, true)
validity bitmap object: Arrow.ValidityBitmap fields (:bytes, :pos, :ℓ, :nc)
Arrow.Primitive setindex! allowed? ReadOnlyMemoryError()
```
`bench.jl`: `Arrow.Table(file) open 10M Float64 col median 0.031 ms | min 0.017 | q25 0.030 | q75 0.032 | max 0.077`.

**ST-06** bitmap layout. pyarrow `arr.buffers()[0]` for 200 elements, null where `i%7==3 or i%11==0`:
`BITMAP_HEX f6f3bd7ebdcf6ff7fbdd7ebed7aff7f9ed7ebfdbcff7faf53e`. Julia:
```
BitVector chunks as UInt8 hex: f6f3bd7ebdcf6ff7fbdd7ebed7aff7f9ed7ebfdbcff7faf53e
ENDIAN little: true
matches pyarrow BITMAP_HEX: true
Arrow.jl validity matches: true
```
Spec (Context7 `/apache/arrow`, Columnar.rst): validity bits are little-endian, LSB numbering;
buffers recommended 8- or 64-byte aligned and padded.

**ST-07** memory. `bench.jl`:
```
Vector{Union{Missing,Float64}}: 85.831 MiB (90000040 B; 8N+N = 90000000)
values Vector{Float64} + BitVector: 77.486 MiB (81250120 B)
Arrow file size: 77.486 MiB
Union isbits-union layout: Base.allocatedinline(Union{Missing,Float64}) = true; sizeof(A) = 80000000 (= 8N, tags excluded); summarysize-8N = 10000040
```

**ST-08** sums. `bench.jl` (quiet rerun, `missing fraction: 0.10006959999999998`), e.g.
`A loop ismissing median 1.414 ms | min 1.303 | q25 1.361 | q75 1.493 | max 4.554 | n=2729`;
`C Arrow data+validity branchless median 6.854 ms | min 6.742 | q25 6.801 | q75 6.950 | max 8.604 | n=580`.
All kernels checked against `sum(skipmissing(A))` (rtol 1e-9); no mismatch printed.

**ST-09** filter and gather. `bench.jl`, e.g. `B values[mask], valid[mask] median 13.269 ms | min 8.427 | q25 13.178 | q75 13.419 | max 32.529`;
`C Arrow C[idx] median 8.860 ms | min 8.363 | q25 8.620 | q75 9.210 | max 38.456`. Masks asserted equal across layouts.

**ST-10** group keys. `bench.jl`:
```
types: P PooledVector{String, UInt16, Vector{UInt16}} | AS Arrow.List{String, Int32, Vector{UInt8}} | AD Arrow.DictEncoded{String, Int16, ...}
Vector{String} Dict group ids     median 114.170 ms | min 111.740 | q25 112.683 | q75 115.643 | max 121.471
Arrow string col Dict group ids   median 284.928 ms | ... | allocs 10000025 | mem 386.730 MiB
PooledArray refs -> per-group counts median 2.896 ms | min 2.717 | q25 2.826 | q75 3.016 | max 7.114
```

**ST-11** partitions and concurrency. `julia -t 4 --project=env read2.jl data` (pyarrow Zstd file, 2M rows, 20 batches):
```
partitions(Arrow.Table) count: 20 (Arrow.TablePartitions, first partition rows 100000) | Arrow.Stream batches: 20
32 concurrent Arrow.Table opens (zstd): all equal ref: true
32 concurrent reductions over one shared table: all equal: true
16 concurrent string scans: [2000]
custom AbstractVector write roundtrip: Union{Missing, Float64}[1.0, missing, 3.0]
```
`collect(Tables.partitions(t))` -> `MethodError: no method matching length(::Arrow.TablePartitions)`.

**ST-12** writing. `read_files.jl`: `julia_written roundtrip: Arrow.DictEncoded [...]`,
`PooledArray write -> Arrow.DictEncoded`, `Arrow.write kwargs mention view: false`; pyarrow reads
the Julia file as `x: double; k: dictionary<values=string, indices=int8, ordered=0>`.
`grep -rn "utf8ViewStart\|binaryViewStart\|listViewStart\|runEndEncodedStart" src --exclude=Schema.jl` -> no hits;
`eltypes.jl:449-450` writes strings as `Meta.Utf8`.

**ST-13** Arrow.jl source and project state. Arrow.jl table.jl line 733: `const ViewTypes = Union{Meta.Utf8View,Meta.BinaryView,Meta.ListView,Meta.LargeListView}`;
`grep RunEnd` hits only `metadata/Schema.jl`; Arrow.jl's module file (Arrow.jl) lines 111-127: per-`threadid` decompressors in `Lockable`s; `table.jl` decodes batches in `@wkspawn` tasks.
`gh api repos/apache/arrow-julia/releases`: `v2.8.1 2026-01-14`, `v2.8.0 2024-12-08`. Commits: `2026-06-11 support StringViews 2.0 (#599)`.
PR #609: draft, `additions 61992, deletions 46804, changed_files 225, updated 2026-10-04`. Issues #476 (REE) and #610 (dictionary replacement) open.

**ST-14** Arrow time to first read, 3 fresh processes, `--project=env`:
```
using Arrow: 0.253994 / 0.131273 / 0.157211 s
first Arrow.Table: 1.018011 / 0.955492 / 0.966525 s (99.9% compilation time)
first sum(skipmissing): 0.317386 / 0.074870 / 0.073502 s
```

**ST-15** Tables.jl interface: Context7 `/juliadata/tables.jl` ("Implementing the Interface >
Required Methods"; `Tables.partitions`, `Tables.partitioner`, `Tables.schema`, `Tables.materializer`).

**ST-16** compat drag. `Pkg.add(name="Arrow", version="2.8.1")` -> `StringViews v2.0.1 ⇒ v1.3.7`;
`Pkg.status(outdated=true, mode=PKGMODE_MANIFEST)`:
`InlineStrings v1.4.6 (<v2.0.1): TimeZones, WeakRefStrings`; `StringViews v1.3.7 (<v2.0.1): Arrow`.
