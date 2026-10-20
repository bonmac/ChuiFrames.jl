# Research: Arrow timestamps across producers, Julia packages and formats

**Question.** What must ChuiFrames' `ArrowTimestamp` (ADR-0001 rule 6) do so that timestamps in
seconds, microseconds and nanoseconds, with or without a time zone, read, compare and round-trip
through Arrow, Parquet and CSV like the producers' own tools? Input to ADR-0021.

- **Date:** 2026-10-20. Machine zone `Africa/Nairobi` (shows in some R and DuckDB results).
- **Versions:** Julia 1.13.2 and 1.10.12; Arrow.jl 2.8.1, Parquet2 0.2.37, CSV.jl 1.1.0 (with
  Durations 1.4.1), TimeZones 1.22.3; Polars 2.0.0, pyarrow 26.0.0, DuckDB 1.5.6 (Python 3.13.13
  through `uv`); R 4.4.2 with arrow 23.0.1.1 and dplyr 1.2.0.
- **Method:** two research lanes ran the scripts in [timestamps/](timestamps/) in a scratch
  directory and pasted their output; facts from package source cite `file:line` in the installed
  version. Commands: `uv run --no-project --python 3.13 --with pyarrow==26.0.0 --with polars
  --with duckdb python -I <script>.py`; `Rscript <script>.R`; `julia --project=<scratch env>
  <script>.jl`.

## The Arrow specification

- **TS-01** `format/Schema.fbs` at `apache-arrow-26.0.0` (unchanged since 22.0.0): a Timestamp
  with no zone is a wall-clock reading in an unknown zone, "cannot be reliably compared or
  ordered" with zoned values, and "it is *not* possible to interpret an unset or empty timezone
  as the same as UTC". A zoned value's epoch is 1970-01-01 in UTC; zoned values "can be compared
  and ordered directly", and changing one non-empty zone to another is "a metadata-only
  operation". A naive date-time is encoded "as if" its zone were UTC. The zone field is an Olson
  name or an absolute offset `+XX:XX`/`-XX:XX`. The same text is in pyarrow's
  `include/arrow/type.h` (`TimestampType`).

## Producers

- **TS-02 Polars 2.0.0.** `pl.Series([datetime(...)])` and `pl.datetime_range` give
  `Datetime('us', None)`; zone-aware Python datetimes give `Datetime('us', 'UTC')`.
  `str.to_datetime` truncates 9 fraction digits to µs; inputs with `Z`/offsets become UTC.
  `write_ipc` keeps unit and zone name (`timestamp[ms, tz=Europe/Berlin]`). Comparing a zoned
  with a naive column, or two different zones (same instant), is a `SchemaError`; `concat` and
  `join` raise on unit or zone mismatch. **us vs ns compares after truncating to the coarser
  unit**: `us 12:00 == ns 12:00:00.000000001` is `True`. `unique`/`group_by` keep ns values apart.
  `write_csv` writes unit digits and `+HHMM` offsets (`2024-01-01T12:00:00.123456789+0000`), losing
  the zone name; `read_csv(try_parse_dates=True)` gives µs (UTC for offsets). Parquet round-trips
  unit and zone (the zone through the `ARROW:schema` metadata). `"+01:00"` is accepted but
  renamed `Etc/GMT-1`; `"Z"` is rejected as a zone.
- **TS-03 pyarrow 26.0.0.** `pc.equal` compares **by exact instant across units** (`us` vs
  `ns + 1ns` is `False`, `less` is `True`), and two zones of one unit by instant (UTC vs Berlin
  `True`); zoned vs naive is `ArrowInvalid: Cannot compare timestamp with timezone to timestamp
  without timezone`. Casting ns→us fails if data would be lost (`safe=False` truncates).
  `csv.write_csv` writes `2024-01-01 12:00:00.000000Z` for UTC and local time with `+HHMM` for other
  zones; `csv.read_csv` reads s as `timestamp[s]`, finer units as `timestamp[ns]`, offsets as UTC.
  `pq.write_table` defaults to format 2.6: ns stays ns, s is stored as ms; naive columns are
  `isAdjustedToUTC=false`, zoned `true`; zone names come back only through `ARROW:schema`
  (`store_schema=False` gives `tz=UTC`).
- **TS-04 R arrow 23.0.1.1.** Writes POSIXct as `timestamp[us]`: `tzone="UTC"` → `tz=UTC`,
  `tzone=""` → naive, no attribute → the session zone (`Africa/Nairobi`). A naive value holds the
  UTC moment of the local reading (12:00 in Nairobi is stored as naive 09:00), against TS-01.
  Reading `timestamp[ns]` gives a double POSIXct, losing digits below 1 µs (`.123456789` →
  `.123456478`). Base R and dplyr compare different `tzone` attributes by instant, with a warning;
  arrow's Acero engine raises on zoned vs naive, as pyarrow.
- **TS-05 DuckDB 1.5.6.** `TIMESTAMP` → `timestamp[us]`, `TIMESTAMP_NS` → `timestamp[ns]`,
  `TIMESTAMP_MS`/`_S` → ms/s, `TIMESTAMPTZ` → `timestamp[us, tz=<session zone>]`.
  `TIMESTAMP = TIMESTAMP_NS` is exact (common type `TIMESTAMP_NS`; +1 ns is unequal).

## Julia packages

