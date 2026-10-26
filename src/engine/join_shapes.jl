# The hash join's physical shapes (phase-4 spec docs/superpowers/specs/2026-10-26-phase4-joins-groupby-codegen-design.md
# §1.2): the output assembly, `ProbeStep` (shapes a and b), `JoinTailStep`, `PartitionedJoinStep`
# (shape c) and the cross join. Included at the end of src/engine/join.jl (types, cost stage,
# key conversion, build table, sort and x-side pass). Join lane.

# ---------------------------------------------------------------------------------------------
# Output assembly

"`col` with a validity bitmap (a nullable column of the same kind and values)."
_asnullable(c::AbstractColumn) = validity(c) === nothing ? _withvalidity(c, trues(length(c))) : c
_withvalidity(c::PrimitiveColumn, v::BitVector) = PrimitiveColumn(c.values, v)
_withvalidity(c::BoolColumn, v::BitVector) = BoolColumn(c.values, v)
_withvalidity(c::StringColumn, v::BitVector) = StringColumn(c.offsets, c.data, v)
_withvalidity(c::BinaryColumn, v::BitVector) = BinaryColumn(c.offsets, c.data, v)
_withvalidity(c::DictColumn, v::BitVector) = DictColumn(c.codes, c.dict, v)
_withvalidity(c::ListColumn, v::BitVector) = ListColumn(c.offsets, c.child, v)
_withvalidity(c::StructColumn, v::BitVector) = StructColumn(c.children, v; length = length(c))
_withvalidity(c::ObjectColumn, v::BitVector) = ObjectColumn(c.values, v)

_ascolumn(v::AbstractColumn) = v
_ascolumn(v::AbstractVector) = column(v)

"""
The merged key column (keep = false): x's converted value, or y's for a row only in y. For
right/full joins (`merged`) the column is fed by both frames and always built from plain
values (a dictionary is decoded, spec §1.1), whatever the rows, so every shape gives one kind.
"""
function _keycolumn(xc::AbstractVector, yc::Union{Nothing, AbstractVector}, xr::Vector{Int}, yr::Vector{Int}, ynullable::Bool, merged::Bool)
    if !merged
        col = take(_ascolumn(xc), xr)
        return ynullable ? _asnullable(col) : col
    end
    E = yc === nothing ? eltype(xc) : Union{eltype(xc), eltype(yc)}
    v = Vector{ynullable ? Union{Missing, E} : E}(undef, length(xr))
    return column(_fillkeys!(v, xc, yc, xr, yr))
end
function _fillkeys!(v::Vector, xc::AbstractVector, ::Nothing, xr::Vector{Int}, yr::Vector{Int})
    @inbounds for i in eachindex(v)
        v[i] = xc[xr[i]]
    end
    return v
end
function _fillkeys!(v::Vector, xc::AbstractVector, yc::AbstractVector, xr::Vector{Int}, yr::Vector{Int})
    @inbounds for i in eachindex(v)
        v[i] = xr[i] > 0 ? xc[xr[i]] : yc[yr[i]]
    end
    return v
end

"""
    _assemble(s, names, X, xconv, Y, yconv, xr, yr) -> (names, columns)

The output columns of a keyed (or cross) join for the row pairs `(xr[i], yr[i])` (`0`: that
side is missing), in `names`' order. X's columns come from `X`, y's from `Y` (by y's names);
columns absent from `X`/`Y` (projected away) are skipped. Element types are static by kind
(spec §1.1).
"""
function _assemble(s::JoinStep, names::JoinNames, X::Frame, xconv::Vector{AbstractVector}, Y::Frame, yconv::Union{Nothing, Vector{AbstractVector}}, xr::Vector{Int}, yr::Vector{Int})
    xnull = s.kind === :right || s.kind === :full
    ynull = s.kind === :left || s.kind === :full
    xkeys = _xkeys(names)
    outn = Symbol[]
    cols = AbstractColumn[]
    for (j, nm) in enumerate(names.outnames)
        side, src = names.outside[j], names.outsrc[j]
        if side === :x
            hascolumn(X, src) || continue
            col = take(getcol(X, src), xr)
            xnull && (col = _asnullable(col))
        elseif side === :y
            hascolumn(Y, src) || continue
            col = take(getcol(Y, src), yr)
            ynull && (col = _asnullable(col))
        else  # :key
            p = findfirst(==(src), xkeys)::Int
            ynullable = Missing <: eltype(getcol(Y, names.pairs[p].second))
            col = _keycolumn(xconv[p], yconv === nothing ? nothing : yconv[p], xr, yr, ynullable, xnull)
        end
        push!(outn, nm)
        push!(cols, col)
    end
    return outn, cols
