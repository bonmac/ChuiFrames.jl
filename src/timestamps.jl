# ArrowTimestamp: Arrow Timestamp values that `DateTime` cannot hold exactly (ADR-0021).
#
# A value is a raw Int64 count of `U` units since the Unix epoch, plus an optional time zone
# `TZ` (a Symbol). Naive values (`TZ === nothing`) are wall-clock times; zoned values are UTC
# instants and the zone only says how to display them (the Arrow spec, Schema.fbs). Equality,
# hashing and order are by the exact instant, across units (ADR-0021 rules 3-5).

const _TS_UNITS = (Dates.Second, Dates.Millisecond, Dates.Microsecond, Dates.Nanosecond)

"""
    ArrowTimestamp{U,TZ}(value::Integer)
    ArrowTimestamp{U}(value::Integer)          # naive: TZ = nothing

An Arrow `Timestamp` value: `value` units `U` (`Dates.Second`, `Dates.Millisecond`,
`Dates.Microsecond` or `Dates.Nanosecond`) since 1970-01-01T00:00:00, with time zone `TZ`
(`nothing` for a naive, wall-clock timestamp, else a `Symbol` such as `:UTC`,
`Symbol("Europe/Berlin")` or `Symbol("+01:00")`; ADR-0021).

ChuiFrames reads Arrow Timestamp(ms) without a zone as `DateTime` (ADR-0001 rule 6). Every
other Timestamp (seconds, microseconds, nanoseconds, or any unit with a zone) is read as an
`ArrowTimestamp`, so no digit is lost and the unit and zone survive a round trip.

- **Zones.** A zoned value is a UTC instant; the zone is display metadata (Arrow's rule).
  Values with different zones compare by instant. ChuiFrames has no time-zone database, so it
  shows zoned values in UTC (with a `Z`), never in local time. Each zone string is its own
  type: `Symbol("+01:00")` and `Symbol("Etc/GMT-1")` are different types (their values still
  compare by instant).
- **Equality and order** are by the exact instant, across units:
  `ArrowTimestamp{Millisecond}(1) == ArrowTimestamp{Nanosecond}(1_000_000)`. A naive value also
  equals the `DateTime` of the same wall-clock time. Comparing (`==`, `<`, `isless`) a naive
  value with a zoned one is an `ArgumentError`, as in pyarrow and Polars; `isequal` is `false`
  for them, so `Dict`s and `Set`s stay total.
- **Conversion.** `DateTime(t)` floors sub-millisecond digits (toward earlier times; zoned
  values give the UTC time). `ArrowTimestamp{U,TZ}(dt::DateTime)`, unit changes and `convert`
  are exact or throw an `InexactError`; a zoned target reads `dt` as UTC.
- **Arithmetic.** `t ± p` for a fixed period (`Week` down to `Nanosecond`) keeps `t`'s type and
  must be exact (`+ Microsecond(1)` on a millisecond value throws; pyarrow and Polars would widen
  the unit). `t1 - t2` is a period of the finer unit.
- `Dates.value(t)` is the raw count. `ChuiFrames.timestamp_unit(t)` and
  `ChuiFrames.timestamp_zone(t)` give `U` and `TZ`.
"""
struct ArrowTimestamp{U, TZ}
    value::Int64
    function ArrowTimestamp{U, TZ}(value::Int64) where {U, TZ}
        U in _TS_UNITS || throw(ArgumentError("ArrowTimestamp unit must be one of Second, Millisecond, Microsecond, Nanosecond; got $U"))
        TZ === nothing || TZ isa Symbol || throw(ArgumentError("ArrowTimestamp zone must be nothing or a Symbol; got $(repr(TZ))"))
        TZ === Symbol("") && throw(ArgumentError("ArrowTimestamp zone must not be empty; use nothing for a naive timestamp"))
        return new{U, TZ}(value)
    end
end
ArrowTimestamp{U, TZ}(value::Integer) where {U, TZ} = ArrowTimestamp{U, TZ}(Int64(value))
ArrowTimestamp{U}(value::Integer) where {U} = ArrowTimestamp{U, nothing}(Int64(value))

timestamp_unit(::Type{<:ArrowTimestamp{U}}) where {U} = U
timestamp_unit(t::ArrowTimestamp) = timestamp_unit(typeof(t))
timestamp_zone(::Type{ArrowTimestamp{U, TZ}}) where {U, TZ} = TZ
timestamp_zone(t::ArrowTimestamp) = timestamp_zone(typeof(t))
_iszoned(t::ArrowTimestamp) = timestamp_zone(t) !== nothing
_iszoned(::DateTime) = false

