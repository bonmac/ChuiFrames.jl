using Arrow, Dates, CSV
const D = Base.loaded_modules[Base.PkgId(Base.UUID("41ac09f5-0a95-4810-aa18-c88bf48ee130"), "Durations")]
const M = Arrow.Meta.TimeUnit
# ArrowTemporal-style lazy wrapper over raw Int64 + validity
struct TSView{E, U, TZ} <: AbstractVector{E}
    v::Vector{Int64}
    valid::BitVector
end
Base.size(x::TSView) = size(x.v)
Base.IndexStyle(::Type{<:TSView}) = IndexLinear()
Base.getindex(x::TSView{E, U, TZ}, i::Int) where {E, U, TZ} = x.valid[i] ? Arrow.Timestamp{U, TZ}(x.v[i]) : missing
w = TSView{Union{Missing, Arrow.Timestamp{M.MICROSECOND, :UTC}}, M.MICROSECOND, :UTC}(Int64[1_704_164_645_123_456, 7], BitVector([true, false]))
dur = [D.Timestamp{Microsecond}(Dates.UTInstant(Microsecond(1_704_164_645_123_456)))]
Arrow.write(ARGS[1], (wrapped = w,))
Arrow.write(ARGS[2], (durations_ts = dur,))
println("julia readback wrapped: ", Arrow.Table(ARGS[1]; convert = false).wrapped |> collect)
println("julia readback durations: ", eltype(Arrow.Table(ARGS[2]).durations_ts))
