# Upstream incompatibility: AirspeedVelocity cannot install next to CSV.jl 1.x (not filed)

**Status: documented, not filed.** The user decided on 2026-10-20 (phase-2c ★) to record this and
not report it upstream. ChuiFrames does not depend on a fix: the factory lane is switching the
Benchmark workflow to `julia scripts/ci.jl bench` (`scripts/bench.jl`), which needs no
AirspeedVelocity. Revisit if AirspeedVelocity drops JSON3, or JSON3 widens its Parsers bound, and
the project wants AirspeedVelocity's PR comparison back (ADR-0022).

Filing is an outward action and needs the user.

## Summary

AirspeedVelocity 0.6.6 adds `BenchmarkTools`, `JSON3`, `Pkg` and `TOML` to every benchmark
environment it builds (its `Utils.jl`, function `_benchmark`). JSON3 1.14.3, the latest release and
marked deprecated in the General registry, caps Parsers at 2.8.8. CSV.jl 1.x needs Parsers 3. So
any package that depends on CSV 1.x, ChuiFrames included, cannot be benchmarked by
AirspeedVelocity: environment resolution fails before a benchmark runs.

The full reproduction, the resolver output and the reproduction without ChuiFrames
(`Pkg.add(["CSV", "JSON3"])` resolves CSV 0.10.17; pinning CSV 1.1 then fails) are PF-12 in
[performance.md](performance.md).

```
ERROR: Unsatisfiable requirements detected for package Parsers [69de0a69]:
 ├─restricted by compatibility requirements with CSV [336ed68f] to versions: 3.0.0
 │   └─restricted to versions 1 by ChuiFrames [a485ff65], leaving only versions: 1.0.0 - 1.1.0
 └─restricted by compatibility requirements with JSON3 [0f8b85d8] to versions: 0.3.0 - 2.8.8 — no versions left
```

## Draft issue text (for AirspeedVelocity.jl, not filed)

Title: Benchmark environments cannot resolve for packages that need CSV.jl 1.x (JSON3 caps Parsers)

AirspeedVelocity 0.6.6 adds JSON3 to the benchmark environment. JSON3 1.14.3 restricts Parsers to
≤ 2.8.8, while CSV.jl 1.x requires Parsers 3, so `benchmark(...)` fails during resolution for any
package depending on CSV 1.x. Would AirspeedVelocity consider JSON.jl 1.x (or another writer with no
Parsers bound) for its result files?

## Versions

AirspeedVelocity 0.6.6, JSON3 1.14.3, CSV 1.1.0, Parsers 3.0.0, Julia 1.13.2 (PF-12, 2026-10-20).
