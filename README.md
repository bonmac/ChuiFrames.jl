# ChuiFrames.jl

Data frames for the Chui ecosystem: Arrow-backed columnar storage, dplyr/tidyr-style verbs,
and one engine with lazy and eager modes.

**Status: pre-release scaffold.** The package loads and exports nothing yet; the design is
being worked out in phase 1 (research and ADRs). It is not registered.

- Brief: [`docs/agent/BRIEF.md`](docs/agent/BRIEF.md)
- Current state: [`HANDOFF.md`](HANDOFF.md)
- Agent instructions: [`CLAUDE.md`](CLAUDE.md)

```sh
julia --project=. -e 'using Pkg; Pkg.instantiate(); Pkg.test()'
```

License: MIT (see [`LICENSE`](LICENSE)).
