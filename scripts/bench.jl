#!/usr/bin/env julia
# bench.jl: benchmark-regression gate. Runs benchmark/benchmarks.jl (which defines a
# BenchmarkTools `SUITE`) on HEAD and on the merge base, compares median times, and fails
# when any benchmark is slower than ratchets.toml `bench.time_tolerance` allows.
#
#   julia scripts/bench.jl [--base main] [--root DIR]
#
# The benchmark environment is benchmark/Project.toml (must list BenchmarkTools); each tree
# is `Pkg.develop`ed into a temporary copy of it. Medians are exchanged as TOML
# ("group/name" = nanoseconds) so the comparison below is stdlib-only and unit-tested.
module Bench

using TOML
include(joinpath(@__DIR__, "_common.jl"))

const RUNNER = raw"""
using BenchmarkTools
tree, out = ARGS
include(joinpath(tree, "benchmark", "benchmarks.jl"))
tune!(SUITE)
m = median(run(SUITE; verbose = false))
flat = Dict{String, Float64}()
walk(g, p) = g isa BenchmarkGroup ? foreach(((k, v),) -> walk(v, isempty(p) ? string(k) : p * "/" * string(k)), g) :
             (flat[p] = time(g))
walk(m, "")
open(io -> TOML.print(io, flat), out, "w")
"""

"Benchmarks in both runs whose median slowed by more than `tol`; returns (name, ratio) pairs."
function regressions(old::AbstractDict, new::AbstractDict, tol::Real)
    out = Tuple{String, Float64}[]
    for (k, t) in new
        haskey(old, k) && old[k] > 0 || continue
        r = t / old[k]
        r > 1 + tol && push!(out, (k, r))
    end
    return sort!(out; by = last, rev = true)
end

function measure(tree, root, out)
    env = mktempdir()
    cp(joinpath(root, "benchmark", "Project.toml"), joinpath(env, "Project.toml"))
    jl = [Base.julia_cmd().exec; "--startup-file=no"; "--project=$env"]
    run(Cmd([jl; "-e"; "using Pkg; Pkg.develop(path = ARGS[1]); Pkg.instantiate()"; tree]))
    run(Cmd([jl; "-e"; "using TOML; " * RUNNER; tree; out]))
    return TOML.parsefile(out)
end

function main(args)
    opts, _ = parse_args(args, (), ("--base", "--root"))
    root = abspath(get(opts, "--root", normpath(joinpath(@__DIR__, ".."))))
    tol = get(get(TOML.parsefile(joinpath(root, "ratchets.toml")), "bench", Dict()), "time_tolerance", 0.10)
    mb = merge_base(root, get(opts, "--base", "main"))
    mb === nothing && (println(stderr, "bench.jl: no merge base"); return 2)
    basetree = joinpath(mktempdir(), "base")
    git(root, "worktree", "add", "--detach", basetree, mb; strict = true)
    try
        isfile(joinpath(basetree, "benchmark", "benchmarks.jl")) ||
            (println("bench.jl: no benchmarks at the merge base; nothing to compare"); return 0)
        old = measure(basetree, root, joinpath(dirname(basetree), "old.toml"))
        new = measure(root, root, joinpath(dirname(basetree), "new.toml"))
        regs = regressions(old, new, tol)
        for (k, r) in regs
            println("  REGRESSION $k: $(round(r; digits = 3))x the merge base")
        end
        println(isempty(regs) ? "bench.jl: OK ($(length(new)) benchmarks, tolerance $tol)" :
                "bench.jl: $(length(regs)) regressions beyond tolerance $tol")
        return isempty(regs) ? 0 : 1
    finally
        git(root, "worktree", "remove", "--force", basetree)
    end
end

end # module

abspath(PROGRAM_FILE) == @__FILE__() && exit(Bench.main(ARGS))
