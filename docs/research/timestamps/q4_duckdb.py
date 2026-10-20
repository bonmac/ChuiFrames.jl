import duckdb, pyarrow as pa
print("duckdb", duckdb.__version__, "pyarrow", pa.__version__)
con = duckdb.connect()
print("TimeZone setting:", con.sql("SELECT current_setting('TimeZone')").fetchone())
q = """SELECT TIMESTAMP '2024-01-01 12:00:00' AS ts,
  TIMESTAMP_NS '2024-01-01 12:00:00.123456789' AS ts_ns,
  TIMESTAMP_MS '2024-01-01 12:00:00' AS ts_ms,
  TIMESTAMP_S '2024-01-01 12:00:00' AS ts_s,
  TIMESTAMPTZ '2024-01-01 12:00:00+00' AS tstz"""
print(con.sql(q).arrow().schema if hasattr(con.sql(q).arrow(), "schema") else con.sql(q).arrow())
tbl = con.sql(q).to_arrow_table()
print("to_arrow_table schema:\n", tbl.schema)
def t(label, sql):
    try:
        print(label, con.sql(sql).fetchall())
    except Exception as e:
        print(label, "ERROR", type(e).__name__, str(e).splitlines()[0])
t("TS == TS_NS same instant:", "SELECT TIMESTAMP '2024-01-01 12:00:00' = TIMESTAMP_NS '2024-01-01 12:00:00'")
t("TS == TS_NS +1ns:", "SELECT TIMESTAMP '2024-01-01 12:00:00' = TIMESTAMP_NS '2024-01-01 12:00:00.000000001'")
t("TS <  TS_NS +1ns:", "SELECT TIMESTAMP '2024-01-01 12:00:00' < TIMESTAMP_NS '2024-01-01 12:00:00.000000001'")
t("typeof(TS = TS_NS operands cast):", "SELECT typeof(CASE WHEN true THEN TIMESTAMP '2024-01-01' ELSE TIMESTAMP_NS '2024-01-01' END)")
t("TS == TIMESTAMPTZ:", "SELECT TIMESTAMP '2024-01-01 12:00:00' = TIMESTAMPTZ '2024-01-01 12:00:00+00'")
t("TS_S == TS_MS:", "SELECT TIMESTAMP_S '2024-01-01 12:00:00' = TIMESTAMP_MS '2024-01-01 12:00:00'")
con.sql("SET TimeZone='UTC'")
t("(TimeZone=UTC) TS == TIMESTAMPTZ:", "SELECT TIMESTAMP '2024-01-01 12:00:00' = TIMESTAMPTZ '2024-01-01 12:00:00+00'")
print("tstz arrow type after SET TimeZone=UTC:", con.sql("SELECT TIMESTAMPTZ '2024-01-01 12:00:00+00' AS x").to_arrow_table().schema)
con.sql("SET TimeZone='Europe/Berlin'")
print("tstz arrow type after SET TimeZone=Europe/Berlin:", con.sql("SELECT TIMESTAMPTZ '2024-01-01 12:00:00+00' AS x").to_arrow_table().schema)
# Arrow -> DuckDB ingestion
arrtbl = pa.table({"ns": pa.array([0], pa.timestamp("ns")), "us_ber": pa.array([0], pa.timestamp("us", "Europe/Berlin")), "s": pa.array([0], pa.timestamp("s"))})
print("arrow->duckdb types:", con.sql("SELECT typeof(ns), typeof(us_ber), typeof(s) FROM arrtbl").fetchall())
print("round trip arrow schema:", con.sql("SELECT * FROM arrtbl").to_arrow_table().schema)
for z in ["+01:00", "Etc/GMT-1"]:
    try:
        con.sql(f"SET TimeZone='{z}'"); print(f"SET TimeZone='{z}' ok ->", con.sql("SELECT TIMESTAMPTZ '2024-01-01 12:00:00+00'::VARCHAR").fetchone())
    except Exception as e:
        print(f"SET TimeZone='{z}' ERROR", type(e).__name__, str(e).splitlines()[0])
