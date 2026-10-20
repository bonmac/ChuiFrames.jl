import sys, os, io, traceback
from datetime import datetime, timezone, timedelta
import polars as pl, pyarrow as pa, pyarrow.ipc as ipc, pyarrow.parquet as pq

OUT = os.path.join(os.path.dirname(os.path.abspath(__file__)), "out")
print("polars", pl.__version__, "pyarrow", pa.__version__, "python", sys.version.split()[0])

def tryit(label, f):
    try:
        r = f()
        print(f"{label}: {r!r}")
    except Exception as e:
        print(f"{label}: ERROR {type(e).__name__}: {str(e).splitlines()[0]}")

print("\n## defaults")
tryit("Series([datetime]) dtype", lambda: pl.Series([datetime(2024, 1, 1, 12)]).dtype)
tryit("Series([aware datetime UTC]) dtype", lambda: pl.Series([datetime(2024, 1, 1, 12, tzinfo=timezone.utc)]).dtype)
tryit("Series([aware datetime +01:00]) dtype", lambda: pl.Series([datetime(2024, 1, 1, 12, tzinfo=timezone(timedelta(hours=1)))]).dtype)
tryit("datetime_range dtype", lambda: pl.datetime_range(datetime(2024,1,1), datetime(2024,1,2), "1h", eager=True).dtype)
tryit("datetime_range tz arg dtype", lambda: pl.datetime_range(datetime(2024,1,1), datetime(2024,1,2), "1h", time_zone="UTC", eager=True).dtype)
s = pl.Series(["2024-01-01 12:00:00.123456789"])
tryit("str.to_datetime (9 frac digits) dtype", lambda: s.str.to_datetime().dtype)
tryit("str.to_datetime (9 frac digits) value", lambda: s.str.to_datetime().to_list())
tryit("str.to_datetime (6 frac) dtype", lambda: pl.Series(["2024-01-01 12:00:00.123456"]).str.to_datetime().dtype)
tryit("str.to_datetime 'Z' dtype", lambda: pl.Series(["2024-01-01T12:00:00Z"]).str.to_datetime().dtype)
tryit("str.to_datetime '+01:00' dtype", lambda: pl.Series(["2024-01-01T12:00:00+01:00"]).str.to_datetime().dtype)
tryit("str.to_datetime '+01:00' value", lambda: pl.Series(["2024-01-01T12:00:00+01:00"]).str.to_datetime().to_list())
tryit("str.to_datetime ns+Z dtype", lambda: pl.Series(["2024-01-01T12:00:00.123456789Z"]).str.to_datetime().dtype)

print("\n## time zone strings")
for z in ["UTC", "Europe/Berlin", "+01:00", "Etc/GMT-1", "EST", "Z"]:
    tryit(f"dt.replace_time_zone({z!r})", lambda z=z: pl.Series([datetime(2024,1,1)]).dt.replace_time_zone(z).dtype)
    tryit(f"Datetime('us',{z!r}) cast", lambda z=z: pl.Series([datetime(2024,1,1)]).cast(pl.Datetime("us", z)).dtype)

print("\n## frame")
base = datetime(2024, 1, 1, 12, 0, 0)
df = pl.DataFrame({
    "us": pl.Series([base]).cast(pl.Datetime("us")),
    "ns_utc": pl.Series(["2024-01-01T12:00:00.123456789"]).str.to_datetime("%Y-%m-%dT%H:%M:%S%.f", time_unit="ns").dt.replace_time_zone("UTC"),
    "ms_berlin": pl.Series([base]).cast(pl.Datetime("ms")).dt.replace_time_zone("Europe/Berlin"),
})
print(df.schema)
print(df)

print("\n## write_ipc -> arrow schema")
p = os.path.join(OUT, "polars.arrow")
df.write_ipc(p)
with pa.memory_map(p) as f:
    print(ipc.open_file(f).schema)
tryit("read_ipc schema", lambda: pl.read_ipc(p).schema)

