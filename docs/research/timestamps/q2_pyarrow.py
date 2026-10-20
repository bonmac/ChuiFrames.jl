import os, io
import pyarrow as pa, pyarrow.compute as pc, pyarrow.csv as pcsv, pyarrow.parquet as pq
OUT = os.path.join(os.path.dirname(os.path.abspath(__file__)), "out")
print("pyarrow", pa.__version__)

def tryit(label, f):
    try:
        print(f"{label}: {f()!r}")
    except Exception as e:
        print(f"{label}: ERROR {type(e).__name__}: {str(e).splitlines()[0]}")

v = 1704110400  # 2024-01-01T12:00:00Z
s = pa.array([v], pa.timestamp("s"))
ms = pa.array([v * 1000], pa.timestamp("ms"))
us = pa.array([v * 10**6], pa.timestamp("us"))
ns = pa.array([v * 10**9], pa.timestamp("ns"))
ns1 = pa.array([v * 10**9 + 1], pa.timestamp("ns"))
utc = pa.array([v * 10**6], pa.timestamp("us", tz="UTC"))
ber = pa.array([v * 10**6], pa.timestamp("us", tz="Europe/Berlin"))
ny_ns = pa.array([v * 10**9], pa.timestamp("ns", tz="America/New_York"))

print("\n## compute.equal across units / zones")
tryit("equal(s, ms)", lambda: pc.equal(s, ms).to_pylist())
tryit("equal(us, ns)", lambda: pc.equal(us, ns).to_pylist())
tryit("equal(us, ns+1ns)", lambda: pc.equal(us, ns1).to_pylist())
tryit("less(us, ns+1ns)", lambda: pc.less(us, ns1).to_pylist())
tryit("equal(naive us, utc us)", lambda: pc.equal(us, utc).to_pylist())
tryit("equal(utc us, berlin us) same stored value", lambda: pc.equal(utc, ber).to_pylist())
tryit("equal(utc us, NY ns) same instant", lambda: pc.equal(utc, ny_ns).to_pylist())
tryit("utc.cast(timestamp(us))", lambda: utc.cast(pa.timestamp("us")).type)
tryit("us.cast(timestamp(us,UTC))", lambda: us.cast(pa.timestamp("us", "UTC")).type)
tryit("ns1.cast(us) safe", lambda: ns1.cast(pa.timestamp("us")))
tryit("ns1.cast(us) unsafe", lambda: ns1.cast(pa.timestamp("us"), safe=False).to_pylist())

print("\n## zone strings")
for z in ["UTC", "Europe/Berlin", "+01:00", "-05:30", "Etc/GMT-1", "EST", "Z", "Not/AZone"]:
    def f(z=z):
        a = pa.array([v * 10**6], pa.timestamp("us", tz=z))
        return (str(a.type), str(pc.strftime(a, format="%Y-%m-%dT%H:%M:%S%z")[0]))
    tryit(f"tz={z!r} type+strftime", f)
    tryit(f"tz={z!r} pc.hour", lambda z=z: pc.hour(pa.array([v * 10**6], pa.timestamp("us", tz=z))).to_pylist())

print("\n## CSV write")
t = pa.table({"s": s, "ms": ms, "us": us, "ns": ns1, "us_utc": utc, "us_berlin": ber, "ns_ny": ny_ns,
              "s_plus1": pa.array([v], pa.timestamp("s", tz="+01:00"))})
print(t.schema)
buf = io.BytesIO()
pcsv.write_csv(t, buf)
txt = buf.getvalue().decode()
print(txt)
rb = pcsv.read_csv(io.BytesIO(buf.getvalue()))
print("read_csv schema:\n", rb.schema)
print("read_csv values (int64):", {n: rb[n].cast(pa.int64()).to_pylist() for n in rb.column_names})

print("\n## Parquet")
for kw in [{}, {"version": "2.4"}, {"version": "1.0"}, {"coerce_timestamps": "ms", "allow_truncated_timestamps": True}]:
    p = os.path.join(OUT, f"pa_{'_'.join(f'{k}{v}' for k,v in kw.items()) or 'default'}.parquet")
    try:
        pq.write_table(t, p, **kw)
    except Exception as e:
        print(kw, "WRITE ERROR", type(e).__name__, str(e).splitlines()[0]); continue
    pf = pq.ParquetFile(p)
    print(f"--- write_table kwargs={kw} format_version={pf.metadata.format_version}")
    for i in range(len(pf.schema)):
        c = pf.schema.column(i)
        print(f"  {c.name}: physical={c.physical_type} logical={c.logical_type}")
    print("  read back:", {f.name: str(f.type) for f in pq.read_table(p).schema})
    print("  read back (no ARROW:schema, i.e. parquet-only):",
          {f.name: str(f.type) for f in pq.read_table(p, schema=None).schema} if False else "see below")
# read ignoring stored arrow schema
p = os.path.join(OUT, "pa_noarrowschema.parquet")
pq.write_table(t, p, store_schema=False)
print("--- store_schema=False read back:", {f.name: str(f.type) for f in pq.read_table(p).schema})
print("default write_table version doc default:", pq.write_table.__doc__.split("version :")[1].split("\n")[1:4] if "version :" in (pq.write_table.__doc__ or "") else "n/a")
