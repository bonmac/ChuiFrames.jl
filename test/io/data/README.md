# I/O test fixtures

- `timestamps_exact.parquet` and `timestamps_exact_noschema.parquet` (ADR-0021 TS-12): columns
  `ms` (`timestamp[ms]`), `us` (`timestamp[us]`), `ns_utc` (`timestamp[ns, tz=UTC]`), `us_b`
  (`timestamp[us, tz=Europe/Berlin]`) and `ms_utc` (`timestamp[ms, tz=UTC]`) over values that
  Parquet2's own decoding reads 1 ms early. The second file has no `ARROW:schema` metadata.
  Written by pyarrow 26.0.0 with:

  ```sh
  uv run --no-project --python 3.13 --with pyarrow==26.0.0 python -I -c 'import pyarrow as pa, pyarrow.parquet as pq; v=[-2186259751700, -2176368591140, 1085072413093, 1704164645123]; c=lambda xs, t: pa.array(xs, pa.int64()).cast(t); t=pa.table({"ms": c(v, pa.timestamp("ms")), "us": c([x*1000+7 for x in v], pa.timestamp("us")), "ns_utc": c([x*10**6+9 for x in v], pa.timestamp("ns", tz="UTC")), "us_b": c([x*1000 for x in v], pa.timestamp("us", tz="Europe/Berlin")), "ms_utc": c(v, pa.timestamp("ms", tz="UTC"))}); pq.write_table(t, "timestamps_exact.parquet"); pq.write_table(t, "timestamps_exact_noschema.parquet", store_schema=False)'
  ```

- `timestamps_stats.parquet` and `timestamps_stats_none.parquet` (exact timestamp statistics):
  12 rows in 3 row groups of 4, ascending and disjoint across groups but not sorted within
  one. Columns `i` (`int64`, the row id 0-11), `ms` (`timestamp[ms]`), `us` (`timestamp[us]`,
  `ms*1000+7`), `ns` (`timestamp[ns]`, `ms*10^6+9`), `ms_utc` (`timestamp[ms, tz=UTC]`),
  `ns_utc` (`timestamp[ns, tz=UTC]`), `us_b` (`timestamp[us, tz=Europe/Berlin]`, `ms*1000+3`)
  and `ms_null` (`timestamp[ms]`, null in row 6). The ms bounds of groups 1 and 2 are values
  Parquet2's Float64 path decodes 1 ms late (TS-12). The second file is written with
  `write_statistics=False`. Written by pyarrow 26.0.0 with:

  ```sh
  uv run --no-project --python 3.13 --with pyarrow==26.0.0 python -I -c 'import pyarrow as pa, pyarrow.parquet as pq; v=[-2186259700000, -2186259551700, -2186259751700, -2186259651000, 1085072500000, 1085072613093, 1085072413093, 1085072600000, 1704164645123, 1704164700000, 1704164600000, 1704164645000]; c=lambda xs, t: pa.array(xs, pa.int64()).cast(t); t=pa.table({"i": pa.array(range(12), pa.int64()), "ms": c(v, pa.timestamp("ms")), "us": c([x*1000+7 for x in v], pa.timestamp("us")), "ns": c([x*10**6+9 for x in v], pa.timestamp("ns")), "ms_utc": c(v, pa.timestamp("ms", tz="UTC")), "ns_utc": c([x*10**6+9 for x in v], pa.timestamp("ns", tz="UTC")), "us_b": c([x*1000+3 for x in v], pa.timestamp("us", tz="Europe/Berlin")), "ms_null": c([None if k == 6 else x for k, x in enumerate(v)], pa.timestamp("ms"))}); pq.write_table(t, "timestamps_stats.parquet", row_group_size=4); pq.write_table(t, "timestamps_stats_none.parquet", row_group_size=4, write_statistics=False)'
  ```

- `timestamps_units.parquet`: one row group, columns `us` (`timestamp[us]`), `ns`
  (`timestamp[ns]`), `ms` (`timestamp[ms]`) and `d` (`date32`). Written by pyarrow 26.0.0
  (review finding M1, 2026-10-20) with:

  ```sh
  uv run --no-project --python 3.13 --with pyarrow==26.0.0 python -I -c 'import pyarrow as pa, pyarrow.parquet as pq, datetime; pq.write_table(pa.table({"us": pa.array([datetime.datetime(2024,1,1,0,0,0,123456)], type=pa.timestamp("us")), "ns": pa.array([1704067200123456789], type=pa.timestamp("ns")), "ms": pa.array([datetime.datetime(2024,1,1,0,0,0,123000)], type=pa.timestamp("ms")), "d": pa.array([datetime.date(2024,1,2)])}), "timestamps_units.parquet")'
  ```
