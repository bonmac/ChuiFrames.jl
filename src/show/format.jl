# Cell and type formatting for tibble-style printing: numbers to significant digits, text
# truncation by display width, type labels (`type_sum`) and per-element cell text (`obj_sum`).

# ---------------------------------------------------------------------------------------------
# Display-width helpers. Widths are `textwidth` (wide East Asian characters count 2).

"`pad_right(s, w)`: `s` followed by spaces up to display width `w`."
pad_right(s::AbstractString, w::Integer) = string(s, " "^max(w - textwidth(s), 0))
"`pad_left(s, w)`: spaces then `s`, up to display width `w`."
pad_left(s::AbstractString, w::Integer) = string(" "^max(w - textwidth(s), 0), s)

"""
    truncate_text(s, w) -> String

`s` cut to display width `w`, ending in `…` when it was cut (pillar's truncation).
"""
function truncate_text(s::AbstractString, w::Integer)
    textwidth(s) <= w && return String(s)
    w <= 1 && return "…"
    out = IOBuffer()
    used = 0
    for ch in s
        cw = textwidth(ch)
        used + cw > w - 1 && break
        print(out, ch)
        used += cw
    end
    print(out, '…')
    return String(take!(out))
end

# ---------------------------------------------------------------------------------------------
# Numbers (pillar's defaults: 3 significant digits, decimal points aligned, scientific notation
# for a column whose fixed-point width would exceed 13 characters).
#
# R reference (tibble 3.3.0):
#   > tibble(x = c(1.5, 22.25, 333.125, -4), y = c(1e-10, 1, 1e10, NA), z = c(1e7, 2, 3, 4))
#         x      y        z
#     <dbl>  <dbl>    <dbl>
#   1   1.5  1e-10 10000000
#   2  22.2  1e+ 0        2
#   3 333.   1e+10        3
#   4  -4   NA            4
#   > tibble(x = c(NaN, Inf, -Inf, 0.001234, 123456.7))     # NaN / Inf / -Inf / 0.00123 / 123457.
# The integer part is never rounded away (123457.); a trailing `.` marks a non-integer whose
# fraction was rounded off. `missing` takes the place of R's `NA` in the integer part.

const SIGFIG = 3
const MAX_DEC_WIDTH = 13

# fixed-point parts (lhs, rhs) of one value; rhs is "" or starts with '.'
function _fixed_parts(x::Real)
    x isa Integer && return (string(x), "")
    isnan(x) && return ("NaN", "")
    isinf(x) && return (x > 0 ? "Inf" : "-Inf", "")
    neg = signbit(x) && !iszero(x)
    a = abs(Float64(x))
    a >= 1.0e15 && return (string(x), "")         # too wide for fixed notation: num_cells uses sci
    if isinteger(a)
        return (string(neg ? "-" : "", Int64(a)), "")
    end
    dec = a == 0 ? 0 : max(SIGFIG - 1 - floor(Int, log10(a)), 0)
    n = round(Int128, a * exp10(dec))
    s = string(n)
    if dec > 0
        s = lpad(s, dec + 1, '0')
        ip, fp = s[1:(end - dec)], rstrip(s[(end - dec + 1):end], '0')
    else
        ip, fp = s, ""
    end
    ip = string(neg && (n != 0) ? "-" : "", ip)
    return (ip, "." * fp)
end

# scientific parts (mantissa lhs, mantissa rhs, exponent)
function _sci_parts(x::Real)
    (x isa Integer || !isfinite(x) || iszero(x)) && return (_fixed_parts(x)..., nothing)
    r = round(Float64(x); sigdigits = SIGFIG)
    e = floor(Int, log10(abs(r)))
    n = round(Int, abs(r) / exp10(e) * exp10(SIGFIG - 1))
    if n >= 10^SIGFIG          # rounding carried into a new digit
        e += 1
        n = round(Int, n / 10)
    end
    s = string(n)
    ip, fp = s[1:1], rstrip(s[2:end], '0')
    return (string(signbit(r) ? "-" : "", ip), isempty(fp) ? "" : "." * fp, e)
end

"""
    num_cells(v::AbstractVector) -> Vector{String}

The printed cells of a numeric column (`missing` allowed), all of the same display width:
3 significant digits, decimal points aligned, scientific notation for wide-ranging columns.
"""
function num_cells(v::AbstractVector)
    isempty(v) && return String[]
    parts = [ismissing(x) ? ("missing", "") : _fixed_parts(x) for x in v]
    wl = maximum(p -> textwidth(p[1]), parts)
    wr = maximum(p -> textwidth(p[2]), parts)
    huge = any(x -> x isa AbstractFloat && isfinite(x) && abs(x) >= 1.0e15, v)
    if huge || (wl + wr > MAX_DEC_WIDTH && any(x -> !ismissing(x) && !(x isa Integer), v))
        return _sci_cells(v)
    end
    return [pad_left(l, wl) * pad_right(r, wr) for (l, r) in parts]
end

