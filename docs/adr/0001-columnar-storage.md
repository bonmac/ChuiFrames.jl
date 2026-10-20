# ADR-0001: Columns are ChuiFrames' own Arrow-layout buffers; ChuiFrames reads Arrow IPC itself and writes it through Arrow.jl

- **Status:** Accepted (2026-10-20, user at the ChuiFrames phase-1 ★)
- **Date:** 2026-10-20
- **Deciders:** the user, at the phase-1 ★ checkpoint
- **Scope:** ChuiFrames.jl

## Context

The brief asks for Apache Arrow memory and semantics (validity bitmaps for nulls, dictionary
encoding, string views) and for phase 1 to choose between Arrow.jl and own buffers. Storage must
also serve the engine (branch-free kernels, typed keys, dictionary codes; ADR-0003) and Tables.jl
interchange (CF-001). The Julia floor is 1.10 (ecosystem ADR-0006), so `Memory` needs a gate.

Facts ([storage.md](../research/storage.md); Arrow.jl 2.8.1, Julia 1.13.2, M3 Pro, 1 thread;
[lane-checks.md](../research/lane-checks.md)):

**What Arrow.jl 2.8.1 gets wrong or cannot do on read:**
- It reads a Polars 2.0.0 IPC **file** as a table with no columns, and raises no error. This
  happens both with Polars' default `string_view` layout and with `large_string`. The stream
  format reads correctly (LC-04). Polars writes `string_view` by default (LC-04).
