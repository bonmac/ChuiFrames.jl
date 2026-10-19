## Operating rules

- Suites live in `benchmark/benchmarks.jl` and define `SUITE` (BenchmarkTools).
- Report hardware, Julia version, thread count, package versions, cold vs warm, median and spread.
- Publish losses as well as wins.
- A regression beyond the tolerance in `ratchets.toml` fails CI (`julia scripts/ci.jl bench`).
- Close other heavy processes; one benchmark run at a time per machine.
- Change files only with the Edit/Write tools. Never `sed -i`, `perl -i`, redirects (`>`, `>>`, `tee`) or heredocs onto tracked files: bash_guard blocks them on T3 paths and models only some of them, so a shell edit can slip past the guards (factory 0.2.4).
