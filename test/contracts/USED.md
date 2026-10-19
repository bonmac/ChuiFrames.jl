# Contract IDs this package relies on

<!-- Seeded by the factory; repo-owned. Checked by `julia scripts/contract_usage.jl` (part of
     `julia scripts/ci.jl guards`) and by /contract-check. One line per upstream contract ID
     this package relies on, from the coordinator's contracts/<package>.md, e.g.

- CC-004 — aggregators in summarise

Each listed ID needs exactly one `@testitem "<ID> ..." tags = [:contract]` under
test/contracts/ (tested for real: no @test_skip), and must be stable or deprecated in the
upstream contract file named in upstreams.toml [contract_files]. Every qualified upstream name
used in src/ or ext/ that a contract's `names:` line covers needs that ID listed here.
Rule-only entries (no `names:` line) are listed by hand when relied on. -->

(none yet)
