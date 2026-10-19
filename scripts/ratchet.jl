#!/usr/bin/env julia
# ratchet.jl: one-way limits from ratchets.toml.
#
#   julia scripts/ratchet.jl [--base main] [--lcov lcov.info] [--root DIR]
#
# 1. Direction, against the merge base's ratchets.toml: coverage.floor may only rise,
#    bench.time_tolerance and every size max_lines may only fall, no size rule may vanish.
# 2. Current tree: every tracked file matching a size glob is within max_lines; with --lcov,
#    line coverage is at least coverage.floor.
# Exit 0 = pass, 1 = a limit broken, 2 = could not evaluate.
module Ratchet

using TOML
include(joinpath(@__DIR__, "_common.jl"))

"Compare two parsed ratchets.toml dicts; return failure messages."
function direction(old, new)
    bad = String[]
    of = get(get(old, "coverage", Dict()), "floor", 0.0)
    nf = get(get(new, "coverage", Dict()), "floor", 0.0)
    nf < of && push!(bad, "coverage.floor lowered $of -> $nf (may only rise)")
    ot = get(get(old, "bench", Dict()), "time_tolerance", Inf)
    nt = get(get(new, "bench", Dict()), "time_tolerance", Inf)
    nt > ot && push!(bad, "bench.time_tolerance raised $ot -> $nt (may only fall)")
    newsize = Dict(s["glob"] => s["max_lines"] for s in get(new, "size", Any[]))
    for s in get(old, "size", Any[])
        g = s["glob"]
        if !haskey(newsize, g)
            push!(bad, "size rule `$g` removed (may only tighten)")
        elseif newsize[g] > s["max_lines"]
            push!(bad, "size `$g` raised $(s["max_lines"]) -> $(newsize[g]) (may only fall)")
        end
    end
    return bad
end

"Check tracked files against the size budgets; return failure messages."
function sizes(root, cfg, files)
    bad = String[]
    for s in get(cfg, "size", Any[]), f in files
        globmatch(s["glob"], f) || continue
        p = joinpath(root, f)
        isfile(p) || continue
        n = countlines(p)
        n > s["max_lines"] && push!(bad, "$f has $n lines > $(s["max_lines"]) (`$(s["glob"])`)")
    end
    return bad
end

"Line coverage percent from an lcov file (sum LH / sum LF)."
function lcov_percent(path)
    found = hit = 0
    for l in eachline(path)
        startswith(l, "LF:") && (found += parse(Int, l[4:end]))
        startswith(l, "LH:") && (hit += parse(Int, l[4:end]))
    end
    return found == 0 ? 0.0 : 100 * hit / found
end

function main(args)
    opts, _ = try
        parse_args(args, (), ("--base", "--lcov", "--root"))
    catch e
        println(stderr, "ratchet.jl: ", e isa ErrorException ? e.msg : e)
        return 2
    end
    root = abspath(get(opts, "--root", normpath(joinpath(@__DIR__, ".."))))
    cfgpath = joinpath(root, "ratchets.toml")
    isfile(cfgpath) || (println(stderr, "ratchet.jl: no ratchets.toml"); return 2)
    cfg = TOML.parsefile(cfgpath)
    bad = String[]
    mb = merge_base(root, get(opts, "--base", "main"))
    oldtxt = mb === nothing ? nothing : git(root, "show", "$mb:ratchets.toml")
    if oldtxt === nothing
        println("ratchet.jl: no ratchets.toml at the merge base; direction check skipped")
    else
        append!(bad, direction(TOML.parse(oldtxt), cfg))
    end
    append!(bad, sizes(root, cfg, tracked_files(root)))
    if haskey(opts, "--lcov")
        pct = lcov_percent(opts["--lcov"])
        floor = get(get(cfg, "coverage", Dict()), "floor", 0.0)
        println("ratchet.jl: coverage $(round(pct; digits = 2))% (floor $floor%)")
        pct + 1e-9 < floor && push!(bad, "coverage $(round(pct; digits = 2))% is below the floor $floor%")
        pct > floor + 1 && println("ratchet.jl: coverage is >1 point above the floor; consider raising coverage.floor")
    end
    foreach(b -> println("  FAIL ", b), bad)
    println(isempty(bad) ? "ratchet.jl: OK" : "ratchet.jl: FAILED ($(length(bad)))")
    return isempty(bad) ? 0 : 1
end

end # module

abspath(PROGRAM_FILE) == @__FILE__() && exit(Ratchet.main(ARGS))
