## Operating rules

- Suites live in `benchmark/benchmarks.jl` and define `SUITE` (BenchmarkTools).
- Report hardware, Julia version, thread count, package versions, cold vs warm, median and spread.
- Publish losses as well as wins.
- A regression beyond the tolerance in `ratchets.toml` fails CI (`julia scripts/ci.jl bench`).
- Close other heavy processes; one benchmark run at a time per machine.
