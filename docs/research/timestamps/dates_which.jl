using Dates, InteractiveUtils
println(VERSION, " ", dirname(pathof(Dates)))
probes = (
    (hash, (DateTime(1), UInt(0))), (isequal, (DateTime(1), DateTime(1))), (==, (DateTime(1), DateTime(1))),
    (isless, (DateTime(1), DateTime(2))), (unix2datetime, (1.0,)), (datetime2unix, (DateTime(1),)),
)
for (f, a) in probes
    m = which(f, typeof.(a))
    println(f, " => ", m.file, ":", m.line, "  ", m.sig)
end
println("typemin/max DateTime: ", typemin(DateTime), " / ", typemax(DateTime))
println("hash(DateTime) == hash of its UTInstant? ", hash(DateTime(2024, 1, 2), UInt(7)) == hash(DateTime(2024, 1, 2).instant, UInt(7)))
struct MyT
    ns::Int64
end
Base.hash(x::MyT, h::UInt) = hash(DateTime(Dates.UTM(fld(x.ns, 1_000_000) + Dates.UNIXEPOCH)), h)
println("MyT hash consistent: ", hash(MyT(1_704_164_645_123_000_000)) == hash(DateTime(2024, 1, 2, 3, 4, 5, 123)))
println("isequal(DateTime, Date)=", isequal(DateTime(2024, 1, 2), Date(2024, 1, 2)), " ==: ", DateTime(2024, 1, 2) == Date(2024, 1, 2))
println("hash(Date)==hash(DateTime) same day: ", hash(Date(2024, 1, 2)) == hash(DateTime(2024, 1, 2)))
println("Int64 ns since 1970 range: ", Dates.unix2datetime(typemin(Int64) / 1.0e9), " .. ", Dates.unix2datetime(typemax(Int64) / 1.0e9))
println("exact ns range: ", DateTime(1970) + Millisecond(fld(typemin(Int64), 10^6)), " .. ", DateTime(1970) + Millisecond(fld(typemax(Int64), 10^6)))
println("exact us range (years): ", Dates.year(DateTime(1970) + Millisecond(fld(typemin(Int64), 10^3))), " .. ", Dates.year(DateTime(1970) + Millisecond(fld(typemax(Int64), 10^3))))
println("unix2datetime(-0.000501)=", unix2datetime(-0.000501), " unix2datetime(0.0015)=", unix2datetime(0.0015))
