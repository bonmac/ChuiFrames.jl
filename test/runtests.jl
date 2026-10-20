# Seeded by the ecosystem factory. Test items (TestItemRunner, ADR-0007) are selected by tag:
#   julia scripts/ci.jl test                 -> everything except the tags in EXCLUDE
#   julia scripts/ci.jl test -- laws unit    -> only items tagged :laws or :unit
#   julia scripts/ci.jl test -- all          -> every item except :contract
# :contract items run in their own environment (test/contracts/), via `julia scripts/ci.jl contracts`.
using TestItemRunner

# --- stable-only tags (factory 0.2.7; scripts/test/test_runtests_template.jl evaluates this block) ---
# :doctest and :snapshot output depends on the Julia version: they run on stable Julia only
# (ecosystem ADR-0008 §3). CI_STABLE=true/false decides, both ways (CI.yml sets it per job: false on
# lts and pre). Unset (a plain `]test`), the Julia version decides: stable iff VERSION >= STABLE_MIN.
# Before 0.2.7 unset meant stable, so `]test` on the LTS ran the doctests and failed.
# STABLE_MIN: the oldest Julia whose printed output the doctests and snapshots were written against.
# Name a RELEASED version: prereleases sort below it (v"1.13.0-rc1" < v"1.13"), so they count as not stable.
const STABLE_MIN = v"1.13"
# Exactly "true", "false", or unset/empty; anything else is an ArgumentError (as ChuiCore.jl e80dce9).
function is_stable(env = ENV, v = VERSION)
    s = get(env, "CI_STABLE", "")
    return s == "true" ? true : s == "false" ? false : isempty(s) ? v >= STABLE_MIN :
        throw(ArgumentError("CI_STABLE must be \"true\", \"false\" or unset, got $(repr(s))"))
end
# --- end stable-only tags ---
# JET is not here: see test/jet/.
const EXCLUDE = is_stable() ?
    (:slow, :quality, :contract, :differential) :
    (:slow, :quality, :contract, :differential, :doctest, :snapshot)
is_stable() || @info "not stable Julia (VERSION $VERSION < STABLE_MIN $STABLE_MIN, or CI_STABLE=false): :doctest and :snapshot items skipped"
const SELECT = Symbol.(ARGS)
:contract in SELECT && @info "contract items run in test/contracts/'s own environment: julia scripts/ci.jl contracts"

@run_package_tests filter = ti -> begin
    :contract in ti.tags && return false
    :all in SELECT && return true
    isempty(SELECT) && return !any(in(EXCLUDE), ti.tags)
    return any(in(SELECT), ti.tags)
end
