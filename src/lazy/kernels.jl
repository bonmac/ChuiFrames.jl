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

The callable is shared by every task of a parallel run: it must be reentrant, allocating its
outputs per call (never buffers preallocated once per `stage_kernel` call). Its output column
types must equal the interpreter's on the same morsel, including an empty one (empty and pruned
morsels run through `interpret_stage`, in `_process_empty`).
"""
stage_kernel(ph, ::Union{Nothing, Int}) = interpret_stage(ph)

"""
`explain`'s kernel line for `ph`'s streamed stage, printed only when `kernel = true` (so the
default `explain` output does not depend on the session's kernel cache). Seam version: prints
nothing.
"""
_explain_kernel(io::IO, ph; kernel::Bool = false) = nothing