Dates.value(t::ArrowTimestamp) = getfield(t, :value)
Base.broadcastable(t::ArrowTimestamp) = Ref(t)   # a scalar in `c.t .> t`, like DateTime

# Nanoseconds per unit, and the exact instant as an Int128 count of nanoseconds.
_ns_per(::Type{Dates.Second}) = Int128(1_000_000_000)
_ns_per(::Type{Dates.Millisecond}) = Int128(1_000_000)
_ns_per(::Type{Dates.Microsecond}) = Int128(1_000)
_ns_per(::Type{Dates.Nanosecond}) = Int128(1)
_instant_ns(t::ArrowTimestamp) = Int128(Dates.value(t)) * _ns_per(timestamp_unit(t))

const _UNIX_EPOCH_MS = Dates.value(DateTime(1970))   # DateTime instant (ms since 0000-12-31) of the Unix epoch
const _DT_MIN_MS = Dates.value(typemin(DateTime))
const _DT_MAX_MS = Dates.value(typemax(DateTime))
_instant_ns(dt::DateTime) = (Int128(Dates.value(dt)) - _UNIX_EPOCH_MS) * 1_000_000

nullvalue(::Type{T}) where {T <: ArrowTimestamp} = T(0)

# Fits `ns` (an Int128 count of nanoseconds) in unit `U` exactly? Returns the Int64 count or nothing.
function _exact_count(ns::Int128, ::Type{U}) where {U}
    q, r = fldmod(ns, _ns_per(U))
    return (r == 0 && typemin(Int64) <= q <= typemax(Int64)) ? Int64(q) : nothing
end

# ---------------------------------------------------------------------------------------------
# Equality, hashing, order (ADR-0021 rules 3-5).

function _cmpzone(a, b, op)
    _iszoned(a) == _iszoned(b) && return nothing
    naive, zoned = _iszoned(a) ? (b, a) : (a, b)
    throw(ArgumentError("cannot $op a naive timestamp ($(typeof(naive))) and a zoned one ($(typeof(zoned))) (ADR-0021 rule 5); give both the same kind first"))
end

const _TSOrDT = Union{ArrowTimestamp, DateTime}
Base.:(==)(a::ArrowTimestamp, b::ArrowTimestamp) = (_cmpzone(a, b, "compare"); _instant_ns(a) == _instant_ns(b))
Base.:(==)(a::ArrowTimestamp, b::DateTime) = (_cmpzone(a, b, "compare"); _instant_ns(a) == _instant_ns(b))
Base.:(==)(a::DateTime, b::ArrowTimestamp) = b == a
# isequal is total (Dicts, Sets, grouping): a naive and a zoned value are simply not equal.
Base.isequal(a::ArrowTimestamp, b::_TSOrDT) = _iszoned(a) == _iszoned(b) && _instant_ns(a) == _instant_ns(b)
Base.isequal(a::DateTime, b::ArrowTimestamp) = isequal(b, a)

Base.isless(a::ArrowTimestamp, b::_TSOrDT) = (_cmpzone(a, b, "order"); _instant_ns(a) < _instant_ns(b))
Base.isless(a::DateTime, b::ArrowTimestamp) = (_cmpzone(a, b, "order"); _instant_ns(a) < _instant_ns(b))
Base.:(<)(a::ArrowTimestamp, b::_TSOrDT) = isless(a, b)
Base.:(<)(a::DateTime, b::ArrowTimestamp) = isless(a, b)
Base.:(<=)(a::ArrowTimestamp, b::_TSOrDT) = !isless(b, a)
Base.:(<=)(a::DateTime, b::ArrowTimestamp) = !isless(b, a)

# `hash` agrees with `isequal`: a naive value whose instant is a whole number of milliseconds
# in DateTime's range hashes as that DateTime; any other value hashes its exact instant, with a
# salt that keeps naive and zoned values apart.
const _TS_SALT_NAIVE = 0x6e1a9b7f3c2d5e81 % UInt
const _TS_SALT_ZONED = 0x2b8f4d6a1e3c7095 % UInt
function Base.hash(t::ArrowTimestamp, h::UInt)
    ns = _instant_ns(t)
    _iszoned(t) && return hash(ns, h ⊻ _TS_SALT_ZONED)
    ms, r = fldmod(ns, 1_000_000)
    if r == 0
        inst = ms + _UNIX_EPOCH_MS
        _DT_MIN_MS <= inst <= _DT_MAX_MS && return hash(DateTime(Dates.UTM(Int64(inst))), h)
    end
    return hash(ns, h ⊻ _TS_SALT_NAIVE)