- Two Utf8View columns in one file fail with `UndefRefError` (upstream #590). ListView and
  run-end encoding fail too (ST-02, ST-03).
- A dictionary column in a sliced batch reads with the wrong length, 6 rows instead of 4 (ST-04).
- Issue #610: it applies the last replacement dictionary to every batch.
- Its writer never emits views (ST-12).
- A draft 3.0 rewrite replaces its internals (ST-13).

**What Arrow.jl does well:** it memory-maps files and wraps uncompressed primitive buffers without
copying; opening 10M rows takes 0.031 ms (ST-05).

**Speed and memory** (10M Float64, 10% missing; medians):

| Operation | Arrow.jl column | values + `BitVector` | Base `Vector{Union{Missing,Float64}}` |
|---|---|---|---|
| Sum | 9.9–15.6 ms generic, 6.9 ms branchless | 2.5 ms branchless; 1.1 ms if null slots hold zero | 1.4 ms |
| Predicate mask | 16.8 ms | 5.6 ms | 1.4 ms |
| Apply mask | 30.8 ms | 13.3 ms | 29.1 ms |
| Gather | 8.9 ms | 5.8 ms | 5.3 ms |

The Base union vector stores 9 bytes per element; values plus bitmap store 8.125 (ST-07 to ST-09).

**Strings and dictionaries:**
- `BitVector.chunks` is byte-identical to an Arrow validity bitmap on little-endian machines
  (ST-06).
- Grouping by 1,000 distinct strings over 10M rows: 114 ms on `Vector{String}`, 285 ms on
  Arrow.jl strings (10M allocations), and 2.9 ms on dictionary codes (ST-10).
- `StringView(view(data, a:b))` has a concrete type, and it compares and hashes equal to `String`
  (LC-05).

**Arrow.jl's writer rules (from its source, cited by the critic):**
- it writes a dictionary only when `DataAPI.refarray(x) !== x`;
- it assumes codes start at 1;
- it always writes `isOrdered = false`;
- it takes the schema from the first partition.

## Decision

**Column types (must).**
1. ChuiFrames defines its own column types over Arrow-layout buffers. A column's element type
   comes from its **declared schema**, never from the data. A nullable column has eltype
   `Union{Missing,T}` even when it holds no `missing`; a non-nullable one has eltype `T`. `T` is
   concrete for every column kind except object columns (rule 12).
2. **Primitive** columns hold a values `Vector{T}` and, when nullable, a validity `BitVector`.
   - **Zero-null-slot invariant.** Every constructor and ingest path (IPC, Parquet, CSV, any
     Tables.jl input, verbs) **must** write `zero(T)` into null slots, or a fixed bit pattern for
     types with no `zero`. Kernels may rely on this.
   - **Bool** columns hold a value bitmap plus validity, with null value bits cleared.
3. **Strings** are stored as offsets plus a data `Vector{UInt8}` plus validity. The element type
   is **`StrView = StringView{SubArray{UInt8,1,Vector{UInt8},Tuple{UnitRange{Int64}},true}}`**
   (LC-05). Offsets are `Int32`.
   - Offset builders **must** check for overflow and widen to `Int64` (LargeUtf8) instead of
     wrapping.
   - The **Utf8View** layout is a second in-memory string representation, with the **same**
     element type, adopted only if a phase-4 benchmark shows a gain. Until then the reader
     **converts** Utf8View input (Polars' default, LC-04) to the offsets layout (rule 10).
   - An element keeps its column's data buffer alive. The docs must say that `String(x)`
     detaches it.
4. **Binary** columns use the same buffers, but elements are byte views
   (`SubArray{UInt8,…}`), never `StringView`s. They round-trip as Binary or LargeBinary.
5. **Dictionary** columns hold unsigned codes (`UInt8`/`UInt16`/`UInt32`), a dictionary column
   and validity.
   - Codes are compared, hashed or joined only between columns that share an identical
     dictionary; otherwise the dictionaries are unified first (ADR-0003 rule 8).
   - The reader **must** deduplicate dictionary entries, and fold indices that point at a null
     dictionary entry into validity.
   - `DataAPI.refarray` exposes codes starting at 1, as Arrow.jl's writer expects.
   - v0 has unordered dictionaries only. Ordered levels (forcats) wait for phase 6, which must
     also settle how CF-008's `isless` order meets level order. That is a contract question,
     raised to the lead.
6. **Other Arrow types.**

   | Arrow type | Column element type |
   |---|---|
   | Int8–64, UInt8–64, Float32/64, Bool | itself |
   | Utf8, LargeUtf8, Utf8View | `StrView` |
   | Binary, LargeBinary, BinaryView | byte view |
   | Date32 | `Dates.Date` |
   | Timestamp(ms), no time zone | `Dates.DateTime` |
   | List, LargeList | nested column (offsets + child) |
   | Struct | named child columns + validity |
   | Dictionary | as rule 5 |

   **Timestamps** in µs or ns, or with a time zone, keep their raw `Int64` values plus the unit
   and zone. Their element type is `ArrowTimestamp{U,TZ}`, a ChuiFrames type that converts to
   `DateTime` with documented truncation and compares by its raw value. So `distinct` on ns
   values keeps them apart. Its exact API is settled by a phase-2 ADR, before any reader produces
   these values. That ADR must define equality and hashing across units and zones (a ms and an ns
   timestamp of the same instant), and comparison with `DateTime`.

   *Amended by [ADR-0021](0021-arrow-timestamp.md) (Proposed; takes effect when accepted):*
   timestamps compare and hash by their exact instant, not their raw value (equal instants in
   different units are equal; `distinct` still keeps distinct ns instants apart). `DateTime(t)`
   floors. Timestamp(ms) with a zone and Timestamp(s) also read as `ArrowTimestamp`.

   **Every Arrow type not in the table above** (Decimal, Date64, Float16, Duration, Time,
   Interval, FixedSizeBinary, FixedSizeList, Map, Union, Null, ListView, LargeListView, run-end
   encoding, extension types) **must** raise an `ArgumentError` that names the type, until a
   later ADR adds it.
7. **Immutability.** Columns are immutable once built, and verbs may share buffers with their
   inputs.
8. **Buffers are `Vector`s** on every supported Julia (`Memory` would need its own ADR).
9. **Parallel writes.** Parallel tasks **must not** write into one shared `BitVector` (64 rows
   share a word). Each task builds its own buffers, and they are concatenated in morsel order.

**Arrow IPC (must).**
10. **Reading is ChuiFrames' own.** An internal reader parses IPC metadata (schema, record
    batch and dictionary-batch messages, footer) and decodes buffers into the column types above.
    It **must** meet all of these:
    - **File format** is read through the **footer's block offsets**, never by walking the
      file as a stream: the Polars file in LC-04 has no stream-style prefix after its magic
      bytes (storage critic's hex dump).
    - **Stream format** is read sequentially.
    - **Batch lengths** come from the record-batch message (ST-04).
    - **Dictionaries:** per-batch, replacement (#610) and **delta** dictionaries are all handled.
    - **Utf8View / BinaryView** are converted to the offsets layout on read, with variadic data
      buffers handled (rule 3).
    - **Compression:** LZ4-frame and Zstd buffers are decompressed (ADR-0016 to ADR-0018).
    - **Raise** an `ArgumentError` for a big-endian schema, and for an ordered dictionary
      (`isOrdered = true`) until phase 6 adds ordered levels.
    - **Parser:** the FlatBuffers parser is ChuiFrames' own, a small table reader for the Arrow
      schema files. It **must not** use Arrow.jl's internal `Arrow.Flatbuf`/`FlatBuffers`
      modules, which are not public.
    - **Rough size, not a bound:** Arrow.jl's `table.jl`, FlatBuffers and metadata code is about
      2,900 lines (some of it write-side). Its buffer decoding (`arraytypes/`, read and write
      mixed) is about another 2,200 (critic's `wc -l`).
    - **Spike gate (phase 2's first task).** The reader must pass the LC-04 Polars files (file and
      stream, with strings longer than 12 bytes so variadic buffers appear), the ST-03 two-view
      file, the ST-04 sliced dictionary, a #610 replacement-dictionary stream, a delta-dictionary
      stream and compressed files, all written by pyarrow and Polars. If the spike fails or
      overruns its plan, the lead takes the fallback to the user: Arrow.jl's reader for the
      stream format only, and the file format raising. The ★ question must say two things:
      this fallback still has #610, ST-04 and ST-03's silent or failing cases on streams; and
      with the file format as the default write format (rule 11), ChuiFrames could not read its
      own default output. Under the fallback, writes therefore default to the stream format.
    - **Expected values in tests** come from pyarrow dumps of the same files. Arrow.jl's reader
      is used as a cross-check only on cases where it is known to be correct.
11. **Writing goes through Arrow.jl**, behind one adapter. The adapter **must**:
    - hand columns over as Tables.jl columns with **one declared schema for every partition**
      (Arrow.jl fixes the schema from the first partition);
    - choose Utf8 or LargeUtf8 **up front** from the declared schema. Spill files always use
      large offsets (`largelists = true`). This is because Arrow.jl widens offsets per partition
      once data passes 2³¹−1 bytes, under a schema fixed earlier (critic N4, from `list.jl` and
      `write.jl`; UNVERIFIED by a run);
    - present dictionary columns with 1-based `refarray`, and give every partition the **full
      unified dictionary** as `refpool`, so that the index type fixed by the first partition
      fits;
    - present binary elements as `Base.CodeUnits`, which is what Arrow.jl writes as Binary.
      A `SubArray{UInt8}` would be written as `list<uint8>`;
    - write the **file format by default** (Polars, pyarrow's feather reader and R reject
      stream files). Use the stream format for spills, append and `.arrows` paths (ADR-0004
      rule 7);
    - where the unified dictionary is not known before the first partition is written, decode
      the column, or buffer until the dictionary is known (ADR-0004 rule 7).

    Writing views or ordered dictionaries waits for a later ADR. Round-trip tests check every
    rule here by reading the output with pyarrow.
12. **Julia element types on input.** Any Tables.jl input is accepted (CF-001).
    - **Mapped types:** `Bool`; `Int8`–`Int64`; `UInt8`–`UInt64`; `Float32`/`Float64`; any
      `AbstractString` → the string column (rule 3); `Base.CodeUnits`/byte vectors → binary;
      `Date` → Date32; `DateTime` → Timestamp(ms); `ArrowTimestamp` → its timestamp;
      `AbstractVector` elements → a list column; `NamedTuple` elements → a struct column. Each
      becomes the matching column kind of rules 2–6.
    - **Small numeric unions** (`Union{Int,Float64}`) are promoted with `promote_type` only when
      the conversion is lossless for the values present (`Float64(2^53+1) != 2^53+1`;
      `convert(UInt64, Int8(-1))` throws). Otherwise the column becomes an object column.
    - **Any other element type** (`Any`, `Symbol`, `Char`, `Rational`, `BigInt`, user structs,
      fitted models) becomes an **object column**: a `Vector{T}` plus validity, carried through
      verbs and evaluated by the interpreter.
    - Object columns are never compiled into kernels. They may be grouping or join keys when
      `hash`/`isequal` are defined for their values, through the interpreter path. They raise an
      `ArgumentError` naming the type when written to Arrow, CSV or Parquet.
    - This covers tidyr/purrr list-columns.

## Alternatives rejected

| Alternative | Why rejected |
|---|---|
| Arrow.jl arrays as the in-memory engine | Kernels 1.3–6.4x slower and filters 2.3x slower (ST-08, ST-09). Utf8View reads fail, there is no view writer, the dictionary bugs remain, and its types may change in 3.0. |
| Arrow.jl's reader, behind guards | It cannot guard what it does not report: a Polars file read as an empty table with no error (LC-04), #610's wrong dictionaries, and the sliced-batch length (ST-04). Guards would need the metadata parse that rule 10 does anyway. |
| Our own writer as well, in v0 | Arrow.jl writes the layouts rule 11 needs correctly (pyarrow reads them, ST-12). A writer can move in-house later behind the same adapter. |
| Base `Vector{Union{Missing,T}}` | Fast sums, but not Arrow layout (one type-tag byte per element) and no dictionary or view story. |
| PooledArrays or CategoricalArrays as the dictionary type | PooledArrays is mutable and keeps an `invpool`. CategoricalArrays carries level semantics and 4 dependencies (storage.md A3). Own codes take about 100 lines. |
| InlineStrings / WeakRefStrings | No faster to hash than `String`, and `String31` uses 4x the memory (ST-10). |
| An abstract string element type (`<:AbstractString`) | Boxes every element in `Tables.schema` consumers and in Arrow.jl's writer, and loses type inference (critic run on 1.10.12). |

## Consequences

- **Phase 2 builds** the column types, the IPC reader (a FlatBuffers metadata parser plus buffer
  decoding) and the writer adapter. This is larger than wrapping Arrow.jl. It is the price of
  reading Polars output correctly.
- **New dependencies.** IPC compression needs Zstd and LZ4 codecs (ADR-0016 to ADR-0018). The
  budget is in ADR-0005.
- If Polars' default `Datetime` unit is µs (UNVERIFIED), most Polars timestamps depend on the
  `ArrowTimestamp` type of rule 6, so that phase-2 ADR comes early.
- **Phase-2 tests:**
  - every column constructor and verb keeps the zero-null-slot invariant (property test);
  - files written by pyarrow, Polars (file and stream, default settings) and R's arrow package
    read correctly, including a sliced dictionary batch, replacement dictionaries and two
    Utf8View columns;
  - offset widening past 2 GiB, tested on a synthetic offsets buffer.
- The cost of converting Tables.jl inputs on entry (rule 1) is not measured yet; phase 2
  measures it.

## Verification

- ST-01 to ST-16 in [storage.md](../research/storage.md).
- LC-04 and LC-05 in [lane-checks.md](../research/lane-checks.md).
- The Arrow.jl writer facts are from its source (`write.jl`, `dictencoding.jl`, `arraytypes.jl`),
  as quoted by the storage critic.

UNVERIFIED:
- why Arrow.jl reads Polars files as empty (LC-04);
- whether the Arrow spec allows duplicate dictionary entries;
- the storage benchmarks on Julia 1.10 and with more than one thread;
- the size of an own IPC reader (an estimate, not measured).

## Revisit when

- Arrow.jl 3.0 is released: re-test its reader on the phase-2 corpus, and consider dropping the
  own reader.
- A phase-3 measurement shows copying on read dominates scan time (consider zero-copy wrapping;
  it must zero null slots or carry a flag that kernels check).
- The Julia floor rises to ≥ 1.11.
