# Arrow IPC reader corpus (ADR-0001 rule 10, the phase-2 spike gate)

Each case is `<case>.arrow` (file format) or `<case>.arrows` (stream format), plus
`<case>.json`: pyarrow 26.0.0's reading of the same file (schema, batch lengths, values).
The tests in `test/ipc/` compare ChuiFrames' reader against these dumps. They read the JSON
with a small reader in `test/ipc/ipc_setup.jl`, so the tests need no Python and no JSON
package. NaN/Inf, bytes, dates, timestamps, lists and structs are encoded as small objects,
as `enc` in `make_corpus.py` shows. `unsupported_*` and `ordered_dict` must raise.

Timestamps (ADR-0021): Timestamp(ms) with no zone is dumped as `{"datetime": isoformat}` and
read as `DateTime`. Every other timestamp (s, µs, ns, or any unit with a zone) is dumped raw as
`{"ts": [count, unit, zone]}`: the Int64 count since the epoch, `"s"`/`"ms"`/`"us"`/`"ns"`, and
the zone string or `null`, also inside lists, structs and dictionary values (`to_pylist` cannot
hold ns). The tests read it as `ArrowTimestamp{unit, zone}(count)`. The timestamp cases:

| Case | Producer | What |
|---|---|---|
| `timestamps_pyarrow` (file), `timestamps_pyarrow_stream` | pyarrow 26.0.0 | two batches: s, ms UTC, µs, µs Europe/Berlin, ns (pre-1970, 1 ns apart, the Int64 limits), ns `+05:30`, dictionary of µs, list of ns, struct of µs UTC; nullable and non-nullable fields |
| `polars_timestamps` (file), `polars_timestamps_stream` | Polars 2.0.0 | a `pl.Series` of datetimes (µs naive, the default), ns UTC, ms Europe/Berlin and µs `datetime_range` columns |
| `r_timestamps` (`write_feather`) | R arrow 23.0.1.1 | POSIXct with tzone `"UTC"`, `""` (naive), `"America/New_York"`, fractional µs, an NA |

The `unsupported_tsus`, `unsupported_tsns`, `unsupported_tss` and `unsupported_tsmstz` cases
were removed when ADR-0021 made those types readable.

Producers: pyarrow 26.0.0, Polars 2.0.0 (`polars_*`), R arrow 23.0.1.1 (`r_*`).

To regenerate, run the R script first (it writes the `r_*` files), then the Python one (it
writes everything else and dumps the R files too). Run both from a scratch directory, never
from inside the repo:

```sh
Rscript make_r_corpus.R OUTDIR
uv run --no-project --python 3.13 --with pyarrow==26.0.0 --with polars --with numpy python -I make_corpus.py OUTDIR
```

On 2026-10-20 (Polars 2.0.0, numpy 2.5.4 from uv), both scripts reproduced every committed data
file byte for byte, including the timestamp cases (checked with `cmp` on every file).
