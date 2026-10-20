from datetime import datetime
import polars as pl
print("polars", pl.__version__)
f = "%Y-%m-%dT%H:%M:%S%.f"
us = pl.Series(["2024-01-01T12:00:00.000001"]).str.to_datetime(f, time_unit="us")
ns = pl.Series(["2024-01-01T12:00:00.000000999"]).str.to_datetime(f, time_unit="ns")
ns1 = pl.Series(["2024-01-01T12:00:00.000001000"]).str.to_datetime(f, time_unit="ns")
print("us 00.000001 == ns 00.000000999:", (us == ns).to_list())
print("us 00.000001 >  ns 00.000000999:", (us > ns).to_list())
print("us 00.000001 == ns 00.000001000:", (us == ns1).to_list())
print("ns.cast(us):", ns.cast(pl.Datetime("us")).dt.to_string("%Y-%m-%dT%H:%M:%S%.9f").to_list())
ms = pl.Series(["2024-01-01T12:00:00.0005"]).str.to_datetime(f, time_unit="us").cast(pl.Datetime("ms"))
print("us->ms cast of .0005:", ms.dt.to_string("%Y-%m-%dT%H:%M:%S%.6f").to_list())
usx = pl.Series(["2024-01-01T12:00:00.000500"]).str.to_datetime(f, time_unit="us")
print("ms(.000) == us(.0005):", (ms == usx).to_list())
df = pl.DataFrame({"a": us, "b": ns})
print("expr a==b:", df.select(pl.col("a") == pl.col("b")).to_series().to_list())
print("expr b==a:", df.select(pl.col("b") == pl.col("a")).to_series().to_list())
print("supertype a,b via concat_list? ", end="")
try:
    print(df.select(pl.concat_list("a", "b")).schema)
except Exception as e:
    print("ERROR", type(e).__name__, str(e).splitlines()[0])
print("coalesce dtype:", df.select(pl.coalesce("a", "b")).schema)
print("str.to_datetime ns w/o format time_unit=ns:", pl.Series(["2024-01-01 12:00:00.123456789"]).str.to_datetime(time_unit="ns").dt.to_string("%.9f").to_list())
# negative / pre-epoch truncation direction
neg = pl.Series(["1969-12-31T23:59:59.999999999"]).str.to_datetime(f, time_unit="ns")
print("pre-epoch ns->us:", neg.cast(pl.Datetime("us")).dt.to_string("%Y-%m-%dT%H:%M:%S%.6f").to_list())