end

# ---------------------------------------------------------------------------------------------
# Conversion (ADR-0021 rule 6).

"""
    DateTime(t::ArrowTimestamp)

The `DateTime` of `t`, flooring digits finer than a millisecond (toward earlier times). A zoned
value gives its UTC time. Throws an `InexactError` outside `DateTime`'s range.
"""
function Dates.DateTime(t::ArrowTimestamp)
    ms = fld(_instant_ns(t), 1_000_000) + _UNIX_EPOCH_MS
    _DT_MIN_MS <= ms <= _DT_MAX_MS || throw(InexactError(:DateTime, DateTime, Dates.value(t)))
    return DateTime(Dates.UTM(Int64(ms)))
end
Dates.Date(t::ArrowTimestamp) = Dates.Date(DateTime(t))

function ArrowTimestamp{U, TZ}(dt::DateTime) where {U, TZ}
    q = _exact_count(_instant_ns(dt), U)
    q === nothing && throw(InexactError(:ArrowTimestamp, ArrowTimestamp{U, TZ}, dt))
    return ArrowTimestamp{U, TZ}(q)
end
ArrowTimestamp{U}(dt::DateTime) where {U} = ArrowTimestamp{U, nothing}(dt)

"Exact conversion between units (same zone); `InexactError` if digits would be lost or the value overflows."
function ArrowTimestamp{U, TZ}(t::ArrowTimestamp) where {U, TZ}
    (timestamp_zone(t) === TZ) || throw(ArgumentError("ArrowTimestamp: converting between zones ($(repr(timestamp_zone(t))) to $(repr(TZ))) is not supported; the zone is display metadata, rebuild the value with ArrowTimestamp{U,TZ}(Dates.value(t))"))
    q = _exact_count(_instant_ns(t), U)
    q === nothing && throw(InexactError(:ArrowTimestamp, ArrowTimestamp{U, TZ}, Dates.value(t)))
    return ArrowTimestamp{U, TZ}(q)
end
ArrowTimestamp{U}(t::ArrowTimestamp) where {U} = ArrowTimestamp{U, timestamp_zone(t)}(t)

# `convert` only to a fully specified type (an abstract target would pick a zone by accident).
Base.convert(::Type{ArrowTimestamp{U, TZ}}, t::ArrowTimestamp) where {U, TZ} = t isa ArrowTimestamp{U, TZ} ? t : ArrowTimestamp{U, TZ}(t)
Base.convert(::Type{ArrowTimestamp{U, TZ}}, dt::DateTime) where {U, TZ} = ArrowTimestamp{U, TZ}(dt)

# Promotion (ADR-0021 rule 7): naive with naive (and DateTime), or the same zone, go to the finer
# unit; the conversion itself is exact or throws.
_finer(::Type{A}, ::Type{B}) where {A, B} = _ns_per(A) <= _ns_per(B) ? A : B
Base.promote_rule(::Type{ArrowTimestamp{A, TZ}}, ::Type{ArrowTimestamp{B, TZ}}) where {A, B, TZ} = ArrowTimestamp{_finer(A, B), TZ}
Base.promote_rule(::Type{ArrowTimestamp{A, nothing}}, ::Type{DateTime}) where {A} = ArrowTimestamp{_finer(A, Dates.Millisecond), nothing}

# Arithmetic (ADR-0021 rule 7): exact or throws. Period lengths from a table, in Int128, so
# long periods never overflow an intermediate Nanosecond.
const _FixedPeriod = Union{Dates.Week, Dates.Day, Dates.Hour, Dates.Minute, Dates.Second, Dates.Millisecond, Dates.Microsecond, Dates.Nanosecond}
const _PERIOD_NS = IdDict{Any, Int128}(
    Dates.Week => Int128(604_800_000_000_000), Dates.Day => Int128(86_400_000_000_000),
    Dates.Hour => Int128(3_600_000_000_000), Dates.Minute => Int128(60_000_000_000),
    Dates.Second => Int128(1_000_000_000), Dates.Millisecond => Int128(1_000_000),
    Dates.Microsecond => Int128(1_000), Dates.Nanosecond => Int128(1),
)
_period_ns(p::_FixedPeriod) = Int128(Dates.value(p)) * _PERIOD_NS[typeof(p)]
function _ts_shift(t::ArrowTimestamp, dns::Int128)
    q = _exact_count(_instant_ns(t) + dns, timestamp_unit(t))
    q === nothing && throw(InexactError(:+, typeof(t), dns))
    return typeof(t)(q)
