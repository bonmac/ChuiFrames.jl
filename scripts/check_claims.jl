#!/usr/bin/env julia
# check_claims.jl: numbers written in Markdown match the values they are derived from (0.2.4).
#
#   julia scripts/check_claims.jl [--root DIR] [--strict]
#
# A claim is an HTML comment on the line that states the number:
#   The lane cap is 6 <!-- claim: max_open=6 -->
#   Template tests: 1006/1006 <!-- claim: tests_pass=1006 tests_total=1006 evidence=tests-1a2b3c4 -->
# Each KEY=VALUE must equal the derived value, and VALUE must also appear in the line's text
# outside the comment (so the prose and the marker cannot drift apart). Keys:
#   max_open            [lanes] max_open in .agents/agent-registry.toml (default 4)
#   roles               the number of [[agents]] in the registry
#   factory_version     `version` in .factory-version (in the factory itself: factory/VERSION)
#   max_lines:<glob>    the max_lines of that [[size]] rule in ratchets.toml
#   tests_pass, tests_fail, tests_error, tests_broken, tests_total
#                       the test totals in an evidence file (scripts/evidence.jl): `evidence=<name>`
#                       in the marker (a file in .lanes/evidence/), else the `tests` evidence for
#                       HEAD or its newest ancestor. Evidence is gitignored, so on a machine without
#                       it these claims are reported UNVERIFIED (a failure with --strict).
# Markers inside `inline code` and ``` fences are examples, not claims. A file is checked against
# the checkout it describes: the nearest enclosing directory with .agents/agent-registry.toml
# (so the coordinator's factory/template/CLAUDE.md is checked against the template's registry).
# Config, .agents/factory.toml [check_claims]: `files` (globs of Markdown files to scan; default
# every tracked *.md) and `required` (keys that must have at least one marker).
# Exit 0 = every claim holds, 1 = a mismatch, a missing required key or a bad marker, 2 = could not run.
module CheckClaims

using TOML
include(joinpath(@__DIR__, "_common.jl"))
include(joinpath(@__DIR__, "evidence.jl"))

const MARKER = r"<!--\s*claim:\s*(.*?)\s*-->"
const TEST_KEYS = ("tests_pass", "tests_fail", "tests_error", "tests_broken", "tests_total")
const KEYS = ("max_open", "roles", "factory_version", TEST_KEYS...)

"""
    claims(text) -> Vector of (line, pairs::Vector{Pair}, prose)

Every marker outside code, with its KEY=VALUE pairs and the line's text without markers and code.
"""
function claims(text)
    out = Tuple{Int, Vector{Pair{String, String}}, String}[]
    fenced = false
    for (n, l) in enumerate(split(text, '\n'))
        startswith(lstrip(l), "```") && (fenced = !fenced; continue)
        fenced && continue
        bare = replace(l, r"`[^`]*`" => "")
        prose = replace(bare, MARKER => "")
        for m in eachmatch(r"<!--(.*?)-->", bare)            # 0.2.4 review: a mistyped marker is an error, not prose
            occursin(r"claim"i, m.captures[1]) && !occursin(MARKER, m.match) && push!(out, (n, ["<malformed>" => m.match], prose))
        end
        for m in eachmatch(MARKER, bare)
            pairs = Pair{String, String}[]
            for kv in split(m.captures[1])
                i = findfirst('=', kv)
                push!(pairs, i === nothing ? (kv => "") : (kv[1:i-1] => kv[i+1:end]))
            end
            push!(out, (n, pairs, prose))
        end
    end
    return out
end

"The repo's derived values: a Function key -> value (String) or nothing when it cannot be derived."
function derive(root)
    reg = (p = joinpath(root, ".agents/agent-registry.toml"); isfile(p) ? TOML.parsefile(p) : Dict())
    rat = (p = joinpath(root, "ratchets.toml"); isfile(p) ? TOML.parsefile(p) : Dict())
    rec = try factory_record(root) catch; Dict() end
    version = haskey(rec, "version") ? string(rec["version"]) : nothing
    for d in (joinpath(root, "factory"), normpath(joinpath(root, ".."))) # a checkout holding the factory, or the template
        version === nothing && isfile(joinpath(d, "VERSION")) && isfile(joinpath(d, "MANIFEST.toml")) &&
            (version = String(strip(read(joinpath(d, "VERSION"), String))))
    end
    function value(key)
        key == "max_open" && return string(get(get(reg, "lanes", Dict()), "max_open", 4))
        key == "roles" && return haskey(reg, "agents") ? string(length(reg["agents"])) : nothing
        key == "factory_version" && return version
        if startswith(key, "max_lines:")
            g = chopprefix(key, "max_lines:")
            r = findfirst(s -> get(s, "glob", "") == g, get(rat, "size", Any[]))
            return r === nothing ? nothing : string(rat["size"][r]["max_lines"])
        end
        return nothing
    end
    return value