end

"The y frame of a nested element: y's non-key columns (keep = false) or all of them, ungrouped."
function _nest_source(s::JoinStep, names::JoinNames, Y::Frame)
    ykeys = _ykeys(names)
    ns = Symbol[n for n in names.ynames if (s.keep || !(n in ykeys)) && hascolumn(Y, n)]
    return Frame(ns, AbstractColumn[getcol(Y, n) for n in ns], Symbol[], nothing, Y.nrow)
end

"""
The output of a nest join: x's columns (the key converted under `keep = false`) and one column
of `Frame`s, one per x row, holding the `Y` rows `runs[i]` (y order).
"""
function _assemble_nest(s::JoinStep, names::JoinNames, X::Frame, xconv, Y::Frame, runs::Vector{Vector{Int}})
    ysub = _nest_source(s, names, Y)
    nested = ObjectColumn(Frame[take(ysub, r) for r in runs])
    xr = collect(1:X.nrow)
    xkeys = _xkeys(names)
    outn = Symbol[]
    cols = AbstractColumn[]
    for (j, nm) in enumerate(names.outnames)
        side, src = names.outside[j], names.outsrc[j]
        if side === :x
            hascolumn(X, src) || continue
            push!(cols, getcol(X, src))
        elseif side === :key
            p = findfirst(==(src), xkeys)::Int
            ynullable = Missing <: eltype(getcol(Y, names.pairs[p].second))
            push!(cols, _keycolumn(xconv[p], nothing, xr, xr, ynullable, false))
        elseif side === :nest
            push!(cols, nested)
        else
            continue
        end
        push!(outn, nm)
    end
    return outn, cols
end

"Group runs of pairs sorted by x row: `runs[i]` lists the handles paired with x row `i`."
function _runs(px::Vector{Int}, ph::Vector{Int}, nx::Int)
    runs = [Int[] for _ in 1:nx]
    @inbounds for (x, h) in zip(px, ph)
        push!(runs[x], h)
    end
    return runs
end

"""
x's grouping on the output (spec §1.1): a grouping column is kept when it keeps its name
(dplyr 1.2.0 reconstructs the groups by name, so one renamed by a suffix is dropped, checked
with Rscript); a nest_join column that replaced it keeps the grouping by the nested column.
"""
function _regroup_out(out::Frame, names::JoinNames, groups::Vector{Symbol}, drop::Bool)
    isempty(groups) && return out
    gs = Symbol[]
    for g in groups
        j = findfirst(i -> names.outnames[i] === g && (names.outside[i] === :nest || names.outsrc[i] === g), eachindex(names.outnames))
        j === nothing && continue
        hascolumn(out, g) && push!(gs, g)
    end
    isempty(gs) && return out
    return regroup(out, gs; drop)
end

_ungrouped(f::Frame) = isgrouped(f) ? Frame(copy(f.names), copy(f.columns), Symbol[], nothing, f.nrow) : f

"The kinds whose broadcast-build-y shape needs a tail (spec §1.2 shape a)."
_needs_ytail(s::JoinStep) = s.kind === :right || s.kind === :full ||
    (s.unmatched === :error && (s.kind === :inner || s.kind === :left || s.kind === :nest))

# ---------------------------------------------------------------------------------------------
# The physical steps

"""
    ProbeStep(side, build, spec, names, tail)

A streamable join probe (spec §1.2). `side = :y`: `build` is y's `JoinBuild` and the probe
streams x morsels (shape a); `side = :x`: `build` is x's `JoinBuild` and the probe streams y
morsels (shape b, always followed by a `JoinTailStep`). For a cross join `build` is the
collected y frame. `tail` says whether a `JoinTailStep` follows (shape a: the hidden y-row or
y-key column is emitted). In `explain`'s plan, `build` is the build side's plan.
"""
struct ProbeStep <: Step
    side::Symbol
    build::Any
    spec::JoinStep
    names::JoinNames
    tail::Bool
