# Dependency candidates for ChuiFrames

- **Date:** 2026-10-20
- **Lane:** phase1-research (researcher). Input to the dependency-budget ADR and the per-dependency
  ADRs; recommendations here are proposals, not decisions.
- **Question:** for each candidate: latest registered version, Julia compat, direct and transitive
  registered dependency count, release/activity, maintainers, load time; then core / extension /
  test-only / reject.

## Versions and setup

- Julia 1.13.2 (load times, all candidates) and 1.10.12 (`julia +lts`, a core subset). Apple M3 Pro.
- Registry: local General snapshot, `~/.julia/registries/General.toml` (tree
  `3909358acc0fb535d4cb67fa03ee5836ad28b0f2`, tarball dated 2026-10-19), read in place with
  `Pkg.Registry.reachable_registries()` (no extraction).
- GitHub data: `gh api repos/<owner>/<repo>` (read-only), 2026-10-20. Parquet2 is on GitLab
  (public API via `curl`).

## Method

1. **Closure** (DP-01, DP-02): the E-27 method in the coordinator's evidence log, re-implemented
   on Pkg's `RegistryInstance` API: take the latest non-yanked version, apply the `Deps.toml`
   ranges to it, then recurse taking each dependency at its latest version. Strong deps only
   (weak deps listed separately). Stdlibs (names in `Sys.STDLIB`, including stdlib JLLs) and
   `julia` are excluded from "registered"; non-stdlib JLL binary packages (e.g. `Lz4_jll`) are
   counted. This approximates a resolve; it is not one.
2. **Julia compat** (DP-01): the `julia` entry of `Compat.toml` for the latest version.
3. **Load time** (DP-03, DP-04): one fresh environment per package (`Pkg.add`, `Pkg.precompile`),
   one discarded warm-up, then 3 x `julia --startup-file=no --project=<env> -e '@time using X'`.
   A first 1.13 pass ran while other benchmarks loaded the machine (Arrow read 2.0-4.0 s there);
   it was discarded and all 1.13 numbers below are a rerun on a quiet machine.
4. **Activity** (DP-05, DP-06): `pushed_at`, latest GitHub release, open issues+PRs, and the
   number of human contributors with ≥ 5 commits (a maintainer proxy; "maintainers" proper are
   not visible through the API).

## Summary table

Load times are three runs in seconds, Julia 1.13.2. "Contrib" = contributors with ≥ 5 commits.

