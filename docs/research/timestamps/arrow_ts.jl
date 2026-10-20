using Arrow, Dates
const M = Arrow.Meta.TimeUnit
out = ARGS[1]
println(fieldnames(Arrow.Timestamp), " ", fieldtypes(Arrow.Timestamp{M.MICROSECOND, :UTC}))
println("U typeof: ", typeof(M.MICROSECOND), " Int16=", Int16(M.MICROSECOND), " all=", instances(M.T))
t = Arrow.Timestamp{M.MICROSECOND, :UTC}(Int64(1_704_164_645_123_456))
println(t, " raw=", t.x, " isbits=", isbitstype(typeof(t)), " sizeof=", sizeof(t))
println("ArrowKind=", Arrow.ArrowTypes.ArrowKind(typeof(t)), " arrowname=", repr(Arrow.ArrowTypes.arrowname(typeof(t))))
TS(U, TZ, v) = Arrow.Timestamp{U, TZ}(Int64(v))
cols = (
    us_utc = [TS(M.MICROSECOND, :UTC, 1_704_164_645_123_456), TS(M.MICROSECOND, :UTC, 0)],
    us_utc_missing = Union{Missing, Arrow.Timestamp{M.MICROSECOND, :UTC}}[TS(M.MICROSECOND, :UTC, 1_704_164_645_123_456), missing],
    us_naive = [TS(M.MICROSECOND, nothing, 1_704_164_645_123_456), TS(M.MICROSECOND, nothing, -1)],
    s_naive = [TS(M.SECOND, nothing, 1_704_164_645), TS(M.SECOND, nothing, 0)],
    ns_naive = [TS(M.NANOSECOND, nothing, 1_704_164_645_123_456_789), TS(M.NANOSECOND, nothing, 0)],
    ns_berlin = [TS(M.NANOSECOND, Symbol("Europe/Berlin"), 1_704_164_645_123_456_789), TS(M.NANOSECOND, Symbol("Europe/Berlin"), 0)],
    ms_dt_storage = [Arrow.DATETIME(Int64(1)), Arrow.DATETIME(Int64(2))],
    plain_datetime = [DateTime(2024, 1, 2), DateTime(2024, 1, 3)],
)
Arrow.write(out, cols)
tb = Arrow.Table(out)
for n in propertynames(tb)
    println(n, " => ", eltype(getproperty(tb, n)))
end
tbr = Arrow.Table(out; convert = false)
for n in propertynames(tbr)
    c = getproperty(tbr, n)
    println("raw ", n, " => ", eltype(c), " ", c[1] === missing ? missing : c[1].x)
end
