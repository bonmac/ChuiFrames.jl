using Parquet2, Dates, Tables
for f in ARGS
    println("== ", basename(f))
    ds = Parquet2.Dataset(f)
    ct = Tables.columntable(ds)
    for n in propertynames(ct)
        c = getproperty(ct, n)
        println(rpad(n, 10), " eltype=", eltype(c), " vals=", collect(c), " parqtype=", Parquet2.parqtype(ds, string(n)))
    end
end
ds = Parquet2.Dataset(ARGS[1])
println("Dataset fields: ", fieldnames(typeof(ds)))
println("ParqDateTime fields: ", fieldnames(Parquet2.ParqDateTime))
m = getfield(ds, :meta)
println(typeof(m))
se = m.schema[2]
println(se.name, " ", se.logicalType)
println("1704164645123456 us -> unix2datetime(float): ", unix2datetime(1704164645123456 * 10.0^-6))