| Package | Latest | julia compat | 1.10? | Direct / transitive reg. | Load (s) | Latest release | Last push | Contrib | Proposal |
|---|---|---|---|---|---|---|---|---|---|
| Tables | 1.14.0 | [1.9, 2) | yes | 5 / 5 | 0.012 0.015 0.013 | 2026-08-24 | 2026-10-17 | 6 | **core** |
| DataAPI | 1.16.0 | [1, 2) | yes | 0 / 0 | 0.001 0.002 0.004 | 2024-01-22 | 2026-10-09 | 3 | **core** (via Tables anyway) |
| Arrow | 2.8.1 | [1.9, 2) | yes | 13 / 28 | 0.150 0.171 0.149 | 2026-01-14 | 2026-10-09 | 7 | ADR (see storage.md) |
| ArrowTypes | 2.3.0 | [1, 2) | yes | 0 / 0 | 0.003 0.003 0.003 | (monorepo) | | | with Arrow only |
| Parquet2 | 0.2.37 | [1.10, 2) | yes | 25 / 64 | 1.201 1.214 1.308 | GitLab, 2026-09-18 commit | 2026-09-27 | n/a | reject as core; extension at most |
| Parquet | 0.8.6 | [1.3, 2) | yes | 11 / 25 | 0.124 0.115 0.124 | 2025-08-01 | 2026-10-09 | 5 | ADR (built-in Parquet) |
| CSV | 1.1.0 | [1.10, 2) | yes | 7 / 14 | 0.157 0.160 0.168 | 2026-09-21 | 2026-10-16 | 9 | test-only / ADR |
| PooledArrays | 1.4.3 | [1, 2) | yes | 1 / 1 | 0.008 0.006 0.007 | 2023-09-17 | 2026-10-09 | 6 | core candidate (or own codes) |
| CategoricalArrays | 1.1.1 | [1.6, 2) | yes | 4 / 4 | 0.028 0.027 0.024 | 2026-05-29 | 2026-10-09 | 6 | extension |
| InlineStrings | 2.0.1 | [1.10, 2) | yes | 0 / 0 | 0.004 0.003 0.004 | 2026-09-04 | 2026-10-09 | 3 | reject |
| WeakRefStrings | 2.0.0 | [1.3, 2) | yes | 2 / 2 | 0.006 0.006 0.007 | 2026-10-15 | 2026-10-15 | 3 | reject |
| StringViews | 2.0.1 | [1.6, 2) | yes | 0 / 0 | 0.003 0.003 0.004 | 2026-06-11 | 2026-07-14 | 2 | core candidate |
| SentinelArrays | 1.4.10 | [1.3, 2) | yes | 0 / 0 | 0.016 0.016 0.016 | 2026-05-18 | 2026-10-15 | 3 | reject |
| Missings | 1.2.0 | [1, 2) | yes | 1 / 1 | 0.003 0.003 0.003 | 2024-04-06 | 2026-10-15 | 5 | reject (Base suffices) |
| PrecompileTools | 1.3.4 | **[1.12, 2)** | **no** (1.2.1 resolves on 1.10) | 1 / 1 | 0.017 0.021 0.016 | 2026-05-12 | 2026-10-14 | 2 | core |
| Compat | 4.18.1 | [1.6, 2) | yes | 0 / 0 | 0.005 0.003 0.003 | 2025-09-30 | 2026-07-14 | 34 | core (if ecosystem uses it) |
| DBInterface | 2.7.0 | [1.9, 2) | yes | 0 / 0 | 0.002 0.002 0.002 | 2026-08-10 | 2026-10-09 | 3 | extension |
| XLSX | 0.13.1 | [1.10, 2) | yes | 7 / 20 | 0.232 0.212 0.212 | 2026-10-07 | 2026-10-19 | 6 | extension |
| ReadStat | 1.2.0 | [1.10, 2) | yes | 2 / 6 | 0.039 0.037 0.038 | 2026-08-31 | 2026-09-21 | 3 | extension |
| JSON3 | 1.14.3 | [1.6, 2) | yes | 3 / 4 | 0.049 0.046 0.045 | 2025-05-23 | 2026-10-15 | 4 | reject (prefer JSON 1.x) |
| JSON | 1.11.0 | [1.10, 2) | yes | 3 / 4 | 0.067 0.068 0.070 | 2026-10-16 | 2026-10-16 | 16 | extension |
| HTTP | 2.11.0 | [1.10, 2) | yes | 5 / 7 | 0.091 0.092 0.092 | 2026-10-16 | 2026-10-16 | 39 | extension |
| AWSS3 | 0.11.7 | [1.6, 2) | yes | 12 / 30 | 0.233 0.218 0.217 | 0.11.4 on GitHub, 2025-05-21 | 2026-09-23 | 11 | extension |
| AWS | 1.100.0 | [1.8, 2) | yes | 10 / 25 | 0.215 0.207 0.215 | 2026-09-19 | 2026-10-09 | 21 | via AWSS3 only |
| Dagger | 0.22.7 | [1.10, 2) | yes | 18 / 89 | 0.759 0.781 0.796 | 2026-10-13 | 2026-10-18 | 20 | extension, later phase |
| Distributed | stdlib | n/a | yes | n/a | 0.010 0.011 0.010 | n/a | 2026-10-13 | 22 | extension, later phase |
| Metatheory | 2.1.0 | [1.8, 2) | yes | 7 / 19 | 0.088 0.092 0.088 | 2.0.2 on GitHub, 2023-11-10 | 2026-10-19 | 6 | reject |
| RuntimeGeneratedFunctions | 0.5.27 | [1.10, 2) | yes | 2 / 3 | 0.021 0.029 0.025 | 2026-09-26 | 2026-10-17 | 6 | ADR (lazy engine codegen) |
| Mmap | stdlib | n/a | yes | n/a | 0.005 0.005 0.005 | n/a | n/a | n/a | core |
| TranscodingStreams | 0.11.3 | [1.6, 2) | yes | 0 / 0 | 0.002 0.002 0.002 | (tags on other names) | 2026-10-09 | 4 | core if Parquet is built in |
| CodecZstd | 0.8.7 | [1.6, 2) | yes | 1 / 1 (+ Zstd_jll stdlib) | 0.006 0.007 0.007 | 2025-11-08 | 2026-10-09 | 4 | core if Parquet is built in |
| Polyester | 0.7.19 | [1.6, 2) | yes | 10 / 20 | 0.065 0.062 0.062 | 2026-02-10 | 2026-02-10 | 5 | reject |
| OhMyThreads | 0.8.7 | [1.10, 2) | yes | 5 / 12 | 0.036 0.042 0.039 | 2026-10-02 | 2026-10-02 | 3 | ADR (vs Base threads) |
| ScopedValues | 1.6.2 | [1.8, 2) | yes | 1 / 1 | 0.002 0.002 0.002 | 2026-04-28 | 2026-04-28 | 1 | not direct (via ChuiTypes) |

