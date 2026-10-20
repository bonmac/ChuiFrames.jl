"""Arrow IPC spike corpus (ADR-0001 rule 10) written by pyarrow and Polars.

Usage: uv run --no-project --python 3.13 --with pyarrow==26.0.0 --with polars --with numpy python -I make_corpus.py OUTDIR
Writes OUTDIR/<case>.arrow|.arrows and OUTDIR/<case>.json (the pyarrow dump: expected values).
The r_feather/r_stream cases are written by R arrow (see README.md) and only dumped by pyarrow.
"""
import base64, datetime, json, math, os, sys

import polars as pl
import pyarrow as pa
import pyarrow.ipc as ipc

out = sys.argv[1]
os.makedirs(out, exist_ok=True)

LONG = ["short", "a string longer than twelve bytes", None, "ünïcödé text, long enough", ""]


def enc(v):
    if v is None:
        return None
    if isinstance(v, float):
        if math.isnan(v):
            return {"float": "NaN"}
        if math.isinf(v):
            return {"float": "Inf" if v > 0 else "-Inf"}
        return v
    if isinstance(v, bool):
        return v
    if isinstance(v, (bytes, bytearray)):
        return {"bytes": base64.b16encode(bytes(v)).decode().lower()}
    if isinstance(v, datetime.datetime):
        return {"datetime": v.isoformat()}
    if isinstance(v, datetime.date):
        return {"date": v.isoformat()}
    if isinstance(v, dict):
        return {"struct": {k: enc(x) for k, x in v.items()}}
    if isinstance(v, list):
        return {"list": [enc(x) for x in v]}
    if isinstance(v, (int, str)):
        return v
    return {"repr": str(v)}


def dump(name, path, stream):
    """Expected values: read back with pyarrow, one entry per batch plus the concatenation."""
    with open(path, "rb") as f:
        r = ipc.open_stream(f) if stream else ipc.open_file(f)
        batches = list(r) if stream else [r.get_batch(i) for i in range(r.num_record_batches)]
        schema = r.schema
    t = pa.Table.from_batches(batches, schema=schema)
    doc = {
        "format": "stream" if stream else "file",
        "schema": [{"name": f.name, "type": str(f.type), "nullable": f.nullable} for f in schema],
        "batch_lengths": [b.num_rows for b in batches],
        "num_rows": t.num_rows,
        "columns": {n: [enc(x) for x in t.column(n).to_pylist()] for n in t.column_names},
    }
    with open(os.path.join(out, name + ".json"), "w") as f:
        json.dump(doc, f, indent=1)
    print(name, doc["format"], [str(f.type) for f in schema], doc["batch_lengths"])


def write_file(name, table_or_batches, schema=None, options=None):
    path = os.path.join(out, name + ".arrow")
    batches = table_or_batches if isinstance(table_or_batches, list) else table_or_batches.to_batches()
    schema = schema or batches[0].schema
    with ipc.new_file(path, schema, options=options) as w:
        for b in batches:
            w.write_batch(b)
    dump(name, path, False)


def write_stream(name, batches, schema=None, options=None):
    path = os.path.join(out, name + ".arrows")
    schema = schema or batches[0].schema
    with ipc.new_stream(path, schema, options=options) as w:
        for b in batches:
            w.write_batch(b)
    dump(name, path, True)


# 1. Polars defaults (LC-04): file, stream, compat-oldest file; strings > 12 bytes => variadic buffers
pdf = pl.DataFrame({
    "a": LONG * 3,
    "b": [s[::-1] if s else s for s in LONG] * 3,
    "i": [1, None, 3, 4, 5] * 3,
    "f": [1.5, float("nan"), None, -0.0, 2.25] * 3,
    "flag": [True, False, None, True, False] * 3,
})
pdf.write_ipc(os.path.join(out, "polars_file.arrow"))
dump("polars_file", os.path.join(out, "polars_file.arrow"), False)
pdf.write_ipc_stream(os.path.join(out, "polars_stream.arrows"))
dump("polars_stream", os.path.join(out, "polars_stream.arrows"), True)
pdf.write_ipc(os.path.join(out, "polars_oldest.arrow"), compat_level=pl.CompatLevel.oldest())
dump("polars_oldest", os.path.join(out, "polars_oldest.arrow"), False)
for comp in ["lz4", "zstd"]:
    pdf.write_ipc(os.path.join(out, f"polars_{comp}.arrow"), compression=comp)
    dump(f"polars_{comp}", os.path.join(out, f"polars_{comp}.arrow"), False)
