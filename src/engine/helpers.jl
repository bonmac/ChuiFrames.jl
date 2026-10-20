# Helpers (ADR-0002 rules 8-10): ordering, windows, ranks, conditionals and constants.

"""
    desc(x)

Descending order for `arrange`, the ranking functions and `slice_min`/`slice_max`. Reverses only
the non-NaN, non-`missing` values; NaN and `missing` stay last (ADR-0002 rule 13).
"""
desc(x::Node) = x isa Desc ? x.inner : Desc(x)
desc(s::Symbol) = Desc(Col(s))
desc(s::AbstractString) = Desc(Col(Symbol(s)))

"`n_rows()`: the number of rows of the table, or of the group (dplyr's `n()`)."
n_rows() = NRows()

"""
    row_number()
    row_number(x)

`row_number()` numbers the rows `1:n` (per group). `row_number(x)` ranks `x` with ties broken by
row order; `missing` and NaN rank as `missing` (dplyr). `row_number(desc(x))` ranks descending.
"""
row_number() = Window(:row_number, Node[], (), _NOKW)
row_number(x) = Window(:row_number, Node[_ordnode(x)], (), _NOKW)

"`min_rank(x)`: rank with ties given the smallest rank (`1 1 3`); `missing`/NaN stay `missing`."
min_rank(x) = Window(:min_rank, Node[_ordnode(x)], (), _NOKW)

"`dense_rank(x)`: rank with ties given the same rank and no gaps (`1 1 2`)."
dense_rank(x) = Window(:dense_rank, Node[_ordnode(x)], (), _NOKW)

_ordnode(x::Symbol) = Col(x)
_ordnode(x) = node(x)

"""
    lag(x, k = 1; default = missing)
    lead(x, k = 1; default = missing)

The value `k` rows before (after) each row, per group; `default` where there is none.
"""
lag(x::Node, k::Integer = 1; default = missing) = Window(:lag, Node[x], (Int(k),), ismissing(default) ? _NOKW : (default = default,))
lead(x::Node, k::Integer = 1; default = missing) = Window(:lead, Node[x], (Int(k),), ismissing(default) ? _NOKW : (default = default,))
lag(v::AbstractVector, k::Integer = 1; default = missing) = _shift(v, Int(k), default)
lead(v::AbstractVector, k::Integer = 1; default = missing) = _shift(v, -Int(k), default)

"`cummean(x)`: the running mean, per group (`1 1.5 2`); `missing` propagates."
cummean(x::Node) = Window(:cummean, Node[x], (), _NOKW)
cummean(v::AbstractVector) = _cummean(v)

"""
    consecutive_id(x...)

An id that starts at 1 and increases each time the value (or the tuple of values) changes from
the previous row, per group. Equality is ADR-0003 rule 8's key equality.
"""
consecutive_id(x::Node, xs::Node...) = Window(:consecutive_id, Node[x, xs...], (), _NOKW)

"""
    case_when(cond => value, ...; default = missing)

Elementwise: the value of the first condition that is `true`; a `missing` condition counts as
not true (ADR-0002 rule 10). Conditions and values are column expressions or constants.
"""
function case_when(pairs::Pair...; default = missing)
    isempty(pairs) && throw(ArgumentError("case_when needs at least one cond => value pair"))
    return CaseWhen(Node[node(p.first) for p in pairs], Node[node(p.second) for p in pairs], node(default))
end

"""
    between(x, lo, hi)

`lo <= x <= hi` elementwise (`missing` propagates). `between(c.x, 1, 3)` and
`between.(c.x, 1, 3)` build the same kind of node.
"""
between(x, lo, hi) = (lo <= x) & (x <= hi)
between(x::Node, lo, hi) = Call(between, Node[x, node(lo), node(hi)])

"`na_if(x, y)`: `missing` where `x` equals `y` (by `isequal`), else `x`; elementwise on nodes."
na_if(x, y) = isequal(x, y) ? missing : x
na_if(x::Node, y) = Call(na_if, Node[x, node(y)])

"""
    lit(x)

The constant `x` as a column expression. `mutate(flag = lit(true))` silences the bare-`Bool`
lint (ADR-0002 rule 17).
"""
lit(x) = Lit(x, true)