**Compat flags.** Only **PrecompileTools 1.3.x** excludes Julia 1.10 (julia compat `[1.12, 2)` for
1.3.0-1.3.4); on 1.10.12 the resolver picks **1.2.1** (DP-04, DP-07), so a `PrecompileTools = "1"`
compat entry still works on both. No other candidate's latest version excludes 1.10. Arrow 2.8.1
holds **StringViews at 1.x** and, through TimeZones, **InlineStrings at 1.x** (DP-08).

**Julia 1.10 load times** (DP-04): Tables 0.025 0.015 0.019; Arrow 0.241 0.309 0.266;
PooledArrays 0.014 0.021 0.016; DataAPI 0.003 0.008 0.002; InlineStrings 0.045 0.039 0.035;
StringViews 0.007 0.008 0.005; SentinelArrays 0.027 0.018 0.023; Missings 0.015 0.006 0.008;
PrecompileTools (1.2.1) 0.013 0.008 0.014; CSV 0.215 0.351 0.201; Parquet2 1.197 1.173 1.209.

## Per candidate

**Tables 1.14.0 — core.** The interop contract every reader and sink in the ecosystem speaks;
5 small transitive deps, 13 ms load. The frame must be a Tables.jl source and sink.

**DataAPI 1.16.0 — core.** Zero deps, already in Tables' closure; carries `refarray`/`refpool`
(used by PooledArrays and CategoricalArrays) and the metadata API.

**Arrow 2.8.1 — decided by the storage ADR.** The brief makes Arrow IPC a built-in format. As an
in-memory engine it brings 28 transitive deps (TimeZones, CodecLz4, BitIntegers, …), ~1 s first
read, read-only columns, and read gaps found in storage.md (two Utf8View columns fail, no
ListView/REE, a dictionary-length bug, no view writer), with a 3.0 rewrite in a draft PR. As an
I/O-only dependency the same closure applies. The alternative is an own IPC reader/writer over
Mmap + FlatBuffers parsing (no registered FlatBuffers dependency assessed here: UNVERIFIED).

**ArrowTypes 2.3.0 — only with Arrow.** Zero deps; needed to customise how our types serialise.

**Parquet2 0.2.37 — reject as core; extension at most.** 25 direct / 64 transitive (Transducers,
LazyArrays, StaticArrays, DecFP, Thrift2, five ChunkCodec packages), 1.2 s to load on both Julia
versions. Reads and writes (`writefile`). GitLab-hosted, single main author (UNVERIFIED count;
GitLab does not expose it through the call used).

**Parquet 0.8.6 — candidate for the built-in Parquet, ADR.** 11 / 25, 0.12 s; exports
`read_parquet` and `write_parquet`. Pulls CategoricalArrays, Thrift, Snappy, Decimals. Last
release 2025-08-01. Feature coverage (nested types, statistics for pushdown) was not tested:
UNVERIFIED.

