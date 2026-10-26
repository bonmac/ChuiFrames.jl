# The rendered kernel (spec §7; ADR-0003 rule 13): the streamed stage as a Julia function
# expression over one partition's columns (a NamedTuple of vectors). `code_lowered(q)` lowers it
# with `Meta.lower`. It is rendered for reading; the engine runs the interpreter (phase 4 adds
# compiled kernels). A property test evaluates it in the test process and checks it against the
# interpreter.

# Nodes the renderer spells out; anything else is evaluated through the interpreter.
_rnode(x::Col) = :(cols.$(x.name))
_rnode(x::Lit) = x.scalar ? (x.value isa Symbol ? QuoteNode(x.value) : x.value) : _rinterp(x)
_rnode(x::Call) = Expr(:call, :broadcast, x.f, (_rnode(a) for a in x.args)...)
_rnode(x::Node) = _rinterp(x)
_rinterp(x::Node) = :($(GlobalRef(@__MODULE__, :_evalnode))($(QuoteNode(x)), cols))

"`_evalnode(x, cols)`: node `x` over the columns `cols` (a NamedTuple), one value per row."
_evalnode(x::Node, cols::NamedTuple) = (f = Frame(cols); eval_column(x, Env(f), nothing))

const _FIT = GlobalRef(@__MODULE__, :_fitrows)
"Recycle a scalar result to `n` rows (as `mutate` does)."
_fitrows(v::AbstractVector, n::Int) = v
_fitrows(v, n::Int) = fill(v, n)

# Each method appends the step's code to `body`; `probe` is an empty frame with the step's input
# names and types (for selector resolution).
function _rstep!(body, s::FilterStep, probe::Frame)
    ps = [_rnode(p) for p in s.preds]
    for (k, p) in enumerate(ps)
        push!(body, :($(Symbol(:p, k)) = $(_FIT)($p, n)))
    end
    mask = GlobalRef(@__MODULE__, s.out ? :_notalltrue : :_alltrue)
    push!(body, Expr(:(=), :keep, Expr(:call, mask, (Symbol(:p, k) for k in eachindex(ps))...)))
    push!(body, :(cols = $(GlobalRef(@__MODULE__, :_keeprows))(cols, keep)))
    push!(body, :(n = count(keep)))
    return body
end

"Rows where every condition is exactly `true` (a filter; `missing` and `false` drop the row)."
_alltrue(ps::AbstractVector...) = BitVector(all(p -> p[i] === true, ps) for i in eachindex(first(ps)))
"Rows where the conditions are not all `true` (a `filter_out`)."
_notalltrue(ps::AbstractVector...) = .!_alltrue(ps...)
"The rows `keep` of every column."
_keeprows(cols::NamedTuple, keep::BitVector) = map(v -> v[keep], cols)
"`cols` without column `nm` (`mutate(nm = nothing)`)."
function _dropcol(cols::NamedTuple, nm::Symbol)
    ks = Tuple(k for k in keys(cols) if k !== nm)
    return NamedTuple{ks}(Tuple(cols[k] for k in ks))
end
"The row count of a partition's columns."
_nrows(cols::NamedTuple) = isempty(cols) ? 0 : length(first(cols))
function _rstep!(body, s::MutateStep, probe::Frame)
    for o in s.outs
        nm = o.first
        if o.second === nothing
            push!(body, :(cols = $(GlobalRef(@__MODULE__, :_dropcol))(cols, $(QuoteNode(nm)))))
        else
            push!(body, :(cols = merge(cols, NamedTuple{($(QuoteNode(nm)),)}(($(_FIT)($(_rnode(o.second)), n),)))))
        end
    end
    return body
end
function _rstep!(body, s::SelectStep, probe::Frame)
    outs = Symbol[]
    vals = Any[]
    for it in s.items
        if it isa Pair
            push!(outs, it.first)
            push!(vals, :($(_FIT)($(_rnode(it.second)), n)))
        else
            for i in resolve(it, probe)
                nm = probe.names[i]
                nm in outs && continue
                push!(outs, nm)
                push!(vals, :(cols.$nm))
            end
        end
    end
    push!(body, :(cols = NamedTuple{$(Tuple(outs))}(($(vals...),))))
    return body
end
function _rstep!(body, s::Step, probe::Frame)       # rename, rename_with, relocate
    m = name_map(s, probe.names, _coltypes(probe))
    m === nothing && throw(ArgumentError("cannot render $(s)"))
    outs = Tuple(p.first for p in m)
    push!(body, :(cols = NamedTuple{$outs}(($((:(cols.$(p.second)) for p in m)...),))))
    return body
end

"""
    render_kernel(ph::Physical) -> Union{Nothing, Expr}

The streamed stage of `ph` as `cols -> (…; cols)`: the scan's predicates, then each step, over
a NamedTuple of column vectors. `nothing` when there is no stage, or when a step cannot be
rendered on the declared schema.
"""
function render_kernel(ph::Physical)
    scan = ph.scan
    steps = Step[]
    isempty(scan.preds) || push!(steps, FilterStep(scan.preds, false))
    append!(steps, ph.stage)
    isempty(steps) && return nothing
    sch = source_schema(scan.source)
    probe = apply_scan(empty_frame(sch), scan.select === nothing ? Tables.Scan() : Tables.Scan(; select = scan.select))
    body = Any[:(n = $(GlobalRef(@__MODULE__, :_nrows))(cols))]
    try
        for s in steps
            _rstep!(body, s, probe)
            probe = apply(s, probe)
        end
    catch
        return nothing
    end
    push!(body, :cols)
    return Expr(:->, :cols, Expr(:block, body...))
end

"The lowered code (`CodeInfo`) of a rendered kernel's body, `cols` bound to the partition."
function lower_kernel(ex::Expr)
    body = ex.args[2]
    th = Meta.lower(@__MODULE__, Expr(:let, Expr(:(=), :cols, :partition), body))
    return th isa Expr && th.head === :thunk ? th.args[1] : th
end

# TTFX workload for the compiled stage kernels (kernels.jl; here because it needs the physical
# plan of execute.jl): the kernel machinery (the decision, the builder, the probe check, the
# guarded run, the output assembly) is compiled into the package image, so the first compiled
# kernel of a session pays only for its own shape (docs/research/codegen-phase4.md). The session
# cache is emptied afterwards: its keys hold `objectid`s, which differ between sessions.
@setup_workload begin
    nt = (x = [1.5, -0.0, NaN, 2.0], y = [1, 2, 3, 4], s = ["a", "b", "a", "c"])
    @compile_workload begin
        f = Frame(nt)
        ph = physical(mutate(z = c.x .* 2.0 .+ c.y)(filter(c.y .> 1)(lazy(f))).plan)
        kernel_decision(ph, 0)
        CompiledStage(ph)(f)
        lock(() -> empty!(_KERNEL_CACHE), _KERNEL_LOCK)
    end
end
