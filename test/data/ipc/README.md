# Arrow IPC reader corpus (ADR-0001 rule 10, the phase-2 spike gate)

Each case is `<case>.arrow` (file format) or `<case>.arrows` (stream format), plus
`<case>.json`: pyarrow 26.0.0's reading of the same file (schema, batch lengths, values).
The tests in `test/ipc/` compare ChuiFrames' reader against these dumps. They read the JSON
with a small reader in `test/ipc/ipc_setup.jl`, so the tests need no Python and no JSON
package. NaN/Inf, bytes, dates, timestamps, lists and structs are encoded as small objects,
as `enc` in `make_corpus.py` shows. `unsupported_*` and `ordered_dict` must raise.

Producers: pyarrow 26.0.0, Polars 2.0.0 (`polars_*`), R arrow 23.0.1.1 (`r_*`).

To regenerate, run the R script first (it writes the `r_*` files), then the Python one (it
writes everything else and dumps the R files too). Run both from a scratch directory, never
from inside the repo:

```sh
Rscript make_r_corpus.R OUTDIR
uv run --no-project --python 3.13 --with pyarrow==26.0.0 --with polars --with numpy python -I make_corpus.py OUTDIR
```

On 2026-10-20 (Polars 2.0.0, numpy from uv), both scripts reproduced every committed data file
byte for byte.