end

"""
    JoinTailStep(side, build, spec, names)

The pipeline breaker after a probe (spec §1.2): for `side = :y` (shape a) the y-side check and
the unmatched y rows of right/full joins; for `side = :x` (shape b) the order-restoring sort,
the x-side pass, `multiple`, the y-side check, the unmatched rows, and x's columns.
"""
struct JoinTailStep <: Step
    side::Symbol
    build::Any
    spec::JoinStep
    names::JoinNames
end

"""
    PartitionedJoinStep(right, spec, names, build, p, T, morsel, threads)

Shape (c) (spec §1.2): x arrives gathered; y is `right` (a collected frame, or y's plan,
collected when the step runs). Both sides' keys are hashed and radix-partitioned into `2^p`
partitions; each partition's table is built on `build` (`:x` or `:y`) and probed in ascending
order; the probes raise nothing, every check runs after the order-restoring sort.
"""
struct PartitionedJoinStep <: Step
    right::Any
    spec::JoinStep
    names::JoinNames
    build::Symbol
    p::Int
    T::Vector{Type}
    morsel::Int
    threads::Bool
end

_bystr(ps::Vector{Pair{Symbol, Symbol}}) = "[" * join([p.first === p.second ? repr(p.first) : "$(repr(p.first)) => $(repr(p.second))" for p in ps], ", ") * "]"
_bystr(n::JoinNames) = _bystr(n.pairs)
Base.show(io::IO, p::ProbeStep) = p.spec.kind === :cross ?
    print(io, "probe(cross; y collected, x streamed)") :
    print(io, "probe(", p.spec.kind, "; build ", p.side, ", stream ", p.side === :y ? :x : :y, ", by = ", _bystr(p.names), p.tail ? ", emits hidden columns" : "", ")")
Base.show(io::IO, t::JoinTailStep) = print(io, "join_tail(", t.spec.kind, "; build ", t.side, t.side === :x ? ", order-restoring sort" : "", ")")
Base.show(io::IO, s::PartitionedJoinStep) =
    print(io, "partitioned_join(", s.spec.kind, "; 2^", s.p, " partitions, build ", s.build, ", by = ", _bystr(s.names), ", order-restoring sort)")

function apply(p::ProbeStep, f::Frame)
    b = p.build
    b isa Frame && return _cross(p.spec, p.names, f, b)
    b isa JoinBuild || throw(ArgumentError("a join probe without a built side (explain's plan) cannot run"))
    return p.side === :y ? _probe_streams_x(p, b, f) : _probe_streams_y(p, b, f)
end

# Shape (a): x streams; the morsel's pairs are already in (x row, y row) order (no sort).
function _probe_streams_x(p::ProbeStep, b::JoinBuild, X::Frame)
    s, names = p.spec, p.names
    xkeys = _xkeys(names)
    nx = X.nrow
    xconv = _convkeys(X, xkeys, b.T)
    pk = _join_typed_keys(xconv, nx, xkeys)
    null = s.na_matches === :never ? _nullkeys(xconv, nx) : nothing
    if s.kind === :semi || s.kind === :anti
        ids = _probe_ids(b, pk, null)
        return take(X, s.kind === :semi ? findall(!=(0), ids) : findall(==(0), ids))
    end
    px, py = _probe_pairs(b, pk, null)
    if s.kind === :nest
        outn, cols = _assemble_nest(s, names, X, xconv, b.frame, _runs(px, py, nx))
        if p.tail
            ids = _probe_ids(b, pk, null)
            push!(outn, _YKEY)
            push!(cols, column(ids))
        end
        return _regroup_out(Frame(outn, cols, Symbol[], nothing, nx), names, X.groups, X.drop)
    end
    cx, cy = _xpass(px, py, nx, s)
    outn, cols = _assemble(s, names, X, xconv, b.frame, b.conv, cx, cy)
    if p.tail
        push!(outn, _YROW)
        push!(cols, column(cy))
    end
    return _regroup_out(Frame(outn, cols, Symbol[], nothing, length(cx)), names, X.groups, X.drop)
