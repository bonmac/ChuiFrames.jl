# patch_concat.jl: a what-if for the calibration scripts (nothing in src/ changes). It
# re-evaluates two src functions in the running process with their concatenation made linear,
# to measure what the quadratic `reduce(vcat, ...)` forms cost:
#   (1) src/engine/join_shapes.jl `_partitioned_join`: `reduce(vcat, pxs; init = Int[])` (the
#       `init` keyword disables Base's preallocating `reduce(vcat, ::Vector{<:AbstractVector})`,
#       so 2^p partitions are folded left to right) → `reduce(vcat, pxs)`;
#   (2) src/columns.jl `vcat_columns`: `reduce(vcat, (... for c in cols))` (a generator: a left
#       fold, one copy per morsel) → `reduce(vcat, [... for c in cols])`.
# Included by radix_switch.jl and broadcast_limits.jl when PATCH=1. docs/research/performance-phase4.md P4-02.
const CF_ROOT = normpath(joinpath(@__DIR__, "..", ".."))
function _extract(path, header)
    s = read(joinpath(CF_ROOT, path), String)
    i = findfirst(header, s)
    j = findnext("\nend\n", s, last(i))
    return s[first(i):(first(j) + 4)]
end
let f = _extract("src/engine/join_shapes.jl", "function _partitioned_join(")
    g = replace(f, "reduce(vcat, pxs; init = Int[])" => "reduce(vcat, pxs)", "reduce(vcat, pys; init = Int[])" => "reduce(vcat, pys)")
    @assert g != f
    Core.eval(ChuiFrames, Meta.parse(g))
end
let f = _extract("src/columns.jl", "function vcat_columns(cols::AbstractVector)")
    g = replace(
        f, "reduce(vcat, (something(validity(c), trues(length(c))) for c in cols))" => "reduce(vcat, [something(validity(c), trues(length(c))) for c in cols])",
        "reduce(vcat, (c.values for c in cols))" => "reduce(vcat, [c.values for c in cols])",
        "reduce(vcat, (c.codes for c in cols))" => "reduce(vcat, [c.codes for c in cols])",
    )
    @assert count("[", g) > count("[", f)
    Core.eval(ChuiFrames, Meta.parse(g))
end
println("patch_concat.jl: linear concatenation patched in (this process only)")
