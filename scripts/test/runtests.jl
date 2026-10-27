# Factory tests: every script and hook in scripts/ and .claude/hooks/ has tests here.
#   julia scripts/test/runtests.jl            (also run by `julia scripts/ci.jl guards`)
# Stdlib only. Hooks are run as real `sh` processes with JSON on stdin. Needs git and jq.
using Test
using TOML, SHA   # here too, so a FACTORY_TEST_ONLY selection runs without the files that import them

# factory 0.3.0: a caller's FACTORY_ALLOW_* leaked into every child process and flipped 101+ hook deny tests.
foreach(v -> delete!(ENV, v), ("FACTORY_ALLOW_T3", "FACTORY_ALLOW_PUSH", "FACTORY_ALLOW_OUTWARD"))

const SCRIPTS = normpath(joinpath(@__DIR__, ".."))
const ROOT = normpath(joinpath(SCRIPTS, ".."))
const HOOKS = joinpath(ROOT, ".claude", "hooks")
const FACTORY = normpath(joinpath(ROOT, ".."))           # set when run inside factory/template
const IN_FACTORY = isfile(joinpath(FACTORY, "MANIFEST.toml")) && isfile(joinpath(FACTORY, "VERSION"))
const JULIA = [Base.julia_cmd().exec; "--startup-file=no"]

for f in (
        "gen.jl", "dod.jl", "ratchet.jl", "check_docs.jl", "ci.jl", "lane.jl", "sync_factory.jl", "bench.jl", "contract_usage.jl",
        "changelog.jl", "check_claims.jl", "evidence.jl",
    )
    include(joinpath(SCRIPTS, f))
end

sh(cmd) = run(pipeline(cmd; stdout = devnull, stderr = devnull))
"A fresh git repo with one commit on `main`; `files` maps relative path => content."
function tmp_repo(files = Dict{String, String}())
    d = realpath(mktempdir())
    sh(`git -C $d init -q -b main`)
    sh(`git -C $d config user.email t@example.com`)
    sh(`git -C $d config user.name test`)
    sh(`git -C $d config commit.gpgsign false`)
    isempty(files) && (files = Dict("README.md" => "x\n"))
    for (rel, c) in files
        mkpath(dirname(joinpath(d, rel)))
        write(joinpath(d, rel), c)
    end
    sh(`git -C $d add -- .`)
    sh(`git -C $d commit -q -m init`)
    return d
end
function commit!(d, files::Dict, msg = "change")
    for (rel, c) in files
        mkpath(dirname(joinpath(d, rel)))
        write(joinpath(d, rel), c)
    end
    sh(`git -C $d add -- .`)
    return sh(`git -C $d commit -q -m $msg`)
end
"Run f with stdout captured; returns (result, output)."
function capture(f)
    p = tempname()
    r = open(p, "w") do io
        redirect_stdout(f, io)
    end
    return r, read(p, String)
end

"""
The package profile's seeded `name` (`risk.toml` or `runtests.jl`), from fixtures/seed/. Tests of
dod and tdd behaviour build their scratch repos from it, never from the host repo's own seeded copy:
a coordinator's risk.toml has no `tdd` tier and it has no test/ (tw-032). test_dod.jl checks that
the fixtures equal factory/template's seeds.
"""
seed_fixture(name) = read(joinpath(@__DIR__, "fixtures", "seed", name), String)

"The top-level test files, in order. Others (test_tdd_cli.jl, test_tdd_history*.jl, ...) are included by these."
const TEST_FILES = [
    "test_gen.jl",
    "test_hooks.jl",
    "test_env_isolation.jl",
    "test_hooks_lifecycle.jl",
    "test_hooks_tdd.jl",   # tdd_boundary hook and commit guard (plan Task 8; includes test_hooks_tdd2.jl)
    "test_bash_guard.jl",
    "test_dod.jl",
    "test_ratchet.jl",
    "test_check_docs.jl",
    "test_contract_usage.jl",
    "test_ci.jl",
    "test_lane.jl",
    "test_changelog.jl",
    "test_check_claims.jl",
    "test_evidence.jl",
    "test_sync_factory.jl",
    "test_runtests_template.jl",
    "test_tdd.jl",
    "test_tdd_rename.jl",   # renamed red item must not deadlock green (0.3.0)
    "test_tdd_backfill.jl",
    "test_tdd_classify2.jl",
    "test_tdd_review.jl",
    "test_tdd_c1.jl",   # critic C1: test-side roles (law/property/differential) author test phases
    "test_tdd_c2.jl",   # critic C2: one trailer parser (git's), phase-less role commits
    "test_tdd_c3.jl",   # critic C3/C6: skip separators, lead-only modes, per-merge segments
    "test_tdd_c4.jl",   # critic C4/C7/C8: commit in its own call, E5 lead waiver, blind spots
    "test_tdd_c5.jl",   # review of the critic fixes: sub-lane merged twice, trailer forms
    "test_profile_coordinator.jl",   # tw-032: the dod and tdd tests pass in a coordinator-profile sync
]
# FACTORY_TEST_ONLY=a.jl,b.jl runs only those of TEST_FILES (test_profile_coordinator.jl uses it).
# A name not in TEST_FILES (a nested file would run nothing) is an error, never an empty pass.
const ONLY = filter(!isempty, strip.(split(get(ENV, "FACTORY_TEST_ONLY", ""), ',')))
for f in ONLY
    f in TEST_FILES || error("FACTORY_TEST_ONLY: $f is not a top-level file of scripts/test/runtests.jl")
end

@testset "factory" begin
    t0 = time()
    for f in TEST_FILES
        (isempty(ONLY) || f in ONLY) && include(f)
    end
    println("factory tests finished in $(round(time() - t0; digits = 1)) s")
end
