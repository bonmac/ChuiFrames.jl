# Upstream bug: Parquet2.jl loses 1 ms on INT64 timestamps (not filed)

**Status: documented, not filed.** The user decided on 2026-10-20 to record this and not report it
upstream for now. ChuiFrames does not depend on a fix: ADR-0021 reads and writes exact integer
timestamps through Parquet2 internals that fail closed. If Parquet2 adds a public exact mode or fixes
the conversion, revisit ADR-0021's internal path (and its ExplicitImports allow-list entries).

Parquet2.jl is hosted on GitLab: <https://gitlab.com/ExpandingMan/Parquet2.jl>. Filing is an outward
action and needs the user.

## Summary

Parquet2 0.2.37 converts INT64 timestamps through `Float64` seconds on both read and write. About 0.6%
of millisecond-precision `DateTime` values come back 1 ms early after a round trip. Reproduced by the
lead on Julia 1.13.2 and 1.10.12 (1237 of 200,000 values), and end to end through ChuiFrames on a
pyarrow-written file (phase 2b, TS-12 in this directory's timestamp research).

## Draft issue text (ready to paste)

Title: INT64 TIMESTAMP values lose 1 ms through a Float64 round trip on read and write

**Parquet2 0.2.37**, Julia 1.13.2 and 1.10.12.

About 0.6% of millisecond-precision `DateTime` values do not survive a write/read round trip: they
come back 1 ms early.

```julia
using Parquet2, Tables, Dates, Random

Random.seed!(1)
n = 200_000
ms = rand(0:(Dates.value(DateTime(2100) - DateTime(1970))), n)
dts = DateTime(1970) .+ Millisecond.(ms)

path = tempname() * ".parquet"
Parquet2.writefile(path, (t = dts,))
back = collect(Tables.getcolumn(Tables.columns(Parquet2.Dataset(path)), :t))

println("round-trip mismatches: ", count(back .!= dts), " of ", n)
```

Output on both Julia versions:

```
round-trip mismatches: 1237 of 200000
example: wrote 2038-12-29T21:04:52.561 read 2038-12-29T21:04:52.560
```

**Cause.** Both conversions go through `Float64` seconds:

- read, Parquet2's schema.jl line 185: `Dates.DateTime(pdt::ParqDateTime, x) = unix2datetime(x*10.0^pdt.exponent)`
- write, Parquet2's write.jl line 409: `encodevalue(pdt::ParqDateTime, ::ParqInt64, x::DateTime) = floor(Int64, datetime2unix(x) * 10^(-pdt.exponent))`

`x * 1e-3` is not exact in binary floating point, so `unix2datetime` (and `floor` on the write
side) can land 1 ms low. Files written by pyarrow show the same read error, so the reader is affected
on its own, not only for Parquet2-written files. Microsecond and nanosecond units are truncated to
milliseconds, as you'd expect from `DateTime`, but they also go through the same inexact path.

**Suggested fix.** Integer arithmetic, e.g. on read
`DateTime(Dates.UTM(Dates.UNIXEPOCH + fld(x, 10^(-3 - pdt.exponent))))` for exponents ≤ -3 (and
`x * 10^(-3 - exponent)` the other way), and on write `Dates.value(x) - Dates.UNIXEPOCH` scaled by
an integer power of ten.

**Related requests, if you're open to them:**

1. A way to read INT64 timestamps raw (the `Int64` count plus its unit), for callers that need µs/ns
   exactly.
2. Exposing `isAdjustedToUTC` and the unit on the logical type (`ParqDateTime` currently keeps only
   the exponent).
3. Writing µs/ns and UTC-adjusted timestamp columns.
4. Column statistics (min/max) for timestamp columns go through the same decode, so they inherit the
   error.
