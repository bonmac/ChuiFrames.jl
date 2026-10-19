# Factory tests: every script and hook in scripts/ and .claude/hooks/ has tests here.
#   julia scripts/test/runtests.jl            (also run by `julia scripts/ci.jl guards`)
# Stdlib only. Hooks are run as real `sh` processes with JSON on stdin. Needs git and jq.
using Test

const SCRIPTS = normpath(joinpath(@__DIR__, ".."))
const ROOT = normpath(joinpath(SCRIPTS, ".."))
const HOOKS = joinpath(ROOT, ".claude", "hooks")
const FACTORY = normpath(joinpath(ROOT, ".."))           # set when run inside factory/template
const IN_FACTORY = isfile(joinpath(FACTORY, "MANIFEST.toml")) && isfile(joinpath(FACTORY, "VERSION"))
const JULIA = [Base.julia_cmd().exec; "--startup-file=no"]

for f in ("gen.jl", "dod.jl", "ratchet.jl", "check_docs.jl", "ci.jl", "lane.jl", "sync_factory.jl", "bench.jl", "contract_usage.jl")
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
    sh(`git -C $d commit -q -m $msg`)
end
"Run f with stdout captured; returns (result, output)."
function capture(f)
    p = tempname()
    r = open(p, "w") do io
        redirect_stdout(f, io)
    end
    return r, read(p, String)
end

@testset "factory" begin
    t0 = time()
    include("test_gen.jl")
    include("test_hooks.jl")
    include("test_dod.jl")
    include("test_ratchet.jl")
    include("test_check_docs.jl")
    include("test_contract_usage.jl")
    include("test_ci.jl")
    include("test_lane.jl")
    include("test_sync_factory.jl")
    println("factory tests finished in $(round(time() - t0; digits = 1)) s")
end
