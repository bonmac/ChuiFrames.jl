# The lazy engine (phase 3; spec docs/superpowers/specs/2026-10-20-phase3-lazy-design.md):
# plans, the optimizer, pushdown and pruning, the morsel executor, `explain`/`code_lowered`
# (ADR-0003, ADR-0004).

include("predicates.jl")
include("plan.jl")
include("optimizer.jl")
include("execute.jl")
include("collect.jl")
include("render.jl")
include("explain.jl")

export LazyFrame, lazy, explain, optimize
