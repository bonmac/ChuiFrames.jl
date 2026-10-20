# ADR-0021: Timestamps that `DateTime` cannot hold are `ArrowTimestamp{U,TZ}` values compared by exact instant; zones are display metadata

- **Status:** Accepted (2026-10-20, user at the ChuiFrames phase-2b ★): exact Parquet timestamps
  through Parquet2 internals (fail closed; switch when a public exact mode exists); TimeZones.jl
  deferred; `DateTime(t)` floors sub-millisecond digits.
- **Date:** 2026-10-20
- **Deciders:** the user, at the next ChuiFrames ★ checkpoint (the lead carries it)
- **Scope:** ChuiFrames.jl. **Amends** ADR-0001 rule 6: values compare by instant, not by raw
  value, and `DateTime(t)` floors rather than truncates.

## Context

ADR-0001 rule 6 reads Arrow Timestamp(ms) with no zone as `DateTime`. It raises on every other
Timestamp until "a phase-2 ADR" settles `ArrowTimestamp{U,TZ}`: its API, equality and hashing
across units and zones, and comparison with `DateTime`. This is that ADR. It is urgent: Polars,
R arrow and DuckDB all default to µs (TS-02, TS-04, TS-05).

Facts ([timestamps.md](../research/timestamps.md)):
- **Spec** (TS-01): a naive Timestamp is a wall-clock reading and must not be read as UTC. A
  zoned one is a UTC instant, and changing its zone is "metadata-only". Naive and zoned values
  "cannot be reliably compared".
- **Equality across units:** pyarrow and DuckDB compare by exact instant (TS-03, TS-05). Polars
  truncates to the coarser unit, so `us 12:00 == ns 12:00:00.000000001` (TS-02).
- **Zones:** pyarrow compares two zones by instant and raises on zoned vs naive. Polars raises on
  both, and also on `concat` across units or zones (TS-02, TS-03).
- **Arrow.jl** writes `Arrow.Timestamp{U,TZ}` as plain Arrow Timestamps, with no extension tag
  (TS-06).
- **Parquet2 0.2.37** decodes every INT64 timestamp through a Float64 product plus truncation
  (TS-07). The result: **about 0.6% of millisecond values read 1 ms early** (11,581 of 2·10⁶
  random values, TS-12), and µs/ns digits are cut off.
  - Its writer uses `floor(datetime2unix(x) * 1000)`, which **writes about 0.9% of `DateTime`s
    1 ms off** (TS-12). It writes only naive ms.
  - ChuiFrames' Parquet path on `main` has both errors.
  - Reading the raw Int64 values through Parquet2's column internals is exact, and so is writing
    through an owned `AbstractDateTime` type with its own `encodevalue` (TS-12).
- **CSV.jl 1.1.0** infers ISO timestamps exactly as `Durations.Timestamp{Nanosecond}` (TS-09).
- **Dates:** `DateTime` hashes through the generic fallback (TS-10).
- **TimeZones.jl** is already loaded through Arrow.jl (TS-11).

## Decision

**The type**
1. **Values.** `ArrowTimestamp{U,TZ}` is an isbits `Int64` count of `U` since 1970-01-01.
   - `U` **must** be `Dates.Second`, `Millisecond`, `Microsecond` or `Nanosecond`.
   - `TZ` is `nothing` (naive) or a non-empty `Symbol`, kept verbatim and not validated (rule 8).
     Each zone string is its own type, so `+01:00` and `Etc/GMT-1` are distinct types that
     compare by instant. The IPC reader maps an empty zone to `nothing` (TS-01).
   - The type is exported. `ArrowTimestamp{U}(x)` builds a naive value, and in `col_types` it
     means the naive type. As a Julia type, `ArrowTimestamp{U}` is abstract, so ingest narrows an
     abstract timestamp element type to the values' concrete types. `ArrowTimestamp{U}[…]` then
     gives a primitive column, or rule 7's error, and never an object column.
   - Timestamp(s/ms/µs/ns, any zone) reads as this type, **except** Timestamp(ms) with no zone,
     which stays `DateTime`.
   - Columns are `PrimitiveColumn`s whose null slots hold raw `0`.
2. **Accessors.** `Dates.value(t)` gives the raw count. `ChuiFrames.timestamp_unit` and
   `timestamp_zone` are public, not exported.