**CSV 1.1.0 — test-only (differential reference) unless the I/O ADR adopts it.** 7 / 14, 0.16 s.
The brief asks for readr-style readers, which suggests an own parser with CSV.jl as the parity
oracle. Its weak deps include InlineStrings and FilePathsBase.

**PooledArrays 1.4.3 — core candidate.** One dep (DataAPI). Group-by on its refs is 2.9 ms vs
114 ms hashing `Vector{String}` for 10M rows (storage.md ST-10), and Arrow.jl writes it as a
dictionary column. Last release 2023-09-17 (stable, low churn). Alternative: own codes type.

**CategoricalArrays 1.1.1 — extension.** forcats parity and interop with users' categorical
columns; 4 deps incl. Requires; 25 ms load.

**InlineStrings 2.0.1 — reject.** No hashing gain over `String` in ST-10 (108 vs 114 ms) and
`String31` uses 4x the memory; values arriving from CSV.jl are plain `AbstractString`s we can
accept without the dependency.

**WeakRefStrings 2.0.0 — reject.** Legacy CSV.jl storage; re-exports InlineStrings.

**StringViews 2.0.1 — core candidate.** Zero deps, 3 ms; `StringView` over a byte buffer hashes
equal to `String`, the element type an own offsets/views string column needs. Conflict: released
Arrow.jl 2.8.1 requires StringViews 1.x (its `main` supports 2.0, unreleased).

**SentinelArrays 1.4.10 — reject.** Arrow.jl returns `ChainedVector`s for multi-batch columns;
we would not build on sentinels for nulls (the brief says validity bitmaps).

**Missings 1.2.0 — reject.** `missing`, `skipmissing`, `nonmissingtype` are in Base; the extras
(`passmissing`, `allowmissing`) are small to own.

**PrecompileTools 1.3.4 — core.** Standard for TTFX; compat `"1"` resolves 1.2.1 on 1.10 and
1.3.4 on 1.12+ (flagged above).

**Compat 4.18.1 — core if the ecosystem uses `@compat public`** (the minimum-Julia ADR mentions it).
Zero registered deps.

**DBInterface 2.7.0 — extension.** Zero deps, 2 ms; the database integration point in the brief.

**XLSX 0.13.1 — extension.** 7 / 20, 0.22 s.

**ReadStat 1.2.0 — extension (haven parity).** 2 / 6 incl. `ReadStat_jll` and DataValues.
Also noticed: ReadStatTables.jl exists (Context7 lists it); not assessed.

**JSON 1.11.0 vs JSON3 1.14.3 — extension on JSON 1.x.** Same closure size (3 / 4); JSON.jl 1.x
is the actively released one (2026-10-16, 16 contributors ≥ 5 commits) while JSON3's last
release is 2025-05-23.

**HTTP 2.11.0 — extension.** 5 / 7, 0.09 s; 39 contributors.

**AWSS3 0.11.7 (+ AWS 1.100.0) — extension.** 12 / 30, 0.22 s; 94 open issues+PRs on AWSS3.
Its GitHub releases stop at 0.11.4 while the registry has 0.11.7.

**Dagger 0.22.7 — extension, later phase (distributed mode).** 18 / 89 transitive (GPU and
statistics stacks), 0.77 s. It now depends on DistributedNext, not the Distributed stdlib.

**Distributed (stdlib) — extension, later phase.** 10 ms. Evaluated against Dagger and Arrow
Flight in the distributed-mode ADR.

**Metatheory 2.1.0 — reject.** 7 / 19 deps; the brief puts optimizer rewrites on ChuiCore's
recursion schemes. Its GitHub releases stop at 2.0.2 (2023-11-10) while the registry has 2.1.0.

**RuntimeGeneratedFunctions 0.5.27 — engine ADR.** 2 / 3, 25 ms. Relevant if the lazy engine
compiles plans to Julia code without `eval` world-age problems.

