# Seeded by the ecosystem factory. Test items (TestItemRunner, ADR-0007) are selected by tag:
#   julia scripts/ci.jl test                 -> everything except the tags in EXCLUDE
#   julia scripts/ci.jl test -- laws unit    -> only items tagged :laws or :unit
#   julia scripts/ci.jl test -- all          -> every item
using TestItemRunner

# :doctest and :snapshot output depends on the Julia version: CI runs them on stable only
# (CI.yml sets CI_STABLE=false on the lts and pre jobs). JET is not here: see test/jet/.
const EXCLUDE = get(ENV, "CI_STABLE", "true") == "false" ?
    (:slow, :quality, :contract, :differential, :doctest, :snapshot) :
    (:slow, :quality, :contract, :differential)
const SELECT = Symbol.(ARGS)

@run_package_tests filter = ti -> begin
    :all in SELECT && return true
    isempty(SELECT) && return !any(in(EXCLUDE), ti.tags)
    return any(in(SELECT), ti.tags)
end
