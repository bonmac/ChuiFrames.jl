# ADR-0004: Sources take `Tables.Scan` pushdown and answer with a residual, plus statistics and handles; sinks are transactional; v0 is bounded-only

- **Status:** Accepted (2026-10-20, user at the ChuiFrames phase-1 ★)
- **Date:** 2026-10-20
- **Deciders:** the user, at the phase-1 ★ checkpoint
- **Scope:** ChuiFrames.jl (the interface is published in the coordinator's `chui-frames.md`)

## Context

The brief asks for a pluggable source/sink interface that carries:
- partitions, column selection, pushed-down filters and statistics;
- one file and no core changes for a new source;
- CSV, Arrow IPC and Parquet built in, and the other connectors as package extensions.

Ecosystem ADR-0009 §7 and ecosystem ADR-0010 rule 6 require names distinct from Tables.jl's, **or
consistent extensions of Tables.jl**. They also require a choice between a bounded-only v0 and a
streaming variant. The ChuiTypes stream adapter lives in ChuiFrames (ecosystem ADR-0002 §1).
In this ADR, "ADR-NNNN" without "ecosystem" means a ChuiFrames ADR.

Facts:

**Tables.jl 1.14.0 has a pushdown protocol, `Tables.Scan`** (LC-10,
[lane-checks.md](../research/lane-checks.md)):
- the request is a plain-data value: `select`, `filter`, `limit` and `offset`;
- filters are built from `Tables.col`, `colcmp`, `colin`, `isnull`, string predicates,
  and/or/not, and `OpNode` for extensions;
- a row is kept if the predicate is exactly `true`, so `missing` excludes it;
- the source answers with a **residual** `Scan`, in a fixed axis order: filter, then row
  bounds, then projection. A source that does not consume the filter must leave `limit`/`offset`
  in the residual;
- `Tables.scan(table, scan)` is the generic executor, and CSV 1.1.0 accepts `scan=`.

SS-01's claim that Tables.jl has no projection or filter hook predates this check, and is wrong
for 1.14.

**Prior art** (Trino, DataFusion, Polars, DuckDB, Arrow Dataset, Spark DSv2;
[source-sink.md](../research/source-sink.md) B2). They share planning separate from reading,
pushdown with an exactness or residual answer, statistics, ordering and boundedness. Polars
re-applies nothing that a source ignored (SS-07).

**Failure cases the I/O critic ran** (scratch probes, quoted in its report and in LC-10/LC-11):
- **Limit plus engine-side filter.** A pushed limit applied below a filter the engine still
  evaluates returns the wrong rows (`expected [4, 5]: got [6, 7]`).
- **NaN and min/max.** pyarrow leaves NaN out of Parquet min/max, so pruning `!(f <= 2.0)` drops
  a NaN row (LC-11).
- **Unclosed writes.** A stream-format Arrow write that is never closed reads back as complete
  but truncated. An unclosed file-format write reads as an empty table.
- **No schema check in Arrow.jl's writer.** It accepted a widened batch (`missing` became 0) and
  reinterpreted Float64 bits as Int64.
- **Stream format interop.** `polars.read_ipc`, `pyarrow.feather.read_table` and R's
  `read_feather` all reject stream-format files.
- **A shared, unlocked IO races.** A naive source seeking in one shared IO fails under `-t 4`
  (`EOFError`).
- **`CSV.Chunks` has no handle access.** It cannot be indexed (`getindex` `MethodError`).

## Decision

1. **Pushdown vocabulary is `Tables.Scan`** (a consistent extension of Tables.jl).
   - The engine translates the pushable part of a plan into one `Tables.Scan`: projection,
     conjuncts and limit/offset.
   - A conjunct is pushable only if `Tables.Scan` can express it **and** its `Scan` semantics
     equal ChuiFrames' for every value, including NaN and `missing`. Phase 2 verifies the
     mapping with a differential test per node kind, and until then a node kind is not pushable.
     - `Scan`'s comparisons already follow IEEE as ChuiFrames does: `f != 1.0` and
       `!(f <= 2.0)` keep NaN (I/O critic, `r2_scan.jl`).
     - `colin` does **not**: `colin(col(:f), (NaN,))` matches nothing, while
       `in.(c.f, Ref(Set([NaN])))` keeps the NaN row. So `in.` with a float NaN member is never
       pushed, and the differential test covers NaN set members.
   - Any other conjunct (arbitrary Julia calls, `|>`, the abstract-typed barrier filters of
     ADR-0003 rule 4) stays with the engine.
   - ADR-0006's compat becomes `Tables = "1.14"`.
2. **Source functions.** (R) marks a required method. The rest have defaults, so one file with
   four methods is a working source.

   ```julia
   abstract type Source end
   source_schema(s)::Tables.Schema                                   # (R) names and element types
   source_label(s)::String                                           # (R) shown by explain()
   plan_partitions(s, scan::Tables.Scan; morsel)::Tuple{Vector,Tables.Scan}   # (R) handles + residual
   read_partition(s, p)                                              # (R) → a Tables.jl table for handle p
   partition_stats(s, p, col) = nothing    # (; lo, hi, nnull, nnan, ndistinct): all fields present, each may be nothing
   row_count(s) = nothing                  # (n, exact::Bool) or nothing
   partition_row_count(s, p) = nothing     # (n, exact::Bool) or nothing
   source_ordering(s) = nothing            # an Ordering declaration (rule 6) or nothing
   source_groups(s) = Symbol[]             # pre-grouped columns
   isthreadsafe(s) = false                 # fail-closed: reads are serialized behind a lock unless a source opts in
   source_boundedness(s) = :bounded        # reserved (rule 8)
   ```
   - **Handles carry the pushdown.** Each handle `p` from `plan_partitions` holds everything
     `read_partition` needs: the pushed projection, filter and per-partition limit. So
     `read_partition` takes no filter argument.
   - **The residual is the source's answer.** It follows `Tables.Scan`'s axis rules exactly. The
     engine applies the residual to every partition, plus everything it never pushed.
   - A source that cannot apply a conjunct exactly leaves it in the residual. It may still use
     it to prune.
   - The columns a handle returns **must** include every column the residual and the engine's
     remaining conjuncts reference.
3. **Limits and offsets.**
   - A limit is pushed only when the plan has **no** stage between the scan and the limit, and
     every conjunct has been pushed (none kept by the engine).
   - A pushed limit means "the first *n* qualifying rows of **each partition**, in partition
     order".
   - The engine always keeps the **global** limit, taken in partition order (ADR-0003 rule 6).
   - **Offsets are never pushed** to a source with more than one partition. The per-partition
     `Scan` carries `offset = 0`. The engine applies the global offset, then the global limit,
     in partition order. With an offset *k*, a pushed per-partition limit becomes *k + n*.
     (Per-partition offsets returned `[]` instead of `[7, 8]`, I/O critic `r2_scan.jl`.)
4. **Statistics.**
   - `lo`/`hi` are bounds, not exact values.
   - Pruning keeps a partition whenever its statistics are `nothing`, a bound is NaN or
     `missing`, or the comparison throws (prototype regression 7).
   - **Min/max pruning needs both safety conditions:**
     - a predicate that can be true on NaN (negations, `.!=`, `isnan.`; ADR-0002 rule 12) needs
       `nnan == 0` known;
     - a predicate that can be true on `missing` (`ismissing.`, `.|` with one) needs
       `nnull == 0` known.

     A partition is pruned only when every condition that applies holds. A predicate the engine
     cannot classify **never prunes**. pyarrow leaves NaN out
     of min/max (LC-11). A partition with a `missing` was wrongly prunable under the earlier
     NaN-only rule (I/O critic `r2_prune.jl`).
   - Exact row counts let `n_rows` and join planning skip a scan.
   - Distinct counts may pick the group-by strategy up front (ADR-0003 rule 9).
   - Partitions with dictionary encoding may carry different dictionaries, and the engine
     unifies them (ADR-0003 rule 8).
5. **Any Tables.jl input is a Source.**
   - `TablesSource` wraps any `Tables.istable` input. Each element of `Tables.partitions` is one
     partition, iterated with `iterate`, not `collect` (SS-02).
   - Its residual is the whole `Scan`. The engine evaluates it with its own operators; it may
     use `Tables.scan` as an implementation of that.
   - The partition list is **always snapshotted when the source is constructed**, because Julia
     has no trait that identifies a single-pass iterator. So `explain` followed by `collect`
     plans the same partitions. This keeps CF-001 for lazy queries.
6. **Ordering.**
   - `source_ordering` declares the sort keys, directions, NaN/`missing` placement and how
     `±0.0` is treated. It also has a flag `global::Bool`: `true` when partitions are sorted
     across partition order too, with non-overlapping key ranges.
   - The engine may skip an `arrange` only when the declaration matches ADR-0002 rule 13
     exactly **and** `global` is `true`.
   - If the order holds only within partitions, the engine k-way merges the partitions instead
     of sorting. Ties are broken by partition index, then row position, so the result equals a
     stable `arrange`. (Skipping the sort gave `[1, 3, 2, 4]`, I/O critic `r2_prune.jl`.)
   - If the declaration does not match ADR-0002 rule 13, the engine sorts.
7. **Sinks are transactional.**
   ```julia
   abstract type Sink end
   open_sink(k::Sink, schema::Tables.Schema)   # → state
   write_partition!(state, part)               # one Tables.jl table, in partition order
   close_sink!(state)                          # flush, footer/metadata, commit
   abort_sink!(state, err)                     # discard; the engine calls it on any exception
   ```
   - **Schema.** `write_partition!` **must** convert each partition to the declared schema, or
     raise an `ArgumentError`. It never passes a mismatched batch to a writer, because Arrow.jl
     corrupts silently.
   - **Atomic commit.** Built-in file sinks write to a temporary path in the same directory and
     rename in `close_sink!`. `abort_sink!` deletes the temporary file.
   - **Append** (Arrow stream) is documented as not atomic.
   - **Built-in sinks.**
     - **Arrow IPC** (ADR-0010) writes the **file format by default**, because Polars, pyarrow's
       feather reader and R's `read_feather` reject stream files. The stream format is used for
       spills, explicit append and `.arrows` paths.
     - **CSV** writes one file, written sequentially.
     - **Parquet** (Parquet2 extension, ADR-0020) writes one row group per partition, with
       statistics.
   - **Dictionaries.** A sink in partition order that cannot know the final dictionary up front
     (ADR-0001 rule 11) **decodes** dictionary columns to plain values, or buffers until the
     unified dictionary is known. Delta dictionaries are used only once Arrow.jl's support for
     writing them is verified.
8. **Bounded-only v0.** `plan_partitions` returns a finite `Vector`. `source_boundedness` is
   reserved now (default `:bounded`). The streaming variant adds a **new** method,
   `stream_partitions(s, scan)`, returning a possibly infinite iterator; `plan_partitions` is
   never changed.
   - In that variant, row-wise verbs (`filter`, `select`, `rename`, row-wise `mutate`, `head`)
     accept `:unbounded` sources. Blocking verbs reject them at plan time unless windowed.
   - The ChuiTypes stream adapter ships first as a bounded source.
9. **Placement and "one file".**
   - **Third-party sources.** A new source is a subtype of `Source` in the author's own package,
     with four methods. It needs no core change.
   - **Formats.** File formats are read through `scan_file(path; format = :auto)` and written
     through `write_file(x, path; format = :auto)`. Both dispatch through **one format
     registry** that extensions fill from `__init__` with a source and a sink
     (`register_format!(:parquet; source = ParquetSource, sink = ParquetSink)`). So a format
     extension adds no core line.
   - A second registration of an already-registered format raises an `ArgumentError`. A caller
     picks among alternatives with an explicit `format =` value naming a distinct key (e.g.
     `:parquet_duckdb`).
   - The core keeps **one** generic message for an unknown format: "no reader/writer registered
     for `<ext>`; load the package that provides it". There is no per-format hint table.
   - **Built in:** the Arrow IPC source (ChuiFrames' own reader, ADR-0001) and sink, and the CSV
     source and sink.
   - **Extensions:** Parquet (Parquet2, ADR-0020; ★ deviation from the brief); the phase-6
     connectors (DBInterface, XLSX, ReadStat, JSON, HTTP, S3) as named candidates, each with its
     own dependency ADR when its lane starts.
10. **Threading.** A source with `isthreadsafe(s) == false` (the default) is read behind one
    lock. Per-partition reads may run as asynchronous tasks through the effects adapter
    (ADR-0003 rule 15).

## Alternatives rejected

| Alternative | Why rejected |
|---|---|
| An own conjunct IR with per-conjunct `filter_support` (an earlier draft) | It duplicates `Tables.Scan`, which ecosystem ADR-0010 rule 6 prefers to extend. It left the conjunct type undefined, so third-party sources could only say "unsupported". It also mis-specified limits (critic probe: `[6, 7]` instead of `[4, 5]`). |
| A Source *is* a Tables.jl table (only `Tables.partitions` + `scan=`) | Tables.jl has no partition handles, statistics, row counts, ordering or boundedness. Those are this ADR's additions over `Scan`. |
| Trusting pushed filters with no residual (Polars IO plugins) | Wrong results from a lax source (SS-07). |
| Pruning on min/max for any predicate | Loses NaN rows from pyarrow files (LC-11). |
| Sinks with no abort, writing in place | A crash leaves a truncated stream that reads as complete (critic probe). |
| Stream format as the default Arrow output | Rejected by Polars `read_ipc`, pyarrow's feather reader and R's `read_feather` (critic probe). |
| `isthreadsafe` defaulting to `true` | Fail-open: a naive source races (`EOFError` under `-t 4`). |
| One core stub per extension format | Every connector would need a core edit, which breaks "one file, no core changes". The registry avoids that. |
| Streaming in v0 | ChuiTypes' stream API is PROVISIONAL. |

## Consequences

- **Coordinator contract.** `chui-frames.md`'s PROVISIONAL Source/Sink sketch is replaced by
  rules 1–9 (the lead makes the change). Rule 9's `scan_file`, `write_file` and
  `register_format!` are public API too. The interface gets contract IDs after acceptance.
- **ADR-0006** moves to `Tables = "1.14"`.
- **ADR-0001 rule 11** and **ADR-0010 rule 2** change their Arrow default to the file format.
- **SS-01** gets a correction note.
- **Tests.** Each built-in format gets source and sink tests: files from pyarrow, Polars and R's
  arrow package, NaN statistics, an aborted write, and a schema mismatch on write. Each pushable
  `Scan` node kind gets a differential test against ChuiFrames' own evaluation.
- **CSV source.** It reads `CSV.Chunks` **sequentially**, as one ordered stream of partitions,
  because chunks cannot be accessed by handle. `CSV.Chunks` rejects `scan=`, so the whole
  `Scan` is the CSV source's residual (ADR-0019).
- **DBInterface extension.** Its test environment must resolve DuckDB.jl with
  FixedPointDecimals 0.4.0–0.4.2 next to CSV 1.x (SS-12 as corrected; PQ-11, PQ-13).

## Verification

- LC-10 and LC-11 in [lane-checks.md](../research/lane-checks.md).
- SS-01 to SS-12 (SS-01 as corrected) and B2 in [source-sink.md](../research/source-sink.md).
- PQ-11 and PQ-13 in [parquet-csv.md](../research/parquet-csv.md).
- The I/O critic's probes (scratch `critic-io/`, Julia 1.13.2): `p1_arrow_schema.jl`,
  `p2_stream_partial.jl`, `p7_standin.jl`, `p8_threadsafe.jl`, `p9_chunks_api.jl` and the
  interop checks with Polars, pyarrow and R. These are quoted in the phase report and not
  re-run by the lane owner, except those in LC-10 and LC-11.

UNVERIFIED:
- whether `Tables.Scan` exists in any Tables version before 1.14.0;
- `Scan`'s NaN behaviour beyond comparisons and `colin` (the I/O critic ran those two);
- whether Arrow.jl writes delta dictionaries;
- every source probe on Julia 1.10.

## Revisit when

- ChuiTypes releases its stream API (add `stream_partitions`).
- `Tables.Scan` gains statistics, ordering or partition handles (drop the overlapping additions).
- Polars and R readers accept Arrow stream files.
