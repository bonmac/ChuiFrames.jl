# I/O test fixtures

- `timestamps_units.parquet`: one row group, columns `us` (`timestamp[us]`), `ns`
  (`timestamp[ns]`), `ms` (`timestamp[ms]`) and `d` (`date32`). Written by pyarrow 26.0.0
  (review finding M1, 2026-10-20) with:

  ```sh
  uv run --no-project --python 3.13 --with pyarrow==26.0.0 python -I -c 'import pyarrow as pa, pyarrow.parquet as pq, datetime; pq.write_table(pa.table({"us": pa.array([datetime.datetime(2024,1,1,0,0,0,123456)], type=pa.timestamp("us")), "ns": pa.array([1704067200123456789], type=pa.timestamp("ns")), "ms": pa.array([datetime.datetime(2024,1,1,0,0,0,123000)], type=pa.timestamp("ms")), "d": pa.array([datetime.date(2024,1,2)])}), "timestamps_units.parquet")'
  ```
