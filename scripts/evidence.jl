#!/usr/bin/env julia
# evidence.jl: run a command and keep its result as a file keyed to the commit (factory 0.2.4).
#
#   julia scripts/evidence.jl <kind> [--root DIR] -- <cmd...>   run cmd in DIR (default the repo)
#   julia scripts/evidence.jl latest <kind> [--root DIR]        print the evidence file for HEAD
#
# Writes .lanes/evidence/<kind>-<sha7>.txt (gitignored; a rerun at the same commit replaces it):
# the head sha, a dirty flag (uncommitted changes when it ran), the command, its exit code, the
# seconds it took and its full output (stdout and stderr, interleaved). Exit = the command's exit
# code. A test count written in HANDOFF.md or a CHANGELOG cites this file instead of being typed
# from memory, and scripts/check_claims.jl reads `tests_*` claims from it (`evidence_totals`).
# `latest` falls back to the newest file of that kind whose commit is an ancestor of HEAD.
module Evidence

    using Dates
    include(joinpath(@__DIR__, "_common.jl"))

    const KIND = r"^[a-z0-9][a-z0-9-]{0,39}$"
    evidence_dir(root) = joinpath(root, ".lanes", "evidence")

    head_sha(root) = git(root, "rev-parse", "HEAD")
    is_dirty(root) = !isempty(something(git(root, "status", "--porcelain"), ""))

    "The header fields of an evidence file (key => value), or nothing when it is not one."
    function header(path)
        isfile(path) || return nothing
        h = Dict{String, String}()
        for l in eachline(path)
            l == "--- output ---" && return h
            startswith(l, "#") && continue
            m = match(r"^([a-z]+): (.*)$", l)
            m === nothing || (h[m.captures[1]] = m.captures[2])
        end
        return nothing
    end
    output(path) = (t = read(path, String); i = findfirst("\n--- output ---\n", t); i === nothing ? "" : t[(last(i) + 1):end])

    """
        latest(root, kind) -> path or nothing

    The evidence of `kind` for HEAD, else the newest one (by its `date`) whose commit is an ancestor of HEAD.
    """
    function latest(root, kind)
        head = head_sha(root)
        head === nothing && return nothing
        exact = joinpath(evidence_dir(root), "$kind-$(first(head, 7)).txt")
        h = header(exact)
        h !== nothing && get(h, "head", "") == head && return exact
        best, bestdate = nothing, ""
        d = evidence_dir(root)
        for f in (isdir(d) ? readdir(d) : String[])
            startswith(f, "$kind-") && endswith(f, ".txt") || continue
            h = header(joinpath(d, f))
            (h === nothing || !haskey(h, "head")) && continue
            git(root, "merge-base", "--is-ancestor", h["head"], head) === nothing && continue
            get(h, "date", "") > bestdate && ((best, bestdate) = (joinpath(d, f), get(h, "date", "")))
        end
        return best
    end

    """
        test_totals(text) -> Dict or nothing

    The totals of the Julia `Test Summary:` tables in `text` (pass, fail, error, broken, total; absent
    columns are 0): the first row of each table, SUMMED, since Julia prints one table per top-level
    @testset (0.2.4 review: two top-level sets were read as the last one alone). ANSI colour codes are
    stripped. A table a subprocess printed into the same output is counted too. nothing when there is none.
    """
    function test_totals(text)
        lines = split(replace(text, r"\e\[[0-9;]*[A-Za-z]" => ""), '\n')
        idx = [i for i in eachindex(lines) if startswith(lines[i], "Test Summary:") && i < length(lines)]
        isempty(idx) && return nothing
        tabs = filter(!isnothing, [one_table(lines, i) for i in idx])
        isempty(tabs) && return nothing
        return Dict(k => sum(t[k] for t in tabs) for k in keys(first(tabs)))
    end
    function one_table(lines, i)
        cols = [lowercase(c) for c in split(strip(split(lines[i], '|')[2]))]
        row = split(lines[i + 1], '|')
        length(row) >= 2 || return nothing
        vals = split(strip(row[2]))
        out = Dict(k => 0 for k in ("pass", "fail", "error", "broken", "total"))
        # a row may leave a column blank (no failures): right-align the numbers against the columns
        nums = [parse(Int, v) for v in vals if occursin(r"^\d+$", v)]
        named = filter(c -> c in keys(out), cols)
        length(nums) == length(named) || (nums = right_align(lines[i], lines[i + 1], named))
        for (c, n) in zip(named, nums)
            out[c] = n
        end
        return out
    end
    # Columns by position: each number belongs to the header column whose end it lines up with.
    function right_align(hdr, row, named)
        ends = Dict(c => last(findfirst(Regex("\\b" * uppercasefirst(c) * "\\b"), hdr)) for c in named)
        vals, prev = Int[], last(findfirst('|', hdr))
        for c in named   # the column spans from the previous column's end to its own
            e = ends[c]
            s = prev < length(row) ? row[(prev + 1):min(e, length(row))] : ""
            prev = e
            m = match(r"(\d+)\s*$", s)
            push!(vals, m === nothing ? 0 : parse(Int, m.captures[1]))
        end
        return vals
    end

    function run_evidence(root, kind, cmd::Vector{String}; io = stdout)
        head = head_sha(root)
        head === nothing && (println(stderr, "evidence.jl: $root is not a git checkout with a commit"); return 2)
        dirty = is_dirty(root)
        mkpath(evidence_dir(root))
        tmp = tempname()
        t0 = time()
        code = open(tmp, "w") do f
            p = run(pipeline(ignorestatus(Cmd(Cmd(cmd); dir = root)); stdout = f, stderr = f); wait = true)
            p.exitcode
        end
        secs = round(time() - t0; digits = 1)
        out = read(tmp, String)
        rm(tmp; force = true)
        path = joinpath(evidence_dir(root), "$kind-$(first(head, 7)).txt")
        open(path, "w") do f
            println(f, "# evidence: written by scripts/evidence.jl. Cite this file; do not retype its numbers.")
            println(f, "kind: $kind\nhead: $head\ndirty: $dirty\ncmd: ", join(cmd, ' '), "\nexit: $code\nseconds: $secs")
            println(f, "date: ", Dates.format(Dates.now(Dates.UTC), "yyyy-mm-ddTHH:MM:SS"), "Z")
            tt = test_totals(out)
            tt === nothing || println(f, "tests: ", join(("$k=$(tt[k])" for k in ("pass", "fail", "error", "broken", "total")), ' '))
            println(f, "--- output ---")
            print(f, out)
        end
        print(io, out)
        println(io, "evidence.jl: exit $code in $(secs) s$(dirty ? " (DIRTY tree)" : ""); wrote ", relpath(path, root))
        return code
    end

    function main(args; io = stdout)
        i = findfirst(==("--"), args)
        head, cmd = i === nothing ? (args, String[]) : (args[1:(i - 1)], String.(args[(i + 1):end]))
        opts, pos = try
            parse_args(head, (), ("--root",))
        catch e
            println(stderr, "evidence.jl: ", e isa ErrorException ? e.msg : e)
            return 2
        end
        root = abspath(get(opts, "--root", normpath(joinpath(@__DIR__, ".."))))
        if length(pos) == 2 && pos[1] == "latest" && isempty(cmd)
            p = latest(root, pos[2])
            p === nothing && (println(stderr, "evidence.jl: no `$(pos[2])` evidence for HEAD or an ancestor"); return 1)
            println(io, relpath(p, root))
            return 0
        end
        (length(pos) == 1 && occursin(KIND, pos[1]) && pos[1] != "latest" && !isempty(cmd)) ||
            (println(stderr, "usage: julia scripts/evidence.jl <kind> [--root DIR] -- <cmd...> | latest <kind> [--root DIR]"); return 2)
        return run_evidence(root, pos[1], cmd; io)
    end

end # module

abspath(PROGRAM_FILE) == @__FILE__() && exit(Evidence.main(ARGS))