**Equality, hashing, order**
3. **Equality is by exact instant** (Int128 nanoseconds), across units and against `DateTime`.
   This follows pyarrow and DuckDB, not Polars.
   - Two zoned values compare by UTC instant, whatever their zones (TS-01).
   - A naive value equals the `DateTime` with the same reading.
   - **Naive vs zoned** (including zoned vs `DateTime`): `==`, `<` and `isless` **must** throw an
     `ArgumentError` (pyarrow and Polars raise). `isequal` **must** return `false`, never throw,
     so `Dict`s, `Set`s, `distinct` and `group_by` stay total.
   - Base's own `DateTime == Date` quirk means `==` is not transitive through `Date`. `x in v`
     uses `==` on a vector, so it can throw, while `x in Set(v)` uses `isequal`.
   - Array literals mixing naive and zoned values fail to promote (a `MethodError` on 1.13).
4. **Hashing agrees with `isequal`.**
   - A naive value whose instant is whole milliseconds, inside `DateTime`'s range, hashes as that
     `DateTime`.
   - Every other value hashes its instant, with different salts for naive and zoned values.
   - So grouping keeps values 1 ns apart distinct (ADR-0001 rule 6), and a `Dict` keyed by
     `DateTime` finds an equal µs value. The phase-4 join engine **must** promote key columns by
     rule 7 before hashing, because ADR-0003 rule 8 types its keys.
5. **Order** is by instant, within the naive values (including `DateTime`) and within the zoned
   values. A typed column is all one or the other, so `arrange` never meets the mix there.
   - Only an `Any` object column can hold both. For such a column, group ordering falls back to
     first-seen order, as it does for any value without `isless` (`groups.jl`). `arrange` on it
     raises rule 5's error.

**Conversion, promotion, arithmetic**
6. **Conversion.**
   - `DateTime(t)` **floors** sub-millisecond digits. Floor is monotone; truncation toward zero
     moves values before 1970 forward. Zoned values give UTC.
   - `Date(t)` and the calendar fields (`year` … `millisecond`) go through that floor.
     `microsecond`/`nanosecond` give the sub-millisecond digits.
   - `ArrowTimestamp{U,TZ}(dt)`, unit changes and `convert` are **exact**, or they throw an
     `InexactError`. ns spans only 1677–2262 (TS-10). A zoned target reads `dt` as UTC.
   - `convert` exists only to a fully specified `ArrowTimestamp{U,TZ}`.
   - A zone change is not a conversion: rebuild the value from `Dates.value(t)`.
7. **Promotion and concatenation.**
   - Naive values of different units, naive with `DateTime`, and zoned values with the same zone
     promote to the finer unit, exactly.
   - `vcat_columns`/`bind_rows` **must raise** on naive with zoned, on different zones, and when
     a value overflows the finer unit (as Polars does). They never build an object column whose
     `isless` would throw later in `group_by`.
   - `t ± p` for a fixed period (`Week` down to `Nanosecond`) keeps `t`'s type and must be exact:
     `+ Microsecond(1)` on a ms value throws, where pyarrow would widen.
   - `t1 - t2` (also against `DateTime`) is a period of the finer unit.
   - A calendar period (`Month`, `Quarter`, `Year`) is an `ArgumentError` that points to
     `DateTime(t)`.

**Text and zones**
8. **No zone database.** Zoned values print in UTC with a `Z`, never in local time. Headers show
   the unit and the zone, for example `<dttm[us, Europe/Berlin]>`. Local times wait for the ★
   TimeZones.jl question (ADR-0013).
9. **The text form** is `yyyy-mm-ddTHH:MM:SS`, plus exactly the unit's fraction digits, plus `Z`
   when zoned.
   - It is computed from the day count, never through `DateTime`, so every value prints. Years
     outside 0000–9999 use ISO 8601's expanded form, a sign and at least 5 digits.
   - `print`/`string` produce this form, and CSV writes it.

**Formats**
10. **Arrow IPC** reads any unit and zone into rule 1's types. It writes them back as
    `Arrow.Timestamp{unit,TZ}` (TS-06). The raw values, unit and zone round-trip exactly.
