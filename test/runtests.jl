# Seeded by the ecosystem factory. Test items (TestItemRunner, ADR-0007) are selected by tag:
#   julia scripts/ci.jl test                 -> everything except the tags in EXCLUDE
#   julia scripts/ci.jl test -- laws unit    -> only items tagged :laws or :unit
#   julia scripts/ci.jl test -- all          -> every item except :contract
# :contract items run in their own environment (test/contracts/), via `julia scripts/ci.jl contracts`.
using TestItemRunner

# :doctest and :snapshot output depends on the Julia version: CI runs them on stable only
# (CI.yml sets CI_STABLE=false on the lts and pre jobs). JET is not here: see test/jet/.
const EXCLUDE = get(ENV, "CI_STABLE", "true") == "false" ?
    (:slow, :quality, :contract, :differential, :doctest, :snapshot) :
    (:slow, :quality, :contract, :differential)
const SELECT = Symbol.(ARGS)
:contract in SELECT && @info "contract items run in test/contracts/'s own environment: julia scripts/ci.jl contracts"

@run_package_tests filter = ti -> begin
    :contract in ti.tags && return false
    :all in SELECT && return true
    isempty(SELECT) && return !any(in(EXCLUDE), ti.tags)
    return any(in(SELECT), ti.tags)
end
