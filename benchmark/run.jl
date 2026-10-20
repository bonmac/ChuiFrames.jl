#!/usr/bin/env julia
# run.jl: run benchmark/benchmarks.jl once on this checkout and print a table (median, minimum and
# maximum time, samples, allocations, memory) for docs/ and HANDOFF.md (ADR-0022). Without
# `--check` it only reports; with it, it is the budget gate of ADR-0022. The regression gate between
# commits is AirspeedVelocity in CI and `julia scripts/ci.jl bench` locally.
#
#   julia +release benchmark/run.jl [--check] [--out FILE] [--toml FILE]
#   julia +lts     benchmark/run.jl [--check] [--out FILE] [--toml FILE]
#
# `--check` compares each entry with benchmark/budgets.toml: the median time with [time."<v>"],
# the allocation count with [allocs."<v>"] and the memory with [memory."<v>"], where <v> is the
# Julia major.minor (other versions use the "1.10" tables). It exits 1 when an entry is over a
# budget, or when a SUITE entry and the budget rows of any table do not match one to one.
# `--out` writes the printed table; `--toml` writes the raw numbers ("key" = [median_ns, min_ns,
# max_ns, allocs, bytes]) for the comparison tables in docs/research/performance.md.
#
# Like scripts/ci.jl, it develops the checkout into a scratch copy of benchmark/Project.toml, so no
# tracked file is rewritten and each Julia version resolves its own manifest.
const ROOT = normpath(joinpath(@__DIR__, ".."))

if get(ENV, "CHUI_BENCH_CHILD", "") != "1"
    env = mktempdir()
    cp(joinpath(ROOT, "benchmark", "Project.toml"), joinpath(env, "Project.toml"))
    jl = `$(Base.julia_cmd().exec[1]) --startup-file=no --project=$env`
    run(pipeline(`$jl -e 'using Pkg; Pkg.develop(path = ARGS[1]); Pkg.instantiate()' $ROOT`; stdout = devnull, stderr = devnull))
    p = run(ignorestatus(addenv(`$jl $(@__FILE__) $ARGS`, "CHUI_BENCH_CHILD" => "1")))
    exit(p.exitcode)
end

using TOML: TOML
using Pkg: Pkg
const LOAD_BEFORE = Sys.loadavg()
const T_START = time()
include(joinpath(ROOT, "benchmark", "benchmarks.jl"))
tune!(SUITE)
res = run(SUITE; verbose = false)
const T_RUN = time() - T_START

# (key, median ns, min ns, max ns, samples, allocs, bytes), keys `group/sub/.../leaf`.
rows = Tuple{String, Float64, Float64, Float64, Int, Int, Int}[]
walk(g, p) = g isa BenchmarkGroup ?
    foreach(k -> walk(g[k], isempty(p) ? string(k) : p * "/" * string(k)), collect(keys(g))) :
    (m = median(g); push!(rows, (p, time(m), time(minimum(g)), time(maximum(g)), length(g.times), allocs(m), memory(m))))
walk(res, "")
sort!(rows; by = first)

pkgversion_of(name) = (d = Pkg.dependencies(); i = findfirst(p -> p.name == name, collect(values(d))); i === nothing ? "?" : string(collect(values(d))[i].version))
ns(t) = t < 1.0e3 ? string(round(t; digits = 1), " ns") : t < 1.0e6 ? string(round(t / 1.0e3; digits = 2), " μs") :
    t < 1.0e9 ? string(round(t / 1.0e6; digits = 2), " ms") : string(round(t / 1.0e9; digits = 3), " s")
bytes(b) = b < 1024 ? string(b, " B") : b < 1024^2 ? string(round(b / 1024; digits = 1), " KiB") :
    string(round(b / 1024^2; digits = 2), " MiB")
orno(x, g) = x === nothing ? "—" : g(x)

io = IOBuffer()
println(
    io, "julia ", VERSION, " | ", Sys.cpu_info()[1].model, " | ", Sys.CPU_THREADS, " cores | ",
    round(Sys.total_memory() / 2^30; digits = 1), " GiB | threads ", Threads.nthreads(),
    " | BenchmarkTools ", pkgversion_of("BenchmarkTools"), " | ChuiFrames ", ROOT
)
println(
    io, "load average before ", round.(LOAD_BEFORE; digits = 2), ", after ", round.(Sys.loadavg(); digits = 2),
    " | suite wall time ", round(T_RUN; digits = 1), " s"
)
println(io, "\n| benchmark | median | min | max | samples | allocs | memory |")
println(io, "|---|---:|---:|---:|---:|---:|---:|")
for (name, t, tmin, tmax, ns_, a, m) in rows
    println(io, "| ", name, " | ", ns(t), " | ", ns(tmin), " | ", ns(tmax), " | ", ns_, " | ", a, " | ", bytes(m), " |")
end

ok = true
if "--check" in ARGS
    budgets = TOML.parsefile(joinpath(ROOT, "benchmark", "budgets.toml"))
    ver = "$(VERSION.major).$(VERSION.minor)"
    suite_keys = Set(first.(rows))
    pick(kind) = (t = budgets[kind]; get(t, ver, t["1.10"]))
    bt, ba, bm = pick("time"), pick("allocs"), pick("memory")
    println(io, "\nBudgets: benchmark/budgets.toml, tables for Julia ", haskey(budgets["time"], ver) ? ver : "1.10 (fallback)")
    println(io, "\n| benchmark | median | time budget | allocs | budget | memory | budget | |")
    println(io, "|---|---:|---:|---:|---:|---:|---:|---|")
    for (name, t, _, _, _, a, m) in rows
        b1, b2, b3 = get(bt, name, nothing), get(ba, name, nothing), get(bm, name, nothing)
        verdict = any(isnothing, (b1, b2, b3)) ? "NO BUDGET ROW" :
            join(filter(!isempty, [t <= b1 ? "" : "TIME OVER", a <= b2 ? "" : "ALLOCS OVER", m <= b3 ? "" : "MEMORY OVER"]), ", ")
        verdict = isempty(verdict) ? "OK" : verdict
        global ok &= verdict == "OK"
        println(io, "| ", name, " | ", ns(t), " | ", orno(b1, ns), " | ", a, " | ", orno(b2, string), " | ", bytes(m), " | ", orno(b3, bytes), " | ", verdict, " |")
    end
    # Every version's table of every kind must cover the SUITE keys exactly, so a row missing for
    # the other Julia version fails here too, not only when someone runs that version.
    for kind in ("time", "allocs", "memory"), (v, tbl) in sort!(collect(budgets[kind]); by = first)
        missing_rows = sort!(collect(setdiff(suite_keys, keys(tbl))))
        extra_rows = sort!(collect(setdiff(keys(tbl), suite_keys)))
        isempty(missing_rows) && isempty(extra_rows) && continue
        global ok = false
        println(io, "table [", kind, ".\"", v, "\"]: missing ", missing_rows, ", not in SUITE ", extra_rows)
    end
    println(io, ok ? "\nrun.jl --check: OK ($(length(rows)) benchmarks within budget)" : "\nrun.jl --check: FAILED")
end
s = String(take!(io))
print(s)
i = findfirst(==("--out"), ARGS)
i === nothing || write(ARGS[i + 1], s)
i = findfirst(==("--toml"), ARGS)
i === nothing || open(ARGS[i + 1], "w") do f
    TOML.print(f, Dict("julia" => string(VERSION), "rows" => Dict(r[1] => [r[2], r[3], r[4], r[6], r[7]] for r in rows)))
end
exit(ok ? 0 : 1)
