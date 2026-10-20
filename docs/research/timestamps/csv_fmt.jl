using CSV, Dates
const D = Base.loaded_modules[Base.PkgId(Base.UUID("41ac09f5-0a95-4810-aa18-c88bf48ee130"), "Durations")]
src() = IOBuffer("us\n2024-01-02T03:04:05.123456\n2024-01-02T03:04:05.123\n")
for fmt in ("yyyy-mm-ddTHH:MM:SS.ssssss", "yyyy-mm-ddTHH:MM:SS.sss", "yyyy-mm-ddTHH:MM:SS.s")
    for T in (nothing, DateTime, D.Timestamp{Microsecond})
        kw = T === nothing ? (; dateformat = fmt, delim = ',') : (; dateformat = fmt, delim = ',', types = [T])
        try
            g = CSV.File(src(); kw..., on_error = :collect)
            println(fmt, " types=", T, " => ", eltype(g.us), " ", repr(collect(g.us)), " problems=", length(CSV.problems(g)))
        catch e
            println(fmt, " types=", T, " => ERROR ", first(sprint(showerror, e), 200))
        end
    end
end
for T in (DateTime, D.Timestamp{Microsecond}, D.Timestamp{Millisecond})
    g = CSV.File(src(); delim = ',', types = [T], on_error = :collect)
    println("no fmt types=", T, " => ", eltype(g.us), " ", repr(collect(g.us)), " problems=", [string(p) for p in CSV.problems(g)])
end
g = CSV.File(src(); delim = ',', typemap = Dict(D.Timestamp{Nanosecond} => DateTime), on_error = :collect)
println("typemap ns->DateTime => ", eltype(g.us), " ", repr(collect(g.us)), " problems=", length(CSV.problems(g)))
function chunks_typemap()
    try
        collect(CSV.Chunks(src(); delim = ',', typemap = Dict(D.Timestamp{Nanosecond} => DateTime)))
        return "ok"
    catch e
        return first(sprint(showerror, e), 200)
    end
end
println("Chunks kwargs typemap? ", chunks_typemap())