end

"Test totals from the evidence file `name` (in .lanes/evidence/, `.txt` optional) or the latest `tests` evidence."
function evidence_totals(root, name)
    path = name === nothing ? Evidence.latest(root, "tests") :
           joinpath(Evidence.evidence_dir(root), endswith(name, ".txt") ? name : name * ".txt")
    (path === nothing || !isfile(path)) && return nothing, something(name, "tests evidence for HEAD")
    tt = Evidence.test_totals(Evidence.output(path))
    return tt, relpath(path, root)
end

"The checkout file `f` describes: the nearest directory above it (up to `root`) holding .agents/agent-registry.toml."
function claim_root(root, f)
    d = dirname(f)
    while !isempty(d)
        isfile(joinpath(root, d, ".agents/agent-registry.toml")) && return joinpath(root, d)
        d = dirname(d)
    end
    return root
end

function markdown_files(root, globs)
    files = filter(f -> endswith(f, ".md"), tracked_files(root))
    return sort!(isempty(globs) ? files : filter(f -> any(g -> globmatch(g, f), globs), files))
end

function check(root; strict = false, io = stdout)
    cfg = factory_config(root)
    files = markdown_files(root, config_list(cfg, "check_claims", "files"))
    required = config_list(cfg, "check_claims", "required")
    derived = Dict{String, Function}()
    bad, unverified, seen, n = String[], String[], Set{String}(), 0
    for k in required
        (k in KEYS || startswith(k, "max_lines:")) || push!(bad, ".agents/factory.toml: [check_claims] required key `$k` is unknown")
    end
    for f in files, (line, pairs, prose) in claims(read(joinpath(root, f), String))
        where = "$f:$line"
        croot = claim_root(root, f)
        value = get!(() -> derive(croot), derived, croot)
        ev = nothing
        for (k, v) in pairs
            k == "evidence" && (ev = v)
        end
        for (k, v) in pairs
            k == "evidence" && continue
            k == "<malformed>" && (push!(bad, "$where: malformed claim marker $v (write <!-- claim: key=value -->)"); continue)
            n += 1
            push!(seen, k)
            if !(k in KEYS || startswith(k, "max_lines:"))
                push!(bad, "$where: unknown claim key `$k` (known: $(join(KEYS, ", ")), max_lines:<glob>)")
                continue
            end
            isempty(v) && (push!(bad, "$where: `$k` has no value (write $k=VALUE)"); continue)
            occursin(Regex("(?<![\\w.])\\Q" * replace(v, "\\E" => "") * "\\E(?!\\w)"), prose) ||
                push!(bad, "$where: the text of the line does not state $v (claimed by `$k`)")
            if k in TEST_KEYS
                tt, src = evidence_totals(croot, ev)
                if tt === nothing
                    push!(unverified, "$where: $k=$v UNVERIFIED: no test totals in $src (run `julia scripts/evidence.jl tests -- <test command>`)")
                elseif string(tt[chopprefix(k, "tests_")]) != v
                    push!(bad, "$where: $k=$v but $src says $(tt[chopprefix(k, "tests_")])")
                end
                continue
            end
            want = value(k)
            want === nothing && (push!(bad, "$where: `$k` cannot be derived in this repo"); continue)
            want == v || push!(bad, "$where: $k=$v but the derived value is $want")
        end
    end
    for k in required
        k in seen || push!(bad, "required claim `$k` ([check_claims] in .agents/factory.toml) has no marker in $(isempty(files) ? "any Markdown file" : "the configured files")")
    end
    foreach(u -> println(io, "  [UNVERIFIED] ", u), unverified)
    foreach(b -> println(io, "  [FAIL] ", b), bad)
    strict && append!(bad, unverified)
    println(io, isempty(bad) ? "check_claims.jl: OK ($n claims in $(length(files)) files$(isempty(unverified) ? "" : ", $(length(unverified)) unverified"))" :
                "check_claims.jl: FAILED ($(length(bad)))")
    return isempty(bad)
end

function main(args; io = stdout)
    opts, _ = try
        parse_args(args, ("--strict",), ("--root",))
    catch e
        println(stderr, "check_claims.jl: ", e isa ErrorException ? e.msg : e)
        return 2
    end
    root = abspath(get(opts, "--root", normpath(joinpath(@__DIR__, ".."))))
    try
        return check(root; strict = get(opts, "--strict", false), io) ? 0 : 1
    catch e
        println(stderr, "check_claims.jl: ", e isa ErrorException ? e.msg : sprint(showerror, e))
        return 2
    end
end

end # module

abspath(PROGRAM_FILE) == @__FILE__() && exit(CheckClaims.main(ARGS))