end

# Shape (b): y streams; each y row's x matches, in x order, plus the hidden columns.
function _probe_streams_y(p::ProbeStep, b::JoinBuild, Y::Frame)
    s, names = p.spec, p.names
    ykeys = _ykeys(names)
    ny = Y.nrow
    yconv = _convkeys(Y, ykeys, b.T)
    pk = _join_typed_keys(yconv, ny, ykeys)
    null = s.na_matches === :never ? _nullkeys(yconv, ny) : nothing
    if s.kind === :semi || s.kind === :anti
        ids = unique!(filter!(!=(0), _probe_ids(b, pk, null)))
        return Frame(Symbol[_XKEY], AbstractColumn[column(ids)])
    end
    py, px = _probe_pairs(b, pk, null)
    needall = s.kind === :right || s.kind === :full ||
        (s.unmatched === :error && (s.kind === :inner || s.kind === :left || s.kind === :nest))
    rows, xrow, ystart = _emit_rows(py, px, ny, needall)
    outn = Symbol[]
    cols = AbstractColumn[]
    for (n, c) in zip(Y.names, Y.columns)
        push!(outn, n)
        push!(cols, take(c, rows))
    end
    push!(outn, _XROW, _YSTART)
    push!(cols, column(xrow), column(ystart))
    return Frame(outn, cols, Symbol[], nothing, length(rows))
end
function _emit_rows(py::Vector{Int}, px::Vector{Int}, ny::Int, needall::Bool)
    rows = Int[]
    xrow = Int[]
    ystart = Bool[]
    m = length(py)
    j = 1
    @inbounds for i in 1:ny
        a = j
        while j <= m && py[j] == i
            push!(rows, i)
            push!(xrow, px[j])
            push!(ystart, j == a)
            j += 1
        end
        if j == a && needall
            push!(rows, i)
            push!(xrow, 0)
            push!(ystart, true)
        end
    end
    return rows, xrow, ystart
end

function apply(t::JoinTailStep, G::Frame)
    b = t.build::JoinBuild
    return t.side === :y ? _tail_build_y(t, b, G) : _tail_build_x(t, b, G)
end

function _drophidden(G::Frame)
    keep = findall(n -> !_ishidden(n), G.names)
    return Frame(G.names[keep], G.columns[keep], Symbol[g for g in G.groups if !_ishidden(g)], nothing, G.nrow, G.drop)
end

function _tail_build_y(t::JoinTailStep, b::JoinBuild, G::Frame)
    s, names = t.spec, t.names
    ny = b.frame.nrow
    if s.kind === :nest
        marked = falses(length(b.table))
        for id in getcol(G, _YKEY)
            id > 0 && (marked[id] = true)
        end
        for r in 1:ny
            id = b.ids[r]
            (id == 0 || !marked[id]) && throw(_y_unmatched_error(r))
        end
        return _regroup_like(_drophidden(G), G)
    end
    matched = falses(ny)
    for r in getcol(G, _YROW)
        r > 0 && (matched[r] = true)
    end
    if s.unmatched === :error && (s.kind === :inner || s.kind === :left)
        r = findfirst(!, matched)
        r === nothing || throw(_y_unmatched_error(r))
    end
    out = _drophidden(G)
    if s.kind === :right || s.kind === :full
        un = findall(!, matched)
        isempty(un) || (out = _append_yonly(s, names, out, b.frame, b.conv, un))
    end
    return _regroup_like(out, G)
end
_regroup_like(out::Frame, G::Frame) = isempty(out.groups) ? out : regroup(out, copy(out.groups); drop = G.drop)

# Append y's unmatched rows `un` (right/full; shape a): x columns missing, keys from y.
function _append_yonly(s::JoinStep, names::JoinNames, out::Frame, Y::Frame, yconv, un::Vector{Int})
    k = length(un)
    xkeys = _xkeys(names)
    cols = AbstractColumn[]
    for (nm, col) in zip(out.names, out.columns)
        j = findfirst(==(nm), names.outnames)::Int
        side, src = names.outside[j], names.outsrc[j]
        block = if side === :x
            take(col, zeros(Int, k))
        elseif side === :y
            c = take(getcol(Y, src), un)
            s.kind === :full ? _asnullable(c) : c
        else
            p = findfirst(==(src), xkeys)::Int
            column(yconv[p][un])
        end
        push!(cols, vcat_columns(AbstractColumn[col, block]))
    end
    return Frame(copy(out.names), cols, copy(out.groups), nothing, out.nrow + k, out.drop)