# Polars multi-batch: write_ipc rechunks a concat(rechunk=False) frame into ONE batch, so ask
# for small record batches explicitly (Polars 2.0.0 `record_batch_size`).
pmulti = pl.concat([pdf, pdf.head(2), pdf], rechunk=False)
pmulti.write_ipc(os.path.join(out, "polars_multibatch.arrow"), record_batch_size=7)
dump("polars_multibatch", os.path.join(out, "polars_multibatch.arrow"), False)

# 2. ST-03: two Utf8View columns with long strings (variadic buffers), plus BinaryView
sv = pa.array(LONG, type=pa.string_view())
sv2 = pa.array([s.upper() if s else s for s in LONG], type=pa.string_view())
bv = pa.array([b"x", b"a binary value longer than 12", None, b"", b"\x00\x01"], type=pa.binary_view())
write_file("st03_two_views", pa.table({"v1": sv, "v2": sv2, "bv": bv}))
write_stream("st03_two_views_stream", pa.table({"v1": sv, "v2": sv2, "bv": bv}).to_batches())

# 3. ST-04: a dictionary column in a sliced batch (indices buffer longer than the batch)
d = pa.array(["a", "b", "a", "c", "b", "a"]).dictionary_encode()
sliced = pa.record_batch({"d": d, "x": pa.array([1, 2, 3, 4, 5, 6])}).slice(1, 4)
write_file("st04_sliced_dict", [sliced])
write_stream("st04_sliced_dict_stream", [sliced])

# 4. #610: replacement dictionaries in a stream (each batch its own dictionary)
dt = pa.dictionary(pa.int32(), pa.string())
b1 = pa.record_batch({"d": pa.DictionaryArray.from_arrays(pa.array([0, 1, 0], pa.int32()), pa.array(["x", "y"]))})
b2 = pa.record_batch({"d": pa.DictionaryArray.from_arrays(pa.array([1, 0, None], pa.int32()), pa.array(["p", "q"]))})
b3 = pa.record_batch({"d": pa.DictionaryArray.from_arrays(pa.array([2, 2], pa.int32()), pa.array(["k", "l", "m"]))})
write_stream("dict_replacement_stream", [b1, b2, b3], schema=pa.schema([("d", dt)]))

# 5. delta dictionaries in a stream (pyarrow emits deltas when the new dict extends the old)
e1 = pa.record_batch({"d": pa.DictionaryArray.from_arrays(pa.array([0, 1], pa.int32()), pa.array(["x", "y"]))})
e2 = pa.record_batch({"d": pa.DictionaryArray.from_arrays(pa.array([2, 0, 3], pa.int32()), pa.array(["x", "y", "z", "w"]))})
e3 = pa.record_batch({"d": pa.DictionaryArray.from_arrays(pa.array([4, None], pa.int32()), pa.array(["x", "y", "z", "w", "v"]))})
write_stream("dict_delta_stream", [e1, e2, e3], schema=pa.schema([("d", dt)]),
             options=ipc.IpcWriteOptions(emit_dictionary_deltas=True))
# duplicate dictionary entries and an index pointing at a null dictionary entry (ADR-0001 rule 5)
dd = pa.DictionaryArray.from_arrays(pa.array([0, 1, 2, 3, 0], pa.int8()), pa.array(["a", "a", None, "b"]))
write_file("dict_dups_nullentry", pa.table({"d": dd}))

# 6. compressed files and streams, pyarrow
wide = pa.table({
    "i64": pa.array(list(range(1000)), pa.int64()),
    "s": pa.array([f"row {k} with a longish payload" if k % 7 else None for k in range(1000)]),
    "f": pa.array([k / 3 if k % 5 else None for k in range(1000)], pa.float64()),
})
for comp in ["lz4", "zstd"]:
    write_file(f"pyarrow_{comp}", wide, options=ipc.IpcWriteOptions(compression=comp))
    write_stream(f"pyarrow_{comp}_stream", wide.to_batches(max_chunksize=300),
                 options=ipc.IpcWriteOptions(compression=comp))

