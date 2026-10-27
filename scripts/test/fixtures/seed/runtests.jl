# Seeded by the ecosystem factory. Test items (TestItemRunner, ADR-0007) are selected by tag:
#   julia scripts/ci.jl test                 -> everything except the tags in EXCLUDE
#   julia scripts/ci.jl test -- laws unit    -> only items tagged :laws or :unit
#   julia scripts/ci.jl test -- all          -> every item except :contract
# :contract items run in their own environment (test/contracts/), via `julia scripts/ci.jl contracts`.
#
# Supposition properties and laws (ADR-0007 §2, amended 2026-10-20) take this form, on every Julia version:
#   @testitem "addition commutes" tags = [:property] begin
#       using Supposition
#       ints = Data.Integers{Int8}()
#       sr = @check record = false db = false (a = ints, b = ints) -> a + b == b + a
#       @test Supposition.results(sr).ispass      # `results` is not exported
#   end
# - record=false + an explicit @test: on Julia 1.10 a failing `@check` that records itself in the enclosing
#   testset is silently dropped (summary "None", exit 0); 1.13 reports it. The explicit @test fails on both.
# - db=false: Supposition's counterexample DB (test/SuppositionDB/, gitignored) written by 1.13 crashes 1.10
#   ("Cannot read stream serialized with a newer version"). Keep a counterexample as a plain unit test.
# A manifest resolved on 1.13 may not load on 1.10 (PrecompileTools 1.3.x needs Julia >= 1.12): give the LTS
# its own gitignored Manifest-v1.10.toml, which Julia 1.10 reads in preference to Manifest.toml.
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
# --- item selection ---
# (factory 0.3.0; scripts/test/test_runtests_template.jl evaluates this block on its own.)
# `item=<name>` in the test args selects test items by exact name (spaces allowed:
#   Pkg.test(test_args = ["item=adds two numbers"])). The filter order (spec 2026-10-26 §3.4):
#   1. :contract is never selected; 2. not stable: :doctest/:snapshot are not selected;
#   3. any item= argument: selected iff the name matches one; 4. otherwise `nothing`, the tags decide.
function select_item(name::AbstractString, tags, args::Vector{String}; stable::Bool)::Union{Bool, Nothing}
    :contract in tags && return false
    !stable && (:doctest in tags || :snapshot in tags) && return false
    items = [a[(length("item=") + 1):end] for a in args if startswith(a, "item=")]
    isempty(items) && return nothing
    return name in items
end
# TDD_MATCHED=<file>: append each selected item's name, one per line (never truncates). Unset: no-op.
function record_match(name, env = ENV)
    p = get(env, "TDD_MATCHED", "")
    isempty(p) && return nothing
    open(io -> write(io, name, "\n"), p, "a")
    return nothing
end
# --- end item selection ---
# JET is not here: see test/jet/.
const EXCLUDE = is_stable() ?
    (:slow, :quality, :contract, :differential) :
    (:slow, :quality, :contract, :differential, :doctest, :snapshot)
is_stable() || @info "not stable Julia (VERSION $VERSION < STABLE_MIN $STABLE_MIN, or CI_STABLE=false): :doctest and :snapshot items skipped"
const SELECT = Symbol.(ARGS)
:contract in SELECT && @info "contract items run in test/contracts/'s own environment: julia scripts/ci.jl contracts"

const STABLE = is_stable()
function select_by_tags(tags)
    :contract in tags && return false
    :all in SELECT && return true
    isempty(SELECT) && return !any(in(EXCLUDE), tags)
    return any(in(SELECT), tags)
end

@run_package_tests filter = ti -> begin
    sel = select_item(ti.name, ti.tags, ARGS; stable = STABLE)
    sel === nothing && (sel = select_by_tags(ti.tags))
    sel && record_match(ti.name)
    return sel
end
