#!/usr/bin/env julia
# ci.jl: the ONE list of CI commands. GitHub workflows and local runs both call it, so a
# command is never copied into a Makefile or a second YAML file.
#
#   julia scripts/ci.jl --list                 jobs and the commands they run
#   julia scripts/ci.jl <job> [--dry-run] [-- extra args]
#
# Jobs: setup, test, quality, jet, format, docs, contracts, bench, coverage, guards, dod.
# Extra args after `--` go to the job: `test -- laws property`, `contracts -- main`.
module CI

using TOML
include(joinpath(@__DIR__, "_common.jl"))

const PKG_TEST = "using Pkg; Pkg.test(; coverage = get(ENV, \"CI_COVERAGE\", \"false\") == \"true\", test_args = ARGS)"
const RUNIC_ADD = "using Pkg; Base.find_package(\"Runic\") === nothing && Pkg.add(\"Runic\")"
const RUNIC_RUN = "using Runic; exit(Runic.main(ARGS))"
const DOCS_DEV = "using Pkg; Pkg.develop(PackageSpec(path = pwd())); Pkg.instantiate()"
const CONTRACT_MAIN = "using Pkg, TOML; for (n, u) in TOML.parsefile(\"test/contracts/upstreams.toml\")[\"upstreams\"]; Pkg.add(url = u, rev = \"main\"); end; Pkg.test(; test_args = [\"contract\"])"

# A command is an argv whose first element "julia" is replaced by the running julia binary.
const Argv = Vector{String}

struct Job
    summary::String
    commands::Function # (root, extra) -> Vector{Argv}, or a String explaining a skip
end

upstreams(root) = (p = joinpath(root, "test/contracts/upstreams.toml");
                   isfile(p) ? get(TOML.parsefile(p), "upstreams", Dict()) : Dict())

const SETUP = "using Pkg; Pkg.Registry.add(\"General\"); u = get(ENV, \"ECOSYSTEM_REGISTRY_URL\", \"\"); isempty(u) || Pkg.Registry.add(Pkg.RegistrySpec(url = u))"

const JOBS = Dict{String, Job}(
    "setup" => Job("Add the General registry, plus the personal registry when ECOSYSTEM_REGISTRY_URL is set (ADR-0005).",
        (root, extra) -> [["julia", "-e", SETUP]]),
    "test" => Job("Unit tests via Pkg.test; extra args select tags (`all` = every tag).",
        (root, extra) -> [["julia", "--project=.", "-e", PKG_TEST, "--", extra...]]),
    "jet" => Job("JET in its own env test/jet/ (JET 0.12 needs Julia >= 1.12; run on stable only).",
        (root, extra) -> isfile(joinpath(root, "test/jet/runjet.jl")) ?
            [["julia", "--project=test/jet", "-e", DOCS_DEV], ["julia", "--project=test/jet", "test/jet/runjet.jl"]] :
            "no test/jet/runjet.jl"),
    "quality" => Job("Aqua and ExplicitImports test items (tag :quality). JET is the separate `jet` job.",
        (root, extra) -> [["julia", "--project=.", "-e", PKG_TEST, "--", "quality"]]),
    "format" => Job("Runic check (ADR-0007): fails if any file is not formatted.",
        (root, extra) -> [["julia", "--project=@runic", "-e", RUNIC_ADD],
                          ["julia", "--project=@runic", "-e", RUNIC_RUN, "--", "--check", "--diff", "."]]),
    "docs" => Job("Build Documenter docs (doctests run inside the test suite too).",
        (root, extra) -> isfile(joinpath(root, "docs/make.jl")) ?
            [["julia", "--project=docs", "-e", DOCS_DEV], ["julia", "--project=docs", "docs/make.jl"]] :
            "no docs/make.jl"),
    "contracts" => Job("Contract tests (tag :contract) against the latest upstream release, or `-- main`.",
        function (root, extra)
            isempty(upstreams(root)) && return "no upstreams in test/contracts/upstreams.toml"
            if "main" in extra
                (get(ENV, "CI", "") == "true" || "--in-place" in extra) ||
                    return "the upstream-main run rewrites Project.toml; run it in CI or a lane with `-- main --in-place`"
                return [["julia", "--project=.", "-e", CONTRACT_MAIN]]
            end
            return [["julia", "--project=.", "-e", PKG_TEST, "--", "contract"]]
        end),
    "bench" => Job("Benchmark HEAD vs the merge base; fails beyond ratchets.toml bench.time_tolerance.",
        (root, extra) -> isfile(joinpath(root, "benchmark/benchmarks.jl")) ?
            [["julia", "scripts/bench.jl", extra...]] : "no benchmark/benchmarks.jl"),
    "coverage" => Job("Check lcov.info (from julia-processcoverage) against the coverage floor.",
        (root, extra) -> [["julia", "scripts/ratchet.jl", "--lcov", isempty(extra) ? "lcov.info" : extra[1]]]),
    "guards" => Job("Factory guards: generated files, ratchets, doc references, contract usage, factory tests.",
        (root, extra) -> [["julia", "scripts/gen.jl", "--check"], ["julia", "scripts/ratchet.jl"],
                          ["julia", "scripts/check_docs.jl"], ["julia", "scripts/contract_usage.jl"],
                          ["julia", "scripts/test/runtests.jl"]]),
    "dod" => Job("Definition of done for a PR (PR_LABELS, PR_BODY_FILE, BASE_REF from the environment).",
        (root, extra) -> [["julia", "scripts/dod.jl", "--base", get(ENV, "BASE_REF", "main"),
                           "--labels", get(ENV, "PR_LABELS", ""),
                           (haskey(ENV, "PR_BODY_FILE") ? ["--body-file", ENV["PR_BODY_FILE"]] : String[])...]]),
)

function tocmd(argv::Argv, root)
    exe = first(argv) == "julia" ? [Base.julia_cmd().exec; "--startup-file=no"] : [first(argv)]
    return Cmd(Cmd([exe; argv[2:end]]); dir = root)
end
show_argv(argv) = join((occursin(r"[\s\"'$;&|]", a) ? repr(a) : a for a in argv), ' ')

function run_job(name, root, extra; dry = false, io = stdout)
    haskey(JOBS, name) || (println(stderr, "ci.jl: unknown job `$name` (try --list)"); return 2)
    cmds = JOBS[name].commands(root, extra)
    if cmds isa String
        println(io, "ci.jl $name: skipped: $cmds")
        return 0
    end
    for argv in cmds
        println(io, "ci.jl $name\$ ", show_argv(argv))
        dry && continue
        ok = success(pipeline(tocmd(argv, root); stdout, stderr))
        ok || (println(io, "ci.jl $name: FAILED"); return 1)
    end
    dry || println(io, "ci.jl $name: OK")
    return 0
end

function main(args)
    root = normpath(joinpath(@__DIR__, ".."))
    i = findfirst(==("--"), args)
    head, extra = i === nothing ? (args, String[]) : (args[1:i-1], String.(args[i+1:end]))
    if head == ["--list"]
        for k in sort!(collect(keys(JOBS)))
            println(rpad(k, 10), JOBS[k].summary)
        end
        return 0
    end
    dry = "--dry-run" in head
    jobs = filter(!=("--dry-run"), head)
    length(jobs) == 1 || (println(stderr, "usage: julia scripts/ci.jl <job> [--dry-run] [-- args] | --list"); return 2)
    return run_job(only(jobs), root, extra; dry)
end

end # module

abspath(PROGRAM_FILE) == @__FILE__() && exit(CI.main(ARGS))
