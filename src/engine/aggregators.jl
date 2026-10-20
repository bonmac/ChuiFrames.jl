# ChuiFrames-owned aggregators, built on the CC-004 protocol (user decision R8, option A,
# 2026-10-20): the missing-aware (`skipmissing`) variants, `n_distinct`, and the holistic
# reductions (`median`, `quantile`, `nth`) that need every value. They are not stand-ins: they
# stay ChuiFrames' own after the ChuiCore switch, and they apply the protocol only through
# `Upstream.init/partial/combine/final`.

const UP = Upstream

"""
    SkipMissingAgg(inner)

`inner` over the non-`missing` elements of each chunk: `sum(skipmissing(c.x))`.
"""
struct SkipMissingAgg{A} <: UP.Aggregator
    inner::A
end
UP.init(m::SkipMissingAgg) = UP.init(m.inner)
UP.partial(m::SkipMissingAgg, acc, chunk) = UP.partial(m.inner, acc, Iterators.filter(!ismissing, chunk))
UP.combine(m::SkipMissingAgg, a, b) = UP.combine(m.inner, a, b)
UP.final(m::SkipMissingAgg, acc) = UP.final(m.inner, acc)
UP.iscommutative(m::SkipMissingAgg) = UP.iscommutative(m.inner)
UP.neutral(m::SkipMissingAgg) = UP.neutral(m.inner)
Base.show(io::IO, m::SkipMissingAgg) = print(io, "SkipMissingAgg(", m.inner, ")")

# Key canonicalisation (ADR-0003 rule 8): NaN and -NaN one key, -0.0 and 0.0 one key.
@inline _canon(x) = x
@inline _canon(x::AbstractFloat) = isnan(x) ? oftype(x, NaN) : (iszero(x) ? zero(x) : x)

"""
    NDistinct()

The number of distinct values under ADR-0003 rule 8's key equality (`missing` counts as a
value, as in dplyr's `n_distinct`). The accumulator is a set of canonical keys.
"""
struct NDistinct <: UP.Aggregator end
UP.init(::NDistinct) = Set{Any}()
function UP.partial(::NDistinct, acc, chunk)
    for x in chunk
        push!(acc, _canon(x))
    end
    return acc
end
UP.combine(::NDistinct, a, b) = union!(a, b)
UP.final(::NDistinct, acc) = length(acc)
UP.iscommutative(::NDistinct) = true
UP.neutral(::NDistinct) = Set{Any}()

"""
    Holistic(f, name)

A reduction that needs every value at once (`median`, `quantile`, `nth`): the accumulator
collects the chunks in order; `final` applies `f` to the concatenation. Not commutative.
"""
struct Holistic{F} <: UP.Aggregator
    f::F
    name::String
end
UP.init(::Holistic) = Any[]
UP.partial(::Holistic, acc, chunk) = append!(acc, chunk)
UP.combine(::Holistic, a, b) = append!(a, b)
UP.final(m::Holistic, acc) = m.f(_narrow(acc))
Base.show(io::IO, m::Holistic) = print(io, "Holistic(", m.name, ")")

# A concretely typed copy of collected values.
_narrow(v::AbstractVector) = isempty(v) ? v : [x for x in v]