end

function _tail_build_x(t::JoinTailStep, b::JoinBuild, G::Frame)
    s, names = t.spec, t.names
    X = b.frame
    nx = X.nrow
    if s.kind === :semi || s.kind === :anti
        marked = falses(length(b.table))
        for id in getcol(G, _XKEY)
            marked[id] = true
        end
        semi = s.kind === :semi
        rows = Int[r for r in 1:nx if (b.ids[r] != 0 && marked[b.ids[r]]) == semi]
        return take(X, rows)
    end
    xrow = collect(Int, getcol(G, _XROW))
    ystart = collect(Bool, getcol(G, _YSTART))
    yord = cumsum(Int.(ystart))
    ny = isempty(yord) ? 0 : yord[end]
    yfirst = findall(ystart)
    gs = findall(>(0), xrow)
    perm = _sort_by_x(xrow[gs], nx)
    ph = gs[perm]
    px = xrow[ph]
    Y = _drophidden(G)
    return _finish(s, names, X, b.conv, b.T, Y, px, ph, yord, yfirst, ny)
end

"""
    _finish(s, names, X, xconv, T, Y, px, ph, ynum, yfirst, ny)

Steps 3–8 of shape (b) (spec §1.2), shared by shape (c): the pairs `(px, ph)` are sorted by x
row (`ph`: rows of `Y`, the frame holding y's values); `ynum[h]` is the y row number of handle
`h` and `yfirst[n]` the handle of y row `n` (`ny` rows; every y row has one when the kind needs
y's unmatched rows).
"""
function _finish(s::JoinStep, names::JoinNames, X::Frame, xconv, T::Vector{Type}, Y::Frame, px::Vector{Int}, ph::Vector{Int}, ynum::AbstractVector{Int}, yfirst::AbstractVector{Int}, ny::Int)
    nx = X.nrow
    if s.kind === :semi || s.kind === :anti
        has = falses(nx)
        for x in px
            has[x] = true
        end
        return take(X, s.kind === :semi ? findall(has) : findall(!, has))
    end
    if s.kind === :nest
        if s.unmatched === :error
            matched = falses(ny)
            for h in ph
                matched[ynum[h]] = true
            end
            r = findfirst(!, matched)
            r === nothing || throw(_y_unmatched_error(r))
        end
        outn, cols = _assemble_nest(s, names, X, xconv, Y, _runs(px, ph, nx))
        return _regroup_out(Frame(outn, cols, Symbol[], nothing, nx), names, X.groups, X.drop)
    end
    cx, ch = _xpass(px, ph, nx, s)
    yside = s.unmatched === :error && (s.kind === :inner || s.kind === :left)
    appendy = s.kind === :right || s.kind === :full
    if yside || appendy
        matched = falses(ny)
        for h in ch
            h > 0 && (matched[ynum[h]] = true)
        end
        if yside
            r = findfirst(!, matched)
            r === nothing || throw(_y_unmatched_error(r))
        end
        if appendy
            for n in 1:ny
                matched[n] || (push!(cx, 0); push!(ch, yfirst[n]))
            end
        end
    end
    yconv = appendy ? _convkeys(Y, _ykeys(names), T) : nothing
    outn, cols = _assemble(s, names, X, xconv, Y, yconv, cx, ch)
    return _regroup_out(Frame(outn, cols, Symbol[], nothing, length(cx)), names, X.groups, X.drop)
end

function apply(s::PartitionedJoinStep, X::Frame)
    Y = s.right isa Frame ? s.right : _run_subplan(s.right; morsel = s.morsel, threads = s.threads)
    return _partitioned_join(s.spec, s.names, X, _ungrouped(Y), s.T, s.build, s.p, s.threads)
end