end
Base.:(+)(t::ArrowTimestamp, p::_FixedPeriod) = _ts_shift(t, _period_ns(p))
Base.:(+)(p::_FixedPeriod, t::ArrowTimestamp) = t + p
Base.:(-)(t::ArrowTimestamp, p::_FixedPeriod) = _ts_shift(t, -_period_ns(p))
_calendar_err(p) = throw(ArgumentError("$(typeof(p)) is a calendar period, which ArrowTimestamp does not add (ADR-0021 rule 7); convert first: DateTime(t) + $(p)"))
Base.:(+)(::ArrowTimestamp, p::Union{Dates.Month, Dates.Quarter, Dates.Year}) = _calendar_err(p)
Base.:(-)(::ArrowTimestamp, p::Union{Dates.Month, Dates.Quarter, Dates.Year}) = _calendar_err(p)
function _ts_diff(a, b, U)
    _cmpzone(a, b, "subtract")
    d = div(_instant_ns(a) - _instant_ns(b), _ns_per(U))
    typemin(Int64) <= d <= typemax(Int64) || throw(OverflowError("timestamp difference overflows $(U)"))
    return U(Int64(d))
end
Base.:(-)(a::ArrowTimestamp, b::ArrowTimestamp) = _ts_diff(a, b, _finer(timestamp_unit(a), timestamp_unit(b)))
Base.:(-)(a::ArrowTimestamp, b::DateTime) = _ts_diff(a, b, _finer(timestamp_unit(a), Dates.Millisecond))
Base.:(-)(a::DateTime, b::ArrowTimestamp) = _ts_diff(a, b, _finer(timestamp_unit(b), Dates.Millisecond))

# Calendar fields (on the floored DateTime; zoned values in UTC) and the sub-millisecond digits.
for f in (:year, :month, :day, :hour, :minute, :second, :millisecond, :dayofweek, :dayofyear, :quarter, :week)
    @eval Dates.$f(t::ArrowTimestamp) = Dates.$f(DateTime(t))
end
Dates.microsecond(t::ArrowTimestamp) = Int(fld(mod(_instant_ns(t), 1_000_000), 1_000))
Dates.nanosecond(t::ArrowTimestamp) = Int(mod(_instant_ns(t), 1_000))

# ---------------------------------------------------------------------------------------------
# Ingest (ADR-0001 rule 12, ADR-0021 rule 7): a vector of one ArrowTimestamp type is a primitive
# column; a union of timestamp types (and DateTime) promotes exactly, or raises.

function _column(::Type{T}, v, nullable) where {T <: ArrowTimestamp}
    isconcretetype(T) || return _column_other(T, v, nullable)
    vals = Vector{T}(undef, length(v))
    z = nullvalue(T)
    @inbounds for (i, x) in enumerate(v)
        vals[i] = ismissing(x) ? z : x
    end
    return PrimitiveColumn(vals, _validity_of(v, nullable))
end

# An abstract timestamp element type (`ArrowTimestamp{Microsecond}` is `ArrowTimestamp{Microsecond,TZ}
# where TZ`) is narrowed to the union of the values' concrete types, so `ArrowTimestamp{U}[...]`
# gives a primitive column (or rule 7's error), never an object column (critic, ADR-0021).
function _timestamp_target(::Type{T}, v) where {T}
    (T !== Union{} && T <: _TSOrDT) || return nothing
    (T isa Union && all(isconcretetype, _uniontypes(T))) && return _timestamp_promotion(T)
    ts = unique!(Any[typeof(x) for x in v if !ismissing(x)])
    isempty(ts) && return nothing
    return length(ts) == 1 ? ts[1] : _timestamp_promotion(Union{ts...})
end

