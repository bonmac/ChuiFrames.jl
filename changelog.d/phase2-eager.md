### Added

- Phase 2, eager frame (plan: `docs/superpowers/plans/2026-10-20-phase2-eager.md`).
- `Frame`, an immutable frame of ChuiFrames' own Arrow-layout columns (ADR-0001): primitive,
  Bool, string (`StrView` elements), binary, dictionary (1-based codes), list, struct and
  object columns, with element types from the declared schema and zeroed null slots. Any
  Tables.jl input converts with `Frame(table)`, and a frame is a Tables.jl table (CF-001).
- ChuiFrames reads Arrow IPC with its own reader (`read_ipc`, `read_ipc_batches`,
  `read_ipc_schema`, internal): the file format through the footer, the stream format in order,
  LZ4 and Zstd compression. Files written by Polars (default `string_view`), pyarrow and R read
  correctly: Utf8View/BinaryView become the offsets layout, sliced dictionary batches take
  their length from the message, and replacement and delta dictionaries apply per batch.
  Dictionaries are deduplicated, indices to null entries become nulls, and all batches share one
  dictionary. Unsupported Arrow types, big-endian schemas and ordered dictionaries raise an
  `ArgumentError` naming the type; corrupt or truncated input raises `ArgumentError`.
- The eager engine: an internal upstream adapter (ChuiCore stand-ins for aggregators,
  transducers and `⨟`, ADR-0014), ChuiFrames-owned `skipmissing` aggregators, the macro-free
  `c.x` grammar (selectors, `across`/`each`/`if_any`/`if_all`, window and rank helpers, lints,
  round-trip printing), a single-threaded interpreter with grouped-window evaluation and a
  typed group index, and the phase-2 dplyr verbs as Step values that accept any Tables.jl
  source.
- The Source/Sink interface (`ChuiFrames.Source`, `ChuiFrames.Sink`, public, not exported),
  `TablesSource` and the format registry (`scan_file`, `register_format!`; exported `read_file`,
  `write_file`) (ADR-0004; CF-011 to CF-016).
- Arrow IPC writing through one adapter over Arrow.jl: one declared schema, unified 1-based
  dictionaries with no delta dictionaries, Binary as `CodeUnits`, `Date`/`DateTime` as plain
  Date32/Timestamp(ms) with no Julia extension type, the file format by default and the stream
  format for `.arrows`/append, atomic temporary file + rename (ADR-0010). `read_arrow`,
  `write_arrow`.
- CSV over CSV.jl 1.x with readr-style `read_csv`/`read_tsv`/`write_csv`/`write_tsv`;
  divergences from readr 2.1.6 are documented and tested (ADR-0019).
- Parquet with `using ChuiFrames, Parquet2`: one row group per partition, with statistics
  (ADR-0020). Columns of µs/ns timestamps raise an `ArgumentError` naming the unit instead of
  being truncated to milliseconds, until the `ArrowTimestamp` ADR (ADR-0001 rule 6).
- Verb outputs (`mutate`, `summarise`, `reframe`, the window and rank helpers) take their
  element type from the expression's static type, so all-`missing` groups and empty-group
  neutral values keep writable, typed columns.
- A PrecompileTools workload (frame, a core-verb pipeline, printing, Arrow and CSV round trip).
- Frames print tibble-style: `# A Frame: n × m` and `# Groups:` lines, a type row (`<i64>`,
  `<f64?>`, `<str>`, `<list[i64]>`, …; `?` marks nullable columns), numbers to 3 significant
  digits aligned on the decimal point, `missing` for missing values, `…` truncation, fitting to
  the display width and height, and `# ℹ N more rows` / `# ℹ N more variables:` footers.
- `glimpse([io,] f)`: one line per column with its type and leading values.
- In interactive sessions, loading ChuiFrames prints a banner listing exported names that
  conflict with modules used in `Main` (a stand-in for ChuiCore's banner); set
  `CHUI_QUIET_CONFLICTS=1` to hide it.

### Changed

- ADR-0014: ChuiCore's `neutral` is public, not exported; `missing`-aware aggregators are
  ChuiFrames' own (request R8, option A), outside the stand-in release gate.