**Mmap (stdlib) — core.** Zero-copy file reads (Arrow.jl uses it).

**TranscodingStreams 0.11.3 + CodecZstd 0.8.7 — core if Parquet (or compressed Arrow IPC) is
built in.** 0 and 1 registered deps; Zstd_jll is a stdlib JLL.

**Polyester 0.7.19 — reject.** 10 / 20 (the JuliaSIMD stack); last push 2026-02-10.

**OhMyThreads 0.8.7 — threading ADR vs Base `Threads.@spawn`.** 5 / 12, 39 ms; task-based and
composable. Base alone costs nothing.

**ScopedValues 1.6.2 — not a direct dep.** ChuiTypes already brings it for 1.10 (minimum-Julia ADR).

## Proposed budget (for the ADR)

Core, smallest set that meets the brief: Tables, DataAPI, PrecompileTools, Compat, Mmap, plus
StringViews and PooledArrays if own buffers are chosen, or Arrow (+ ArrowTypes) if Arrow.jl is
chosen; TranscodingStreams + CodecZstd with a built-in Parquet (Parquet.jl or own). Extensions:
CategoricalArrays, DBInterface, XLSX, ReadStat, JSON, HTTP, AWSS3, Dagger/Distributed. Test-only:
CSV (parity oracle), BenchmarkTools.

## UNVERIFIED

- Maintainer counts: "contributors with ≥ 5 commits" is a proxy; GitHub does not expose
  maintainer lists through these calls. Parquet2's GitLab contributor count was not fetched.
- Closure counts are the E-27 approximation (latest versions everywhere), not a Pkg resolve;
  an actual resolve can pick older versions (e.g. Arrow pins StringViews 1.x).
- Feature coverage of Parquet.jl and Parquet2 (nested types, page statistics, write fidelity).
- Whether Distributed is an upgradable stdlib on 1.11+ (not checked).
- Whether a registered FlatBuffers package fits an own Arrow IPC reader (not assessed).
- Registry release dates: taken from GitHub releases, which can lag or differ from registration
  (AWSS3, Metatheory, TranscodingStreams show this).

## Evidence

**DP-01** registry, latest and julia compat. `julia --startup-file=no regdeps2.jl Tables Arrow …`
(scratchpad `storage/regdeps2.jl`, output `regdeps.out`):
```
Tables | latest 1.14.0 | julia 1.9.0 - 1 | 1.10 ok: true | direct reg 5 | transitive reg 5 | stdlibs 0
Arrow | latest 2.8.1 | julia 1.9.0 - 1 | 1.10 ok: true | direct reg 13 | transitive reg 28 | stdlibs 16
Parquet2 | latest 0.2.37 | julia 1.10.0 - 1 | 1.10 ok: true | direct reg 25 | transitive reg 64 | stdlibs 22
PrecompileTools | latest 1.3.4 | julia 1.12.0 - 1 | 1.10 ok: false | direct reg 1 | transitive reg 1 | stdlibs 1
Dagger | latest 0.22.7 | julia 1.10.0 - 1 | 1.10 ok: true | direct reg 18 | transitive reg 89 | stdlibs 26
```
(one line per candidate; all 32 are in `regdeps.out`).

**DP-02** closures, examples:
```
Arrow transitive: ["ArrowTypes", "BitIntegers", "CodecLz4", "CodecZstd", "Compat", "ConcurrentUtilities", "DataAPI", "DataValueInterfaces", "EnumX", "ExprTools", "InlineStrings", "IteratorInterfaceExtensions", "JLLWrappers", "Lz4_jll", "Mocking", "OrderedCollections", "PooledArrays", "PrecompileTools", "Preferences", "RecipesBase", "Scratch", "SentinelArrays", "StringViews", "TZJData", "TableTraits", "Tables", "TimeZones", "TranscodingStreams"]
CSV transitive: ["CodecZlib", "DataAPI", "DataStrings", "DataValueInterfaces", "Durations", "IteratorInterfaceExtensions", "OrderedCollections", "Parsers", "PooledArrays", "PrecompileTools", "Preferences", "TableTraits", "Tables", "TranscodingStreams"]
Tables transitive: ["DataAPI", "DataValueInterfaces", "IteratorInterfaceExtensions", "OrderedCollections", "TableTraits"]
```