"""
The exact common timestamp type of a union of concrete timestamp types and `DateTime`, or
`nothing` when `T` is not such a union. Mixing naive and zoned values, or different zones, is
an `ArgumentError` (ADR-0021 rule 7), never an object column.
"""
function _timestamp_promotion(::Type{T}) where {T}
    T isa Union && T <: _TSOrDT || return nothing
    ts = _uniontypes(T)
    all(isconcretetype, ts) || return nothing
    zones = unique([t === DateTime ? nothing : timestamp_zone(t) for t in ts])
    length(zones) == 1 || throw(
        ArgumentError(
            "cannot combine timestamps of different kinds ($(join(string.(ts), ", "))): naive and zoned values, " *
                "or different zones, do not mix (ADR-0021 rule 7); rebuild one side first, e.g. ArrowTimestamp{U,TZ}(Dates.value(t))"
        )
    )
    U = Dates.Millisecond
    for t in ts
        U = _finer(U, t === DateTime ? Dates.Millisecond : timestamp_unit(t))
    end
    return (all(==(DateTime), ts)) ? DateTime : ArrowTimestamp{U, only(zones)}
end

# ---------------------------------------------------------------------------------------------
# Text: ISO 8601 with the unit's digits; zoned values in UTC with a `Z` (ADR-0021 rule 9). The
# civil date comes from the day count directly (Howard Hinnant's algorithm in Int128), so every
# representable value has a text form. Years outside 0000-9999 use ISO 8601's expanded form
# (a sign and at least five digits).

_frac_digits(::Type{Dates.Second}) = 0
_frac_digits(::Type{Dates.Millisecond}) = 3
_frac_digits(::Type{Dates.Microsecond}) = 6
_frac_digits(::Type{Dates.Nanosecond}) = 9

function _civil(days::Int128)
    z = days + 719468
    era = fld(z, 146097)
    doe = z - era * 146097
    yoe = div(doe - div(doe, 1460) + div(doe, 36524) - div(doe, 146096), 365)
    y = yoe + era * 400
    doy = doe - (365 * yoe + div(yoe, 4) - div(yoe, 100))
    mp = div(5 * doy + 2, 153)
    d = doy - div(153 * mp + 2, 5) + 1
    m = mp < 10 ? mp + 3 : mp - 9
    return (m <= 2 ? y + 1 : y), m, d
end

"Days since 1970-01-01 of a proleptic Gregorian date (the inverse of `_civil`)."
function _days_from_civil(y::Int128, m::Int, d::Int)
    y -= m <= 2
    era = fld(y, 400)
    yoe = y - era * 400
    doy = div(153 * (m > 2 ? m - 3 : m + 9) + 2, 5) + d - 1
    doe = yoe * 365 + div(yoe, 4) - div(yoe, 100) + doy
    return era * 146097 + doe - 719468
end

"`timestamp_string(t)`: ISO 8601 text with exactly the unit's fractional digits; zoned values in UTC with `Z`."
function timestamp_string(t::ArrowTimestamp)
    ns = _instant_ns(t)
    sec, sub = fldmod(ns, 1_000_000_000)
    days, sod = fldmod(sec, 86_400)
    y, m, d = _civil(days)
    ys = 0 <= y <= 9999 ? lpad(string(y), 4, '0') : string(y < 0 ? "-" : "+", lpad(string(abs(y)), 5, '0'))
    two(x) = lpad(string(x), 2, '0')
    k = _frac_digits(timestamp_unit(t))
    frac = k == 0 ? "" : "." * lpad(string(div(sub, Int128(10)^(9 - k))), k, '0')
    return string(ys, "-", two(m), "-", two(d), "T", two(div(sod, 3600)), ":", two(div(mod(sod, 3600), 60)), ":", two(mod(sod, 60)), frac, _iszoned(t) ? "Z" : "")
end

Base.print(io::IO, t::ArrowTimestamp) = print(io, timestamp_string(t))
_unitname(::Type{Dates.Second}) = "Second"
_unitname(::Type{Dates.Millisecond}) = "Millisecond"
_unitname(::Type{Dates.Microsecond}) = "Microsecond"
_unitname(::Type{Dates.Nanosecond}) = "Nanosecond"
function Base.show(io::IO, t::ArrowTimestamp)
    get(io, :typeinfo, Any) === typeof(t) && return print(io, timestamp_string(t))
    tz = timestamp_zone(t)
    return print(io, "ArrowTimestamp{Dates.", _unitname(timestamp_unit(t)), ", ", tz === nothing ? "nothing" : repr(tz), "}(", Dates.value(t), ") # ", timestamp_string(t))
end