# `missing` does not widen the mantissa: it overhangs to the left, as R's `NA` under `1e-10`.
function _sci_cells(v)
    parts = [_sci_parts(x) for x in v if !ismissing(x)]
    wl = maximum(p -> textwidth(p[1]), parts)
    wr = maximum(p -> textwidth(p[2]), parts)
    exps = [p[3] for p in parts if p[3] !== nothing]
    we = isempty(exps) ? 0 : maximum(e -> ndigits(e), exps)
    cells = String[]
    k = 0
    for x in v
        if ismissing(x)
            push!(cells, "missing")
            continue
        end
        l, r, e = parts[k += 1]
        tail = e === nothing ? "" : string("e", e < 0 ? "-" : "+", lpad(string(abs(e)), we))
        push!(cells, string(pad_left(l, wl), pad_right(r, wr), pad_right(tail, isempty(exps) ? 0 : we + 2)))
    end
    w = maximum(textwidth, cells)
    return [pad_left(c, w) for c in cells]
end

# ---------------------------------------------------------------------------------------------
# Type labels (tibble's `type_sum`). Names follow Arrow/Polars dtype names (i64, f64, str, bool,
# binary, list[...], struct[n]), which are Julia-flavoured and short, inside tibble's `<…>`;
# `date` and `dttm` are tibble's. A trailing `?` marks a nullable column: in ChuiFrames
# nullability is part of the declared type (`Union{Missing,T}`, ADR-0001 rule 1), visible even
# when no value is missing.

const _ABBR = IdDict{Any, String}(
    Int8 => "i8", Int16 => "i16", Int32 => "i32", Int64 => "i64", Int128 => "i128",
    UInt8 => "u8", UInt16 => "u16", UInt32 => "u32", UInt64 => "u64", UInt128 => "u128",
    Float16 => "f16", Float32 => "f32", Float64 => "f64", Bool => "bool",
    String => "str", StrView => "str", ByteView => "binary", Date => "date", DateTime => "dttm",
    Missing => "missing", Any => "any",
)

"Short name of a Julia type, as used in type labels and list-cell summaries."
function _abbr(T::Type)
    T === Union{} && return "missing"
    S = nonmissingtype(T)
    q = (S !== T && S !== Union{}) ? "?" : ""
    s = get(_ABBR, S, nothing)
    s === nothing || return s * q
    S <: AbstractString && return "str" * q
    S <: ArrowTimestamp && isconcretetype(S) && return _ts_abbr(S) * q
    S isa DataType && return string(nameof(S)) * q
    return "obj" * q
end

# `dttm[us]`, `dttm[ns, UTC]`: the unit and the zone are part of the type (ADR-0021 rule 8).
const _TS_ABBR_UNIT = IdDict{Any, String}(Dates.Second => "s", Dates.Millisecond => "ms", Dates.Microsecond => "us", Dates.Nanosecond => "ns")
function _ts_abbr(::Type{T}) where {T <: ArrowTimestamp}
    tz = timestamp_zone(T)
    return string("dttm[", _TS_ABBR_UNIT[timestamp_unit(T)], tz === nothing ? "" : string(", ", tz), "]")
end

_tsum(c::AbstractColumn) = _abbr(eltype(c))
_tsum(c::BinaryColumn) = "binary"
_tsum(c::DictColumn) = string("dict[", _tsum(c.dict), "]")
_tsum(c::ListColumn) = string("list[", _tsum(c.child), isnullable(c.child) ? "?" : "", "]")
_tsum(c::StructColumn) = string("struct[", length(c.children), "]")
_tsum(::ObjectColumn{E, T}) where {E, T} = _abbr(T)
_tsum(::ObjectColumn{E, Missing}) where {E} = "missing"

"""
    type_sum(col::AbstractColumn) -> String

The label printed under a column's header: `<i64>`, `<f64?>`, `<str>`, `<list[i64]>`, …
(tibble's `type_sum`).
"""
function type_sum(c::AbstractColumn)
    base = _tsum(c)
    nullable = isnullable(c) && base != "missing" && !endswith(base, "?")
    return string("<", base, nullable ? "?" : "", ">")
end

# ---------------------------------------------------------------------------------------------
# Cell text (tibble's `obj_sum` for list cells). Strings print unquoted and escaped (so a cell
# stays on one line); arrays print as `<eltype [dims]>` like tibble's `<int [2]>`.

"""
    cell_text(x) -> String

The text of one non-missing cell.
"""
cell_text(x::AbstractString) = escape_string(x, "")
cell_text(x::Bool) = x ? "true" : "false"
cell_text(x::Union{Date, DateTime}) = string(x)
cell_text(x::ArrowTimestamp) = timestamp_string(x)
cell_text(x::Real) = sprint(show, x; context = :compact => true)
cell_text(x::Union{Signed, Unsigned}) = string(x)
cell_text(x::ByteView) = string("<", length(x), length(x) == 1 ? " byte>" : " bytes>")
cell_text(x::AbstractArray) = string("<", _abbr(eltype(x)), " [", join(size(x), "×"), "]>")
cell_text(x::Base.CodeUnits{UInt8}) = string("<", length(x), length(x) == 1 ? " byte>" : " bytes>")
cell_text(x) = sprint(show, x; context = (:compact => true, :limit => true))

"`header_text(name)`: a column name as printed in headers and footers (`var\"…\"` when not an identifier)."
function header_text(n::Symbol)
    s = String(n)
    Base.isidentifier(s) && return s
    return string("var\"", Base.escape_raw_string(s), "\"")
end
