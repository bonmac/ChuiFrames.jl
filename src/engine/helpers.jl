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

"""
    percent_rank(x)

`(min_rank(x) - 1) / (m - 1)`, where `m` counts the non-`missing`, non-NaN values (per group):
a number in `[0, 1]`; `missing`/NaN stay `missing`, and a single value gives `0/0 = NaN`
(dplyr 1.2.0). `percent_rank(desc(x))` ranks descending.
"""
percent_rank(x) = Window(:percent_rank, Node[_ordnode(x)], (), _NOKW)

"""
    cume_dist(x)

The proportion of values less than or equal to each value (ties take the largest rank, divided
by the number of non-`missing`, non-NaN values, per group); `missing`/NaN stay `missing`
(dplyr 1.2.0). `cume_dist(desc(x))` ranks descending.
"""
cume_dist(x) = Window(:cume_dist, Node[_ordnode(x)], (), _NOKW)

"""
    ntile(x, n)
    ntile(; n)

`n` roughly equal buckets `1:n` of `x`'s order, per group, as dplyr 1.2.0: ties are broken by
row order (`row_number(x)`), the first buckets get the extra rows, `missing`/NaN stay `missing`.
`ntile(; n)` buckets the rows in order (dplyr's `ntile(n = k)` with no `x`). `n` must be a
positive whole number (`ArgumentError` otherwise, as dplyr errors).
"""
ntile(x, n) = Window(:ntile, Node[_ordnode(x)], (_ntile_n(n),), _NOKW)
ntile(; n) = Window(:ntile, Node[], (_ntile_n(n),), _NOKW)
function _ntile_n(n)
    ok = n isa Integer || (n isa Real && isfinite(n) && isinteger(n))
    ok || throw(ArgumentError("ntile: n must be a whole number, got $(repr(n))"))
    n > 0 || throw(ArgumentError("ntile: n must be positive, got $(repr(n))"))
    return Int(n)
end

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

The element type comes from the values' and the default's types only, never from which branches
fire (as dplyr's common type): equal types stay, numbers promote (`Int` and `Float64` give
`Float64`, `Bool` and `Int` give `Int`), strings give `String`, and a `missing` default (the
default) makes the result nullable even where it never fires; naive timestamps of any units and
`DateTime` promote exactly (ADR-0021 rule 7). Values with no common type (a string and a
number, naive and zoned timestamps) are an `ArgumentError`, as dplyr's "Can't combine"; so is a
value the common type cannot hold exactly (a big `Int` as `Float64`, `-1` as `UInt`). Unlike
dplyr, a `Date` and a `DateTime` are not combined (dplyr gives `POSIXct`), nor are `Char` and
`String` or `Rational` and `Float64`.
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

"""
    WhenFold(isall, na_rm)

The elementwise function behind [`when_any`](@ref) / [`when_all`](@ref): Kleene OR / AND of its
arguments, which must be `Bool` or `missing`.
"""
struct WhenFold
    isall::Bool
    na_rm::Bool
end
function (w::WhenFold)(xs...)
    sawmissing = false
    for x in xs
        x isa Union{Bool, Missing} ||
            throw(ArgumentError("$(w.isall ? "when_all" : "when_any"): arguments must be Bool or missing, got a $(typeof(x)) value (dplyr also requires logical vectors)"))
        if ismissing(x)
            sawmissing = true
        elseif x !== w.isall
            return x
        end
    end
    return sawmissing && !w.na_rm ? missing : w.isall
end

"""
    when_any(xs...; na_rm = false)
    when_all(xs...; na_rm = false)

Elementwise OR / AND of logical column expressions, as dplyr 1.2.0's `when_any`/`when_all`:
Kleene logic (`true | missing` is `true`, `false | missing` is `missing`; `false & missing` is
`false`, `true & missing` is `missing`). With `na_rm = true`, `missing` values are dropped first,
so `when_any` treats them as `false` and `when_all` as `true` and the result is never `missing`.
Arguments must be `Bool` or `missing` (an `ArgumentError` otherwise); at least one is required
(dplyr returns `logical(0)`, which fits no non-empty frame). Constants broadcast, where dplyr
requires every argument to have the frame's size. On plain vectors, the result directly (equal
lengths required).
"""
when_any(xs...; na_rm::Bool = false) = _when(false, na_rm, xs)
when_all(xs...; na_rm::Bool = false) = _when(true, na_rm, xs)
function _when(isall::Bool, na_rm::Bool, xs::Tuple)
    name = isall ? "when_all" : "when_any"
    isempty(xs) && throw(ArgumentError("$name needs at least one condition"))
    w = WhenFold(isall, na_rm)
    if all(x -> x isa AbstractVector, xs)
        n = length(xs[1])
        all(x -> length(x) == n, xs) || throw(ArgumentError("$name: the vectors have lengths $(map(length, xs)); they must be equal"))
        return broadcast(w, xs...)
    end
    return Call(w, Node[node(x) for x in xs])
end
function Base.show(io::IO, x::Call{WhenFold})
    print(io, x.f.isall ? "when_all(" : "when_any(")
    join(io, x.args, ", ")
    x.f.na_rm && print(io, "; na_rm = true")
    return print(io, ")")
end

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

function _rank(kind::Symbol, v::AbstractVector, rev::Bool, params::Tuple = ())
    n = length(v)
    reg = [i for i in 1:n if !_istail(v[i])]
    sort!(reg; alg = MergeSort, lt = (i, j) -> _ltval(v[i], v[j], rev))
    m = length(reg)
    if kind === :percent_rank || kind === :cume_dist
        fout = Vector{Union{Missing, Float64}}(missing, n)
        if kind === :percent_rank       # (min rank - 1) / (m - 1), as dplyr
            r = 0
            for (k, i) in enumerate(reg)
                (k == 1 || _ltval(v[reg[k - 1]], v[i], rev)) && (r = k)
                fout[i] = (r - 1) / (m - 1)
            end
        else                            # max rank / m, as dplyr
            r = 0
            for k in m:-1:1
                i = reg[k]
                (k == m || _ltval(v[i], v[reg[k + 1]], rev)) && (r = k)
                fout[i] = r / m
            end
        end
        return m == n ? Vector{Float64}(fout) : fout
    end
    out = Vector{Union{Missing, Int}}(missing, n)
    r = 0
    d = 0
    for (k, i) in enumerate(reg)
        newval = k == 1 || _ltval(v[reg[k - 1]], v[i], rev)
        if kind === :row_number
            out[i] = k
        elseif kind === :ntile
            out[i] = _ntile_bin(k, m, params[1])
        elseif kind === :min_rank
            newval && (r = k)
            out[i] = r
        else
            newval && (d += 1)
            out[i] = d
        end
    end
    return m == n ? Vector{Int}(out) : out
end

# dplyr 1.2.0's `ntile` bucket of row number `x` among `len` ranked values: the first
# `len % n` buckets have `cld(len, n)` rows, the others `fld(len, n)`.
function _ntile_bin(x::Int, len::Int, n::Int)
    nlarger = len % n
    larger, smaller = cld(len, n), fld(len, n)
    thr = larger * nlarger
    return x <= thr ? fld(x + larger - 1, larger) : fld(x - thr + smaller - 1, smaller) + nlarger
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