- **TS-06 Arrow.jl 2.8.1 writer.** `Arrow.Timestamp{U,TZ}` (Arrow.jl's `eltypes.jl:262-272`) holds
  `x::Int64`; `U` is an `Arrow.Meta.TimeUnit.T` enum value, `TZ` a `Symbol` or `nothing`;
  `Arrow.DATETIME === Timestamp{MILLISECOND,nothing}`. A column of `Arrow.Timestamp` values, or a
  lazy `AbstractVector` presenting them, is written as Arrow's Timestamp(unit, zone) **with no
  extension tag**, for s/ms/µs/ns, naive and zoned, nullable or not; pyarrow reads
  `timestamp[us, tz=UTC]`, `timestamp[ns, tz=Europe/Berlin]`, etc. (`arrow_ts.jl`,
  `arrow_wrap.jl`). A plain `DateTime` column gets the `JuliaLang.DateTime` tag.
- **TS-07 Parquet2 0.2.37 reader.** An INT64 TIMESTAMP becomes `ParqDateTime(exponent)` (only
  field; `schema.jl:178-183`): the `isAdjustedToUTC` flag is dropped. Every value goes through
  `unix2datetime(x * 10.0^exponent)` (`schema.jl:185`, `read.jl:27`): a Float64 product, then
  truncation toward zero (µs `-1`, `-500`, `-501` all read as `1970-01-01T00:00:00`).
  `ReadOptions` has no raw mode (`options.jl:168-195`); `convertvalue` is unconditional
  (`read.jl:237-251`). The flag and unit are reachable only through internals
  (`getfield(ds, :meta_orig).schema[i].logicalType.TIMESTAMP`) (`pq_read.jl`, `pq_meta.jl`).
- **TS-08 Parquet2 0.2.37 writer.** `DateTime` only, always
  `TimestampType(isAdjustedToUTC = false, unit = MILLIS)` ("we follow Julia's DateTime type and
  only ever use milliseconds", `write.jl:181-186`; `encodevalue` at `write.jl:409`).
- **TS-09 CSV.jl 1.1.0.** ISO timestamps (with `T` or a space, 0–9 fraction digits) infer as
  `Durations.Timestamp{Nanosecond}` with exact values (`Timestamp{Microsecond}` outside the ns
  range; `core.jl:720-734`, promotion `core.jl:2383`); strings with `Z` or `±HH:MM` stay strings.
  `CSV.Chunks` infers the same and rejects `typemap`. `Durations.Timestamp{P}` is a backport of a
  proposed `Dates.Timestamp`; `Dates.value(ts)` is the Int64 count since the Unix epoch; its
  `hash` matches `DateTime`'s when the value is whole milliseconds (`timestamp.jl:268-281`)
  (`csv_ts.jl`, `csv_fmt.jl`).
- **TS-10 Dates (1.13.2 and 1.10.12).** `DateTime` has no own `hash` method: the generic
  `hash(objectid(x), h)` applies (`base/hashing.jl:46` on 1.13, `:34` on 1.10); `==`/`isless` are
  by `value` (`Dates/src/types.jl:472-474`). A user type that hashes as the equal `DateTime` is
  consistent on both versions (`dates_which.jl`). DateTime spans ±146 million years; Int64 ns since
  1970 spans 1677-09-21T00:12:43.145224192 to 2262-04-11T23:47:16.854775807; Int64 µs spans years
  −290308 to 294247.
- **TS-11 TimeZones.jl 1.22.3.** 11 direct dependencies; `using TimeZones` takes 0.10–0.12 s warm
  on 1.13.2. **Arrow.jl 2.8.1 already depends on it**, so `using ChuiFrames` loads it today.

- **TS-12 Parquet2 0.2.37 is lossy at millisecond precision too** (lane probes, 2026-10-20).
  - **Read:** `trunc(Int64, 1000 * (x * 10.0^-3))` (Parquet2's formula, TS-07) differs from `x`
    for 11,581 of 2,000,000 random ms counts in `[-3e12, 1e13]` (about 0.6%). Through
    ChuiFrames on `main`, a pyarrow-written `timestamp[ms]` file with
    `[-2186259751700, -2176368591140, 1085072413093, 1704164645123]` reads as
    `[-2186259751699, -2176368591139, 1085072413092, 1704164645123]`.
  - **Write:** `floor(Int64, datetime2unix(d) * 10^3)` (`write.jl:409`) differs from `d`'s count
    for 18,893 of 2,000,000 random `DateTime`s (about 0.9%).
  - **Exact alternatives, both checked with pyarrow:**
    - reading a column chunk rebuilt with type `ParqInt64` (its `SchemaNode` likewise) returns the
      raw counts (200,000 values, exact);
    - writing a ChuiFrames-owned `struct ExactMs <: Dates.AbstractDateTime` with a method of
      `Parquet2.encodevalue(::ParqDateTime, ::ParqInt64, ::ExactMs)` stores the exact count as
      `Timestamp(isAdjustedToUTC=false, timeUnit=milliseconds)`.
  - `DataAPI.metadata(ds)` exposes pyarrow's `ARROW:schema` (a base64 IPC schema message), which
    holds zone names.

## UNVERIFIED

- Whether a `Dates.Timestamp` lands in Julia's standard library (Durations says 1.14+).
- Polars `write_ipc` with a `"+01:00"` zone (expected `Etc/GMT-1`, not run).
- DuckDB `TIMESTAMPTZ` through Parquet and DuckDB's CSV output.
