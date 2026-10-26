# Seeded by the ecosystem factory. Run via `julia scripts/ci.jl jet` (stable Julia only, ADR-0006/0007).
using TOML
const NAME = Symbol(TOML.parsefile(joinpath(@__DIR__, "..", "..", "Project.toml"))["name"])
using JET
@eval using $NAME
const PKG = getfield(Main, NAME)
JET.test_package(PKG; target_modules = (PKG,))

# Optimization checks (`@test_opt` on concrete inputs), one file per owner: test/jet/opt_*.jl
# (phase-4 plan Task 0b; each lane adds its own file).
using Test
for f in sort!(filter(n -> startswith(n, "opt_") && endswith(n, ".jl"), readdir(@__DIR__)))
    include(joinpath(@__DIR__, f))
end
