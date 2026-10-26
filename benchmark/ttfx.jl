#!/usr/bin/env julia
# ttfx.jl: load time, time to first X (TTFX) and precompile time for ChuiFrames (ADR-0022).
#
#   julia +release benchmark/ttfx.jl [--runs N] [--out FILE] [--check] [--no-workload]
#   julia +lts     benchmark/ttfx.jl [--runs N] [--out FILE] [--check] [--no-workload]
#
# `--check` compares the warm medians with benchmark/budgets.toml [ttfx."<v>"] and exits 1 over
# budget. `--no-workload` turns the PrecompileTools workload off (LocalPreferences.toml in the
# scratch environment, `precompile_workloads = false`) to measure what it buys (ADR-0011); the
# budgets apply to the default (workload on) only.
#
# Each sample is a fresh `julia --startup-file=no --project=<scratch env>` process, so the timings
# are process-level, as a user sees them:
#   startup     `julia -e 'nothing'` wall time (the floor every other number sits on)
#   load        `using ChuiFrames` timed inside the process (Julia's own startup excluded); this is
#               ADR-0005 rule 5's load time
#   first call  the TTFX workload below, run once after `using` and its Base-only SETUP
#   precompile  `@elapsed Base.compilecache` of ChuiFrames after its cache files are removed
# "cold" is the first process after the last precompile (OS file cache as the compile left it);
# "warm" is the median of the next `--runs` processes, with the min and max as the spread.
# Stdlib only: it runs on both Julia versions without an environment of its own.
module TTFX

    using TOML: TOML

    median(xs) = (s = sort(xs); n = length(s); isodd(n) ? s[(n + 1) ÷ 2] : (s[n ÷ 2] + s[n ÷ 2 + 1]) / 2)

    const ROOT = normpath(joinpath(@__DIR__, ".."))

    # The TTFX workload: the first calls a user makes. It mirrors the `@compile_workload` in
    # src/ChuiFrames.jl on purpose (ADR-0011, ADR-0022): build a frame, one pipeline of the core
    # verbs, print it, one lazy collect through a compiled stage kernel (forced, as in the
    # workload: 4 rows are below INTERP_THRESHOLD), an Arrow IPC and a CSV round trip. SETUP
    # (Base only: the inputs and a temporary directory) runs before the timer starts.
    const SETUP = raw"""
    nt = (g = ["a", "b", "a", missing], x = [1.5, 2.0, NaN, 4.0], n = [1, 2, 3, 4])
    dir = mktempdir()
    out = IOContext(devnull, :displaysize => (24, 80), :limit => true)
    """
    const WORKLOAD = raw"""
    f = Frame(nt)
    r = f |> filter(c.n .> 1) |> mutate(y = c.x .* 2) |> group_by(:g) |>
        summarise(m = mean(c.y), k = n_rows()) |> arrange(desc(c.m))
    show(out, MIME("text/plain"), r)
    ChuiFrames._FORCE_KERNEL[] = :compiled
    collect(filter(c.z .> 1)(mutate(z = c.x .* 2.0 .+ c.n)(lazy(f))))
    ChuiFrames._FORCE_KERNEL[] = :auto
    write_arrow(f, joinpath(dir, "w.arrow")); read_arrow(joinpath(dir, "w.arrow"))
    write_csv(f, joinpath(dir, "w.csv")); read_csv(joinpath(dir, "w.csv"))
    """

    const SCRIPT = """
    t0 = time_ns(); using ChuiFrames; t1 = time_ns()
    using Statistics: mean
    $SETUP
    t2 = time_ns()
    $WORKLOAD
    t3 = time_ns()
    println((t1 - t0) / 1e9, " ", (t3 - t2) / 1e9)
    """

    julia() = Base.julia_cmd().exec[1]
    # A user's environment: a scratch project that `Pkg.develop`s this checkout and adds Statistics
    # (for `mean`; the same version ChuiFrames resolves). Nothing in the repo is written.
    # A scratch depot is stacked in front of the user's depot: ChuiFrames' cache files are written
    # (and removed for the precompile timing) there only. Dependencies' caches are reused from the
    # user depot when they match; otherwise they are compiled once into the scratch depot and kept.
    const ENV_DIR = Ref("")
    const DEPOT = Ref("")
    function jl(args...)
        cmd = `$(julia()) --startup-file=no --project=$(ENV_DIR[]) $args`
        return addenv(cmd, "JULIA_DEPOT_PATH" => DEPOT[] * ":" * join(DEPOT_PATH, ":"))
    end
    function make_env(workload::Bool)
        ENV_DIR[] = mktempdir()
        DEPOT[] = mktempdir()
        workload || write(
            joinpath(ENV_DIR[], "LocalPreferences.toml"),
            "[ChuiFrames]\nprecompile_workloads = false\n"
        )
        code = "using Pkg; Pkg.develop(path = ARGS[1]); Pkg.add(\"Statistics\"); Pkg.instantiate()"
        run(pipeline(jl("-e", code, ROOT); stdout = devnull, stderr = devnull))
        return nothing
    end

    function sample()
        out = readchomp(jl("-e", SCRIPT))
        a, b = parse.(Float64, split(last(split(out, '\n'))))
        return a, b
    end

    startup() = @elapsed run(`$(julia()) --startup-file=no -e nothing`)

    function precompile_time()
        # Remove ChuiFrames' cache files from the scratch depot, then time `compilecache` alone.
        # Only ChuiFrames' own directory: dependencies compiled into the scratch depot (when the
        # user depot had no matching cache) stay, so the timing never includes compiling them.
        v = "v$(VERSION.major).$(VERSION.minor)"
        rm(joinpath(DEPOT[], "compiled", v, "ChuiFrames"); force = true, recursive = true)
        cdir = joinpath(DEPOT[], "compiled", v)
        deps = isdir(cdir) ? filter(!=("ChuiFrames"), readdir(cdir)) : String[]
        isempty(deps) || println("ttfx.jl: note: dependency caches NOT reused from the user depot (compiled once into the scratch depot, kept): ", join(deps, ", "))
        code = """
        id = Base.identify_package("ChuiFrames")
        print(@elapsed Base.compilecache(id))
        """
        return parse(Float64, last(split(readchomp(pipeline(jl("-e", code); stderr = devnull)), '\n')))
    end

    stats(xs) = (median = median(xs), min = minimum(xs), max = maximum(xs))
    fmt(x) = string(round(x * 1000; digits = 1), " ms")
    fmt(s::NamedTuple) = string(fmt(s.median), " [", fmt(s.min), ", ", fmt(s.max), "]")

    # Budgets: benchmark/budgets.toml [ttfx.<major.minor>] (ADR-0022), in milliseconds.
    function budgets()
        all = TOML.parsefile(joinpath(ROOT, "benchmark", "budgets.toml"))["ttfx"]
        return get(all, "$(VERSION.major).$(VERSION.minor)", get(all, "default", Dict()))
    end

    function check(io, name, measured_s, budget_ms)
        ok = measured_s * 1000 <= budget_ms
        println(io, rpad(name, 27), ": ", fmt(measured_s), " (budget ", budget_ms, " ms) ", ok ? "OK" : "OVER BUDGET")
        return ok
    end

    function main(args)
        runs = 10
        out = nothing
        docheck = false
        workload = true
        i = 1
        while i <= length(args)
            args[i] == "--runs" && (runs = parse(Int, args[i + 1]); i += 2; continue)
            args[i] == "--out" && (out = args[i + 1]; i += 2; continue)
            args[i] == "--check" && (docheck = true; i += 1; continue)
            args[i] == "--no-workload" && (workload = false; i += 1; continue)
            error("ttfx.jl: unknown argument $(args[i])")
        end
        docheck && !workload && error("ttfx.jl: the budgets apply with the workload on; drop --no-workload")
        load_before = Sys.loadavg()
        make_env(workload)
        run(pipeline(jl("-e", "using ChuiFrames"); stderr = devnull))   # caches of the deps exist
        pre = [precompile_time() for _ in 1:3]
        cold = sample()                       # the first process after the last compile
        warm = [sample() for _ in 1:runs]
        st = [startup() for _ in 1:runs]
        load = stats(first.(warm))
        call = stats(last.(warm))
        tot = stats(first.(warm) .+ last.(warm))
        io = IOBuffer()
        println(
            io, "julia ", VERSION, " | ", Sys.cpu_info()[1].model, " ", Sys.CPU_THREADS, " cores | ",
            round(Sys.total_memory() / 2^30; digits = 1), " GiB | load average before ",
            round.(load_before; digits = 2), ", after ", round.(Sys.loadavg(); digits = 2), " | runs ", runs,
            " | precompile workload ", workload ? "on" : "OFF"
        )
        println(io, "startup (julia -e nothing)  : ", fmt(stats(st)))
        println(io, "precompile (ChuiFrames only): ", fmt(stats(pre)), "  (3 compiles)")
        println(io, "cold  load + first call     : ", fmt(cold[1]), " + ", fmt(cold[2]))
        println(io, "warm  load                  : ", fmt(load))
        println(io, "warm  first call            : ", fmt(call))
        println(io, "warm  load + first call     : ", fmt(tot))
        ok = true
        if docheck
            b = budgets()
            println(io, "budgets (benchmark/budgets.toml, warm medians):")
            ok &= check(io, "  load", load.median, b["load_ms"])
            ok &= check(io, "  load + first call", tot.median, b["load_first_call_ms"])
            ok &= check(io, "  precompile", stats(pre).median, b["precompile_ms"])
        end
        s = String(take!(io))
        print(s)
        out === nothing || write(out, s)
        return ok ? 0 : 1
    end

end # module

abspath(PROGRAM_FILE) == @__FILE__() && exit(TTFX.main(ARGS))