"""
    across(sel, fs...; names = nothing)

Apply each function in `fs` to every selected column, in `mutate`/`summarise`/`reframe`
(positional only). Each `f` receives a column **node** (`v -> round.(v)`, or `each(round)`); a
result that is not a node is an `ArgumentError`. Output names follow `names` (`"{col}"`,
`"{fn}"`), by default `"{col}"` for one function and `"{col}_{fn}"` for several. `fs` may be
`name => f` pairs or a NamedTuple of functions. Grouping columns are never selected.
"""
struct Across{S}
    sel::S
    fns::Vector{Pair{String, Any}}
    names::Union{Nothing, String}
end
function across(sel, fs...; names::Union{Nothing, AbstractString} = nothing)
    fns = Pair{String, Any}[]
    fs = length(fs) == 1 && fs[1] isa Union{Tuple, AbstractVector} ? Tuple(fs[1]) : fs
    for (i, f) in enumerate(fs)
        if f isa NamedTuple
            for (k, g) in pairs(f)
                push!(fns, string(k) => g)
            end
        elseif f isa Pair
            push!(fns, string(f.first) => f.second)
        else
            push!(fns, _fnlabel(f, i) => f)
        end
    end
    isempty(fns) && push!(fns, "1" => identity)
    return Across(sel, fns, names === nothing ? nothing : String(names))
end
_fnlabel(f, i) = (s = f isa Each ? _fnlabel(f.f, i) : f isa Function ? string(nameof(f)) : string(i); startswith(s, "#") ? string(i) : s)
Base.show(io::IO, a::Across) = print(io, "across(", _selrepr(a.sel), ", ", join([_fname(f) for (_, f) in a.fns], ", "), ")")

"`if_any(sel, pred)`: `pred(col)` over the selected columns, folded with `.|` (`false` if none)."
if_any(sel, pred) = IfAnyAll(sel, pred, false)
"`if_all(sel, pred)`: `pred(col)` over the selected columns, folded with `.&` (`true` if none)."
if_all(sel, pred) = IfAnyAll(sel, pred, true)

# ---------------------------------------------------------------------------------------------
# Vector kernels behind the window nodes.

function _shift(v::AbstractVector, k::Int, default)
    n = length(v)
    T = Union{eltype(v), typeof(default)}
    out = Vector{T}(undef, n)
    for i in 1:n
        j = i - k
        out[i] = 1 <= j <= n ? v[j] : default
    end
    return out
end

function _cummean(v::AbstractVector)
    out = Vector{Union{Missing, Float64}}(undef, length(v))
    s = 0.0
    for (i, x) in enumerate(v)
        s = s + x
        out[i] = s / i
    end
    return [x for x in out]
end

# Ordering class used by arrange and the ranks: NaN and missing are the "tail" (ADR-0002 rule 13).
@inline _istail(x) = ismissing(x) || (x isa AbstractFloat && isnan(x))
@inline _ordkey(x) = x isa AbstractFloat && iszero(x) ? zero(x) : x
# `lt(a, b)` on regular (non-tail) values, ascending or descending, with -0.0 == 0.0 tied.
@inline _ltval(a, b, rev::Bool) = rev ? isless(_ordkey(b), _ordkey(a)) : isless(_ordkey(a), _ordkey(b))

function _rank(kind::Symbol, v::AbstractVector, rev::Bool)
    n = length(v)
    reg = [i for i in 1:n if !_istail(v[i])]
    sort!(reg; alg = MergeSort, lt = (i, j) -> _ltval(v[i], v[j], rev))
    out = Vector{Union{Missing, Int}}(missing, n)
    r = 0
    d = 0
    for (k, i) in enumerate(reg)
        newval = k == 1 || _ltval(v[reg[k - 1]], v[i], rev)
        if kind === :row_number
            out[i] = k
        elseif kind === :min_rank
            newval && (r = k)
            out[i] = r
        else
            newval && (d += 1)
            out[i] = d
        end
    end
    return length(reg) == n ? Vector{Int}(out) : out
end

function _consecutive(cols::Vector)
    n = isempty(cols) ? 0 : length(cols[1])
    out = Vector{Int}(undef, n)
    id = 0
    for i in 1:n
        if i == 1 || any(col -> !isequal(_canon(col[i]), _canon(col[i - 1])), cols)
            id += 1
        end
        out[i] = id
    end
    return out
end