# Shape (c): both sides radix-partitioned by the high hash bits; one task per contiguous range
# of partitions; per partition the build side's rows (ascending) fill a table and the other
# side's rows probe it (ascending). Then the order-restoring sort and the shared finish.
function _partitioned_join(s::JoinStep, names::JoinNames, X::Frame, Y::Frame, T::Vector{Type}, build::Symbol, p::Int, threads::Bool)
    nx, ny = X.nrow, Y.nrow
    xkeys, ykeys = _xkeys(names), _ykeys(names)
    xconv = _convkeys(X, xkeys, T)
    yconv = _convkeys(Y, ykeys, T)
    xk = _join_typed_keys(xconv, nx, xkeys)
    yk = _join_typed_keys(yconv, ny, ykeys)
    never = s.na_matches === :never
    xnull = never ? _nullkeys(xconv, nx) : nothing
    ynull = never ? _nullkeys(yconv, ny) : nothing
    xh = keyhashes(xk)
    yh = keyhashes(yk)
    np = 1 << p
    nt = (threads && Threads.nthreads() > 1 && nx + ny >= 65_536) ? min(Threads.nthreads(), np) : 1
    xoff, xperm = radix_partition(xh, p; ntasks = nt)
    yoff, yperm = radix_partition(yh, p; ntasks = nt)
    pxs = [Int[] for _ in 1:np]
    pys = [Int[] for _ in 1:np]
    ranges = [(div((k - 1) * np, nt) + 1):div(k * np, nt) for k in 1:nt]
    work(r) = for j in r
        xs = view(xperm, xoff[j]:(xoff[j + 1] - 1))
        ys = view(yperm, yoff[j]:(yoff[j + 1] - 1))
        if build === :y
            _partition_pairs!(pxs[j], pys[j], yk, yh, ys, ynull, xk, xh, xs, xnull, false)
        else
            _partition_pairs!(pxs[j], pys[j], xk, xh, xs, xnull, yk, yh, ys, ynull, true)
        end
    end
    if nt == 1
        work(1:np)
    else
        tasks = [Threads.@spawn(work(r)) for r in ranges]
        foreach(wait, tasks)
    end
    px = reduce(vcat, pxs; init = Int[])
    py = reduce(vcat, pys; init = Int[])
    perm = _sort_by_x(px, nx)
    px, py = px[perm], py[perm]
    r = 1:ny
    return _finish(s, names, X, xconv, T, Y, px, py, r, r, ny)
end

# One partition: build on `bk[brows]`, probe with `qk[qrows]` (both ascending). Pairs go out as
# (x row, y row); `buildx` says which side was built.
function _partition_pairs!(
        px::Vector{Int}, py::Vector{Int}, bk::AbstractVector{K}, bh::Vector{UInt64}, brows::AbstractVector{Int}, bnull,
        qk::AbstractVector, qh::Vector{UInt64}, qrows::AbstractVector{Int}, qnull, buildx::Bool,
    ) where {K}
    (isempty(brows) || isempty(qrows)) && return px
    t = KeyTable{K}(length(brows))
    first = Int[]
    last = Int[]
    next = zeros(Int, length(brows))
    @inbounds for (q, r) in enumerate(brows)
        bnull !== nothing && bnull[r] && continue
        id = getorinsert!(t, bk[r], bh[r])
        if id > length(first)
            push!(first, q)
            push!(last, q)
        else
            next[last[id]] = q
            last[id] = q
        end
    end
    @inbounds for r in qrows
        qnull !== nothing && qnull[r] && continue
        id = lookup(t, qk[r], qh[r])
        id == 0 && continue
        q = first[id]
        while q != 0
            if buildx
                push!(px, brows[q])
                push!(py, r)
            else
                push!(px, r)
                push!(py, brows[q])
            end
            q = next[q]
        end
    end
    return px
end

# The cross join: |x| × |y| rows, x order, each x row's block in y order (spec §1.5).
function _cross(s::JoinStep, names::JoinNames, X::Frame, Y::Frame)
    nx, ny = X.nrow, Y.nrow
    xr = Int[i for i in 1:nx for _ in 1:ny]
    yr = Int[j for _ in 1:nx for j in 1:ny]
    outn, cols = _assemble(s, names, X, AbstractVector[], Y, nothing, xr, yr)      # no keys
    return _regroup_out(Frame(outn, cols, Symbol[], nothing, nx * ny), names, X.groups, X.drop)
end