# 7. every supported type, two batches, with nulls
t1 = pa.table({
    "i8": pa.array([1, None, -3], pa.int8()), "i16": pa.array([1, 2, None], pa.int16()),
    "i32": pa.array([None, 2, 3], pa.int32()), "i64": pa.array([1, 2, 3], pa.int64()),
    "u8": pa.array([1, 255, None], pa.uint8()), "u16": pa.array([1, 2, 3], pa.uint16()),
    "u32": pa.array([1, None, 3], pa.uint32()), "u64": pa.array([2**64 - 1, 0, None], pa.uint64()),
    "f32": pa.array([1.5, None, float("nan")], pa.float32()), "f64": pa.array([-0.0, float("inf"), None]),
    "b": pa.array([True, None, False]),
    "s": pa.array(["x", None, "zz"]), "ls": pa.array(["x", "", None], pa.large_string()),
    "bin": pa.array([b"\x01", None, b""], pa.binary()), "lbin": pa.array([b"ab", b"", None], pa.large_binary()),
    "d32": pa.array([datetime.date(2020, 1, 2), None, datetime.date(1969, 12, 31)], pa.date32()),
    "tsms": pa.array([datetime.datetime(2020, 1, 2, 3, 4, 5, 6000), None, datetime.datetime(1960, 1, 1)], pa.timestamp("ms")),
    "lst": pa.array([[1, 2], None, []], pa.list_(pa.int64())),
    "llst": pa.array([["a"], [None, "b"], None], pa.large_list(pa.string())),
    "st": pa.array([{"p": 1, "q": "x"}, None, {"p": None, "q": "z"}], pa.struct([("p", pa.int32()), ("q", pa.string())])),
})
write_file("alltypes", [*t1.to_batches(), *t1.slice(1, 2).to_batches()], schema=t1.schema)
write_stream("alltypes_stream", [*t1.to_batches(), *t1.slice(1, 2).to_batches()], schema=t1.schema)

# 8. edge cases: empty table with a schema, a batch of length 0 between batches, non-nullable fields
empty_schema = pa.schema([("x", pa.int64()), ("s", pa.string())])
with ipc.new_file(os.path.join(out, "empty.arrow"), empty_schema) as w:
    pass
dump("empty", os.path.join(out, "empty.arrow"), False)
nn = pa.schema([pa.field("x", pa.int64(), nullable=False), pa.field("y", pa.float64(), nullable=True)])
bb = [pa.record_batch([pa.array([1, 2]), pa.array([0.5, None])], schema=nn),
      pa.record_batch([pa.array([], pa.int64()), pa.array([], pa.float64())], schema=nn),
      pa.record_batch([pa.array([3]), pa.array([1.0])], schema=nn)]
write_file("nonnull_zero_batch", bb, schema=nn)

# 9. types that must raise ArgumentError naming the type (ADR-0001 rule 6) and an ordered dictionary
import decimal
write_file("unsupported_decimal", pa.table({"x": pa.array([decimal.Decimal("1.25")], pa.decimal128(5, 2))}))
write_file("unsupported_time", pa.table({"x": pa.array([datetime.time(1, 2)], pa.time64("us"))}))
write_file("unsupported_ree", pa.table({"x": pa.RunEndEncodedArray.from_arrays([2, 3], [1, 2])}))
write_file("unsupported_tsus", pa.table({"x": pa.array([datetime.datetime(2020, 1, 1)], pa.timestamp("us"))}))
od = pa.DictionaryArray.from_arrays(pa.array([0, 1], pa.int8()), pa.array(["lo", "hi"]), ordered=True)
write_file("ordered_dict", pa.table({"x": od}))
# every other type of ADR-0001 rule 6's "must raise" list (case name -> array)
import numpy as np
raise_cases = {
    "date64": pa.array([datetime.date(2020, 1, 1)], pa.date64()),
    "float16": pa.array([np.float16(1.5)], pa.float16()),
    "duration": pa.array([datetime.timedelta(seconds=3)], pa.duration("s")),
    "interval": pa.array([pa.MonthDayNano([1, 2, 3])], pa.month_day_nano_interval()),
    "fixedsizebinary": pa.array([b"ab"], pa.binary(2)),
    "fixedsizelist": pa.array([[1, 2]], pa.list_(pa.int64(), 2)),
    "map": pa.array([[("k", 1)]], pa.map_(pa.string(), pa.int64())),
    "union": pa.UnionArray.from_dense(pa.array([0], pa.int8()), pa.array([0], pa.int32()), [pa.array([1])]),
    "null": pa.array([None], pa.null()),
    "listview": pa.array([[1]], pa.list_view(pa.int64())),
    "largelistview": pa.array([[1]], pa.large_list_view(pa.int64())),
    "extension": pa.ExtensionArray.from_storage(pa.uuid(), pa.array([b"0123456789abcdef"], pa.binary(16))),
    "tsns": pa.array([datetime.datetime(2020, 1, 1)], pa.timestamp("ns")),
    "tss": pa.array([datetime.datetime(2020, 1, 1)], pa.timestamp("s")),
    "tsmstz": pa.array([datetime.datetime(2020, 1, 1)], pa.timestamp("ms", tz="UTC")),
}
for k, arr in raise_cases.items():
    write_file(f"unsupported_{k}", pa.table({"x": arr}))

# 10. R arrow files, when make_r_corpus.R has written them into OUTDIR first: dump only
for name, ext, stream in (("r_feather", ".arrow", False), ("r_stream", ".arrows", True)):
    if os.path.exists(os.path.join(out, name + ext)):
        dump(name, os.path.join(out, name + ext), stream)
