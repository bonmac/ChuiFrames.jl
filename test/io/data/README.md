# I/O test fixtures

- `timestamps_exact.parquet` and `timestamps_exact_noschema.parquet` (ADR-0021 TS-12): columns
  `ms` (`timestamp[ms]`), `us` (`timestamp[us]`), `ns_utc` (`timestamp[ns, tz=UTC]`), `us_b`
  (`timestamp[us, tz=Europe/Berlin]`) and `ms_utc` (`timestamp[ms, tz=UTC]`) over values that
  Parquet2's own decoding reads 1 ms early. The second file has no `ARROW:schema` metadata.
  Written by pyarrow 26.0.0 with:

  ```sh
  uv run --no-project --python 3.13 --with pyarrow==26.0.0 python -I -c 'import pyarrow as pa, pyarrow.parquet as pq; v=[-2186259751700, -2176368591140, 1085072413093, 1704164645123]; c=lambda xs, t: pa.array(xs, pa.int64()).cast(t); t=pa.table({"ms": c(v, pa.timestamp("ms")), "us": c([x*1000+7 for x in v], pa.timestamp("us")), "ns_utc": c([x*10**6+9 for x in v], pa.timestamp("ns", tz="UTC")), "us_b": c([x*1000 for x in v], pa.timestamp("us", tz="Europe/Berlin")), "ms_utc": c(v, pa.timestamp("ms", tz="UTC"))}); pq.write_table(t, "timestamps_exact.parquet"); pq.write_table(t, "timestamps_exact_noschema.parquet", store_schema=False)'
  ```

- `timestamps_units.parquet`: one row group, columns `us` (`timestamp[us]`), `ns`
  (`timestamp[ns]`), `ms` (`timestamp[ms]`) and `d` (`date32`). Written by pyarrow 26.0.0
  (review finding M1, 2026-10-20) with:

  ```sh
  uv run --no-project --python 3.13 --with pyarrow==26.0.0 python -I -c 'import pyarrow as pa, pyarrow.parquet as pq, datetime; pq.write_table(pa.table({"us": pa.array([datetime.datetime(2024,1,1,0,0,0,123456)], type=pa.timestamp("us")), "ns": pa.array([1704067200123456789], type=pa.timestamp("ns")), "ms": pa.array([datetime.datetime(2024,1,1,0,0,0,123000)], type=pa.timestamp("ms")), "d": pa.array([datetime.date(2024,1,2)])}), "timestamps_units.parquet")'
  ```
