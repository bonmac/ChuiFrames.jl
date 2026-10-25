# Stage kernels (phase-4 spec §3; ADR-0003 rule 12). `stage_kernel(ph, est_rows)` returns the
# callable every morsel of the streamed stage runs through: a compiled kernel, or the
# interpreter. Seam version: always the interpreter (the codegen lane fills this file).

"The interpreter over the streamed stage of `ph`: each step through its eager operator."
interpret_stage(ph) = f -> _interpret(ph.stage, f)
function _interpret(stage, f)
    for s in stage
        f = apply(s, f)
    end
    return f
end

"""
    stage_kernel(ph::Physical, est_rows::Union{Nothing, Int}) -> callable

The kernel for `ph`'s streamed stage, given the source's estimated row count (`nothing`: not
reported). Each morsel `f::Frame` runs as `kernel(f)` after the engine's scan predicates.
"""
stage_kernel(ph, ::Union{Nothing, Int}) = interpret_stage(ph)

"`explain`'s kernel line for `ph`'s streamed stage (seam version: prints nothing)."
_explain_kernel(io::IO, ph) = nothing
