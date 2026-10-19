# Seeded by the ecosystem factory. Run via `julia scripts/ci.jl jet` (stable Julia only, ADR-0006/0007).
using TOML
const NAME = Symbol(TOML.parsefile(joinpath(@__DIR__, "..", "..", "Project.toml"))["name"])
using JET
@eval using $NAME
const PKG = getfield(Main, NAME)
JET.test_package(PKG; target_modules = (PKG,))