print("\n## comparisons")
naive = pl.Series("a", [base]).cast(pl.Datetime("us"))
utc = naive.dt.replace_time_zone("UTC")
berlin = utc.dt.convert_time_zone("Europe/Berlin")  # same instant
naive_ns = naive.cast(pl.Datetime("ns"))
tryit("Series naive == utc", lambda: (naive == utc).to_list())
tryit("Series utc == berlin(same instant)", lambda: (utc == berlin).to_list())
tryit("Series naive_us == naive_ns", lambda: (naive == naive_ns).to_list())
d2 = pl.DataFrame({"naive": naive, "utc": utc, "berlin": berlin, "ns": naive_ns})
tryit("expr naive == utc", lambda: d2.select(pl.col("naive") == pl.col("utc")).to_series().to_list())
tryit("expr utc == berlin", lambda: d2.select(pl.col("utc") == pl.col("berlin")).to_series().to_list())
tryit("expr naive(us) == ns", lambda: d2.select(pl.col("naive") == pl.col("ns")).to_series().to_list())
tryit("expr utc < berlin", lambda: d2.select(pl.col("utc") < pl.col("berlin")).to_series().to_list())
# us vs ns where ns has sub-us part
nsx = pl.Series(["2024-01-01T12:00:00.000000001"]).str.to_datetime("%Y-%m-%dT%H:%M:%S%.f", time_unit="ns")
tryit("naive_us(12:00) == ns(12:00:00.000000001)", lambda: (naive == nsx).to_list())
tryit("ns(...001) > us(12:00)", lambda: (nsx > naive).to_list())
tryit("compare to python datetime literal naive vs utc col", lambda: d2.select(pl.col("utc") == base).to_series().to_list())
tryit("concat us+ns", lambda: pl.concat([naive.to_frame("a"), naive_ns.to_frame("a")]).schema)
tryit("concat utc+berlin", lambda: pl.concat([utc.to_frame("a"), berlin.to_frame("a")]).schema)
tryit("join naive_us on naive_ns", lambda: naive.to_frame("k").join(naive_ns.to_frame("k"), on="k").height)
tryit("join utc on berlin", lambda: utc.to_frame("k").join(berlin.to_frame("k"), on="k").height)

print("\n## unique/group_by sub-us")
sub = pl.Series(["2024-01-01T12:00:00.000000001", "2024-01-01T12:00:00.000000002", "2024-01-01T12:00:00.000000001"]).str.to_datetime("%Y-%m-%dT%H:%M:%S%.f", time_unit="ns")
tryit("unique n", lambda: sub.unique().len())
tryit("n_unique", lambda: sub.n_unique())
tryit("group_by groups", lambda: sub.to_frame("t").group_by("t").len().sort("t").rows())

print("\n## write_csv")
csvp = os.path.join(OUT, "polars.csv")
df.write_csv(csvp)
print(open(csvp).read())
# extra: naive ns and utc us
df2 = pl.DataFrame({"ns_naive": nsx, "us_utc": utc, "s_berlin": berlin})
print(df2.write_csv())
tryit("read_csv(try_parse_dates) schema", lambda: pl.read_csv(csvp, try_parse_dates=True).schema)
tryit("read_csv(try_parse_dates) rows", lambda: pl.read_csv(csvp, try_parse_dates=True).rows())
tryit("read_csv(no parse) schema", lambda: pl.read_csv(csvp).schema)
tryit("read_csv df2 try_parse_dates schema", lambda: pl.read_csv(io.StringIO(df2.write_csv()), try_parse_dates=True).schema)
tryit("read_csv df2 try_parse_dates rows", lambda: pl.read_csv(io.StringIO(df2.write_csv()), try_parse_dates=True).rows())

print("\n## parquet")
pp = os.path.join(OUT, "polars.parquet")
df.write_parquet(pp)
tryit("read_parquet schema", lambda: pl.read_parquet(pp).schema)
pf = pq.ParquetFile(pp)
print(pf.schema)
print("arrow schema via pyarrow:", pf.schema_arrow)
print("kv metadata keys:", list((pf.metadata.metadata or {}).keys()))
