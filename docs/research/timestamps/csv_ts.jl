using CSV, Dates, Tables
const D = Base.loaded_modules[Base.PkgId(Base.UUID("41ac09f5-0a95-4810-aa18-c88bf48ee130"), "Durations")]
println("CSV ", pkgversion(CSV), " Durations ", pkgversion(D), " TIMESTAMP_FROM_DATES=", D.TIMESTAMP_FROM_DATES, " isdefined(Dates,:Timestamp)=", isdefined(Dates, :Timestamp))
data = """ms,us,ns,z,off,space,sec,plain,mixed,bigyear,missing_us
2024-01-02T03:04:05.123,2024-01-02T03:04:05.123456,2024-01-02T03:04:05.123456789,2024-01-02T03:04:05Z,2024-01-02T03:04:05+01:00,2024-01-02 03:04:05.5,2024-01-02T03:04:05,2024-01-02,2024-01-02T03:04:05.1,9999-12-31T00:00:00.000001,2024-01-02T03:04:05.000001
2024-01-03T00:00:00.000,1969-12-31T23:59:59.999999,1677-09-22T00:00:00.000000001,2024-01-02T03:04:05.123Z,2024-01-02T03:04:05.123456-05:30,2024-01-03 00:00:00,2024-01-03T00:00:00,2024-01-03,2024-01-03,2024-01-03T00:00:00,
"""
f = CSV.File(IOBuffer(data))
for n in propertynames(f)
    c = getproperty(f, n)
    x = c[1]
    println(rpad(n, 10), " ", eltype(c), " first=", repr(x), x isa D.Timestamp ? "  value=$(Dates.value(x))" : "")
end
println("--- Chunks")
for ch in CSV.Chunks(IOBuffer(data))
    for n in (:us, :ns, :z, :off)
        println(n, " ", eltype(getproperty(ch, n)))
    end
end
println("--- dateformat options")
for fmt in ("yyyy-mm-ddTHH:MM:SS.ssssss", "yyyy-mm-ddTHH:MM:SS.sss")
    try
        g = CSV.File(IOBuffer("us\n2024-01-02T03:04:05.123456\n"); dateformat = fmt)
        println(fmt, " => ", eltype(g.us), " ", repr(g.us[1]))
    catch e
        println(fmt, " => ERROR ", sprint(showerror, e)[1:min(end, 200)])
    end
end
for T in (DateTime, D.Timestamp{Microsecond}, D.Timestamp{Nanosecond})
    try
        g = CSV.File(IOBuffer("us\n2024-01-02T03:04:05.123456\n"); types = [T])
        println("types=", T, " => ", eltype(g.us), " ", repr(g.us[1]))
    catch e
        println("types=", T, " => ERROR ", sprint(showerror, e)[1:min(end, 300)])
    end
end
t = D.Timestamp{Microsecond}(Dates.UTInstant(Microsecond(1_704_164_645_123_456)))
u = D.Timestamp{Microsecond}(DateTime(2024, 1, 2))
println("construct raw: ", t, " value=", Dates.value(t), " convert DateTime=", convert(DateTime, t), " hash==DateTime? ", hash(u) == hash(DateTime(2024, 1, 2)), " isequal=", isequal(u, DateTime(2024, 1, 2)))
println("ranges: ns ", typemin(D.Timestamp{Nanosecond}), " .. ", typemax(D.Timestamp{Nanosecond}), "; us years ", year(typemin(D.Timestamp{Microsecond})), " .. ", year(typemax(D.Timestamp{Microsecond})))
println("fieldnames: ", fieldnames(D.Timestamp{Microsecond}), " supertype: ", supertype(D.Timestamp{Microsecond}), " isbits: ", isbitstype(D.Timestamp{Microsecond}))
