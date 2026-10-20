using Parquet2, Dates
ds = Parquet2.Dataset(ARGS[1])
m = getfield(ds, :meta_orig)
println(typeof(m))
for se in m.schema[2:end]
    println(se.name, " => ", se.logicalType)
end
println("kv metadata keys: ", collect(keys(ds.metadata)))
pdt = Parquet2.ParqDateTime(-6)
for x in (1704164645123456, 1704164645123500, 1704164645123499, -1, -500, -501)
    println("us ", x, " -> ", DateTime(pdt, x))
end
pdt9 = Parquet2.ParqDateTime(-9)
for x in (1704164645123456789, 1704164645123499999, 1704164645123500001)
    println("ns ", x, " -> ", DateTime(pdt9, x))
end
# writer
w = joinpath(ARGS[2], "pq2_written.parquet")
dts = (DateTime(2024, 1, 2, 3, 4, 5, 123), DateTime(1970, 1, 1, 0, 0, 0, 1), DateTime(1900, 1, 1, 0, 0, 0, 7))
Parquet2.writefile(w, (dt = [DateTime(2024, 1, 2, 3, 4, 5, 123), DateTime(1900, 1, 1), DateTime(1970, 1, 1, 0, 0, 0, 1)], i = Int64[1, 2, 3]))
ds2 = Parquet2.Dataset(w)
println("written schema: ", [(se.name, se.logicalType, se.var"type") for se in getfield(ds2, :meta_orig).schema[2:end]])
println(collect(Parquet2.Tables.getcolumn(Parquet2.Tables.columns(ds2), :dt)))
println("floor check: ", [floor(Int64, datetime2unix(d) * 10^3) for d in dts])
println("exact: ", [Dates.value(d) - Dates.UNIXEPOCH for d in dts])