**DP-03** load times, Julia 1.13.2, quiet rerun: `julia --startup-file=no loadtimes.jl j113 julia -- <pkgs>`
(scratchpad `storage/load113_quiet.out`), e.g.
```
Arrow 2.8.1 | 0.150010 seconds (198.12 k allocations: 13.021 MiB) || 0.171163 seconds || 0.148986 seconds
Parquet2 0.2.37 | 1.200767 seconds (1.70 M allocations: 102.642 MiB, 3.09% gc time) || 1.214237 || 1.307884
Dagger 0.22.7 | 0.758922 seconds (1.09 M allocations: 66.817 MiB) || 0.780619 || 0.796213
Tables 1.14.0 | 0.012301 seconds (8.28 k allocations: 766.312 KiB) || 0.015218 || 0.012967
```

**DP-04** load times, Julia 1.10.12: `julia --startup-file=no loadtimes.jl lts julia +lts -- <pkgs>` (`loadlts.out`), e.g.
```
Arrow 2.8.1 | 0.241100 seconds (209.47 k allocations: 17.564 MiB, 14.51% compilation time) || 0.308979 || 0.266315
PrecompileTools 1.2.1 | 0.012679 seconds (11.28 k allocations: 1.508 MiB) || 0.007855 || 0.014005
Parquet2 0.2.37 | 1.197089 seconds (1.83 M allocations: 122.596 MiB, 4.23% gc time) || 1.172997 || 1.208511
```

**DP-05** GitHub activity (`gh api repos/$r`, `…/contributors?per_page=100` filtered to `type=="User"` and
`contributions>=5`, `…/releases?per_page=1`), e.g.
```
apache/arrow-julia | 2026-10-09 archived=false stars=315 issues=121 | contributors>=5 commits: 7 | latest GH release: v2.8.1 2026-01-14
JuliaLang/PrecompileTools.jl | 2026-10-14 archived=false stars=252 issues=21 | contributors>=5 commits: 2 | latest GH release: v1.3.4 2026-05-12
quinnj/JSON3.jl | 2026-10-15 archived=false stars=222 issues=4 | contributors>=5 commits: 4 | latest GH release: v1.14.3 2025-05-23
JuliaIO/JSON.jl | 2026-10-16 archived=false stars=359 issues=1 | contributors>=5 commits: 16 | latest GH release: v1.11.0 2026-10-16
JuliaSymbolics/Metatheory.jl | 2026-10-19 archived=false stars=404 issues=75 | contributors>=5 commits: 6 | latest GH release: v2.0.2 2023-11-10
```
(full output in scratchpad `storage/gh.out` and `storage/gh2.out`).

**DP-06** Parquet2 on GitLab: `curl https://gitlab.com/api/v4/projects/ExpandingMan%2FParquet2.jl` ->
`last_activity_at 2026-09-27T17:20:37Z, star_count 20, forks_count 10`; latest commits
`2026-09-18 bump version`, `Support WeakRevStrings@2`. Exports checked in the installed source:
`writefile` (write) and Parquet.jl `export write_parquet, read_parquet`.

**DP-07** PrecompileTools julia compat by version (registry): `1.3.0`…`1.3.4` all `julia 1.12.0 - 1`;
on 1.10.12 the per-package env resolves `PrecompileTools 1.2.1` (DP-04).

**DP-08** Arrow compat drag (scratchpad `storage/env`): `Pkg.add(name="Arrow", version="2.8.1")` ->
`StringViews v2.0.1 ⇒ v1.3.7`; `Pkg.status(outdated=true, mode=PKGMODE_MANIFEST)` ->
`InlineStrings v1.4.6 (<v2.0.1): TimeZones, WeakRefStrings`, `StringViews v1.3.7 (<v2.0.1): Arrow`.
Registry compat of Arrow 2.8.1: `StringViews 1`, `julia 1.9.0 - 1`.
