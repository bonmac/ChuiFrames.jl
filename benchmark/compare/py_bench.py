"""py_bench.py: the db-benchmark-like queries on Polars and DuckDB (same Arrow IPC input).

    POLARS_MAX_THREADS=1 uv run --no-project --python 3.13 --with polars==2.0.0 \
        --with duckdb==1.5.6 --with pyarrow==26.0.0 python -I benchmark/compare/py_bench.py \
        DATADIR OUT.toml THREADS

Pins as the differential suite (test/engine/differential_polars_duckdb_tests.jl). THREADS is 1
(the like-for-like run for a single-threaded ChuiFrames run) or 0 (each tool's default). Polars'
thread pool is fixed at import, so its thread count comes from POLARS_MAX_THREADS (checked
against THREADS). Same timing protocol and TOML rows as chui.jl: one warm-up, then 3 timed runs
(1 when the warm-up took over 20 s), [min_s, median_s, result_rows]. Polars group-by results are
sorted by key (as ChuiFrames' are); DuckDB materializes each result into a temp table
(`CREATE OR REPLACE TEMP TABLE ans AS ...`) and adds ORDER BY for the group-by queries.
"""

import gc
import os
import statistics
import sys
import time

import duckdb
import polars as pl

DIR, OUT, THREADS = sys.argv[1], sys.argv[2], int(sys.argv[3])
if THREADS == 1:
    assert pl.thread_pool_size() == 1, "set POLARS_MAX_THREADS=1 for THREADS=1"


def timeit(f):
    gc.collect()
    t0 = time.perf_counter()
    r = f()
    w = time.perf_counter() - t0
    reps = 1 if w > 20 else 3
    ts = []
    for _ in range(reps):
        gc.collect()
        t0 = time.perf_counter()
        f()
        ts.append(time.perf_counter() - t0)
    return [min(ts), statistics.median(ts), r]


def path(name):
    return os.path.join(DIR, name)


G1 = pl.read_ipc(path("G1.arrow"))
X = pl.read_ipc(path("X.arrow"))
SMALL = pl.read_ipc(path("SMALL.arrow"))
MEDIUM = pl.read_ipc(path("MEDIUM.arrow"))

PQ = {
    "groupby q1": lambda: G1.group_by("id1").agg(pl.sum("v1")).sort("id1"),
    "groupby q2": lambda: G1.group_by("id1", "id2").agg(pl.sum("v1")).sort("id1", "id2"),
    "groupby q3": lambda: G1.group_by("id3").agg(pl.sum("v1"), pl.mean("v3")).sort("id3"),
    "groupby q4": lambda: G1.group_by("id4").agg(pl.mean("v1"), pl.mean("v2"), pl.mean("v3")).sort("id4"),
    "groupby q5": lambda: G1.group_by("id6").agg(pl.sum("v1"), pl.sum("v2"), pl.sum("v3")).sort("id6"),
    "join q1": lambda: X.join(SMALL, on="id1", how="inner"),
    "join q2": lambda: X.join(MEDIUM, on="id2", how="inner"),
    "join q3": lambda: X.join(MEDIUM, on="id2", how="left"),
    "join q1r": lambda: SMALL.join(X, on="id1", how="inner"),
}

con = duckdb.connect()
if THREADS == 1:
    con.execute("SET threads = 1")
for name, df in (("g1", G1), ("x", X), ("small", SMALL), ("medium", MEDIUM)):
    con.register("tmp_" + name, df.to_arrow())
    con.execute(f"CREATE TABLE {name} AS SELECT * FROM tmp_{name}")
    con.unregister("tmp_" + name)


def dq(sql):
    def run():
        con.execute("CREATE OR REPLACE TEMP TABLE ans AS " + sql)
        return con.execute("SELECT count(*) FROM ans").fetchone()[0]

    return run


DQ = {
    "groupby q1": dq("SELECT id1, sum(v1) AS v1 FROM g1 GROUP BY id1 ORDER BY id1"),
    "groupby q2": dq("SELECT id1, id2, sum(v1) AS v1 FROM g1 GROUP BY id1, id2 ORDER BY id1, id2"),
    "groupby q3": dq("SELECT id3, sum(v1) AS v1, avg(v3) AS v3 FROM g1 GROUP BY id3 ORDER BY id3"),
    "groupby q4": dq("SELECT id4, avg(v1) AS v1, avg(v2) AS v2, avg(v3) AS v3 FROM g1 GROUP BY id4 ORDER BY id4"),
    "groupby q5": dq("SELECT id6, sum(v1) AS v1, sum(v2) AS v2, sum(v3) AS v3 FROM g1 GROUP BY id6 ORDER BY id6"),
    "join q1": dq("SELECT x.*, small.id4 AS id4_y, small.v2 FROM x JOIN small USING (id1)"),
    "join q2": dq("SELECT x.*, medium.id1 AS id1_y, medium.id4 AS id4_y, medium.v2 FROM x JOIN medium USING (id2)"),
    "join q3": dq("SELECT x.*, medium.id1 AS id1_y, medium.id4 AS id4_y, medium.v2 FROM x LEFT JOIN medium USING (id2)"),
    "join q1r": dq("SELECT small.*, x.id2, x.id4 AS id4_y, x.v1 FROM small JOIN x USING (id1)"),
}

load0 = os.getloadavg()
lines = []
for tool, qs in (("polars", PQ), ("duckdb", DQ)):
    for name, f in qs.items():
        tmin, tmed, r = timeit(f)
        n = r if isinstance(r, int) else r.height
        print(f"{tool:7s} {name:11s} min {tmin:.3f} s  median {tmed:.3f} s  rows {n}  load {os.getloadavg()[0]:.2f}", flush=True)
        lines.append(f'"{tool} {name}" = [{tmin!r}, {tmed!r}, {n}]')
load1 = os.getloadavg()
with open(OUT, "w") as io:
    io.write("[meta]\n")
    io.write(f'polars = "{pl.__version__}"\nduckdb = "{duckdb.__version__}"\npython = "{sys.version.split()[0]}"\n')
    io.write(f"threads = {THREADS}\npolars_threads = {pl.thread_pool_size()}\n")
    io.write(f"load_before = {list(load0)}\nload_after = {list(load1)}\n\n[rows]\n")
    io.write("\n".join(lines) + "\n")