11. **Parquet** **must not** produce or write a shifted value.
    - **Reading:** INT64 timestamps are read as raw counts, by rebuilding the column chunk with
      its physical type (Parquet2 internals, TS-12). If that fails, the read raises; it never
      falls back to Parquet2's decoding.
      - `isAdjustedToUTC = false` gives naive values: `DateTime` for ms, otherwise
        `ArrowTimestamp{U}`.
      - `isAdjustedToUTC = true` gives a zone taken from pyarrow's `ARROW:schema` metadata,
        parsed by the IPC reader, or `:UTC` when that metadata is absent. Parquet itself stores
        only the flag.
      - An unreadable flag, or legacy INT96 data, raises.
      - Timestamp columns report no statistics, because Parquet2 decodes their bounds the lossy
        way. That gives up row-group pruning on timestamps, until the raw statistics bytes are
        decoded the exact way.
      - The `isAdjustedToUTC` flag is read from the root's direct children only. Parquet2 0.2.37
        cannot open files with nested timestamp columns at all (critic probe).
    - **Writing:** `DateTime` and naive s/ms `ArrowTimestamp` columns go through an owned
      `ExactMs <: AbstractDateTime`, whose `encodevalue` writes the exact count. µs/ns and zoned
      columns raise, naming Arrow as the lossless route, because Parquet2 writes only naive ms
      (TS-08).
12. **CSV.**
    - **Writing** uses rule 9's text.
    - **Reading:** the first batch decides an inferred timestamp column's type, as for every
      CSV column (TS-09). A first batch that holds only whole milliseconds gives `DateTime`;
      **any** finer digit gives `ArrowTimestamp{Nanosecond}`, or `{Microsecond}` when a value lies
      outside 1677–2262. So only "whole ms first, finer later" can raise, and its error points to
      `col_types`.
    - `col_types = (t = ArrowTimestamp{U,TZ},)` parses the ISO text itself.
      - It accepts rule 9's expanded years, so ChuiFrames reads its own output back. Fields and
        offsets out of range raise.
      - Zoned types accept `Z`, `±HH:MM` and `±HHMM`, shifted to UTC.
      - Naive types reject a zone suffix.
      - Digits the unit cannot hold raise.
    - Zone names are lost in CSV in every library (TS-02, TS-03).

## Alternatives rejected

| Alternative | Why rejected |
|---|---|
| Polars' truncating cross-unit equality | Not transitive across three units; merges ns-distinct keys (TS-02); pyarrow and DuckDB are exact. |
| Raise when comparing different zones | The spec makes zones metadata on a UTC instant (TS-01); pyarrow and R compare by instant. |
| `==` returning `false` for naive vs zoned | Silently empties `filter(c.t .== dt)` on every zoned column, while `.>` throws (critic). `isequal` stays total instead. |
| An object column for mixed kinds (an earlier draft) | `group_by` then crashes in `isless`, and the failure surfaces only at write time (critic). |
| Truncation toward zero in `DateTime(t)` | Not monotone before 1970 (TS-07). |
| `Durations.Timestamp` / a future `Dates.Timestamp` | No zone; Durations' Arrow extension writes a tag other readers ignore (TS-09); one more dependency. Revisit when Dates ships one. |
| Parquet2's own timestamp decoding and encoding | Shifts about 1 in 170 values read and 1 in 110 written by 1 ms; truncates µs/ns (TS-07, TS-12). |
| Raising on every Parquet timestamp | Safe, but drops the most common Parquet column type; the raw path is exact and fails closed. ★ question. |
| TimeZones.jl now | A direct dependency goes through ADR-0005; ADR-0013 defers zones to phase 6. ★ question. |

## Consequences

- Polars, pyarrow, R arrow and DuckDB files read exactly, and Arrow write-back is exact. Parquet
  becomes exact for every unit on read, and for naive ms on write. This **fixes a silent 1-ms
  error on `main`**, in both Parquet directions (TS-12).
- The Parquet extension relies on Parquet2's internal `Column`/`SchemaNode` fields. A test pins
  it, the read fails closed, and a draft upstream request asks Parquet2 for a raw mode.
- Code: `src/timestamps.jl` (new); `columns.jl`; `ipc/meta.jl` and `ipc/decode.jl`;
  `io/arrow.jl`; `io/csv.jl`; `ext/`; `show/`.
- Tests: corpus cases from Polars, pyarrow and R arrow; round trips through Arrow, CSV and Parquet;
  property tests (`isequal` ⇒ equal `hash`; strict order; floor monotone; exact conversions).
- One new export: `ArrowTimestamp`.

## Verification

TS-01 to TS-12 in [timestamps.md](../research/timestamps.md), with the scripts in
[timestamps/](../research/timestamps/). The critic's probes (`isequal` ⇒ `hash`, transitivity,
monotone floor; 100k random values on 1.10.12 and 1.13.2). UNVERIFIED: whether and when Dates
gains a `Timestamp` type.

## Revisit when

- Parquet2 exposes raw timestamps or `isAdjustedToUTC`: drop the internals.
- Dates ships `Timestamp{P}`: consider it as the naive element type.
- Phase 6 decides TimeZones.jl: local-time display, `ZonedDateTime`, zone validation.
