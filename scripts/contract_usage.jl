#!/usr/bin/env julia
# contract_usage.jl: does test/contracts/ match the contract IDs this package relies on?
#
#   julia scripts/contract_usage.jl [--root DIR] [--contracts DIR] [--strict]
#
# Sources (contracts/README.md "How downstream repos mirror contracts", ADR-0010 rule 1):
#   test/contracts/USED.md         one line per relied-on ID: `- CC-004` (optional ` — note`)
#   test/contracts/*.jl            one `@testitem "<ID> ..."` per listed ID
#   test/contracts/upstreams.toml  [upstreams] name = git URL; [contract_files] name = path of
#                                  the upstream's contract file (a copy of the coordinator's
#                                  contracts/<pkg>.md, refreshed by /contract-check)
#   src/, ext/                     qualified upstream names: `Up.x`, `Up.:⨟`, `using/import Up: x`
# Checks (E = error, W = warning):
#   E  a listed ID has no test item, or more than one; a contract test item's ID is not listed;
#      a test item named after an ID is not tagged `:contract` (ci.jl contracts would skip it)
#   E  a contract test item uses @test_skip/@test_broken (an ID is tested for real or not listed)
#   E  a listed ID is not in any contract file, or is `status=retired`;   W  `status=deprecated`
#   E  a used name maps (via the contracts' `names:` lines) to an ID that USED.md does not list
#   W  a used name no stable/deprecated entry's `names:` line covers (PROVISIONAL or unpromised
#      API); an error with --strict
#   E  an upstream whose names are used has no contract file
#   E  a contract file entry has no `since=... status=...` line, or its ID appears twice
# Upstreams grepped: the keys of [upstreams] and of [contract_files] (a package may vendor a
# contract file before the upstream has a URL). Commented-out code (`#`, `#= =#`) is ignored.
# --contracts DIR reads each contract file from DIR/<basename> instead (e.g. the coordinator's
# contracts/ while working inside it). Entry headers: `### <ID> <title>` then `since=... status=...`.
# Exit 0 = no errors (or no test/contracts/USED.md: skipped), 1 = errors, 2 = usage error.
module ContractUsage

    using TOML
    include(joinpath(@__DIR__, "_common.jl"))

    const IDPAT = "C[A-Z]{1,2}-\\d{3}"
    const HEADER = Regex("^### ($IDPAT) (.+)\$")
    const STATUS = r"since=\S+\s+status=(stable|deprecated|retired)(?![\w-])"

    "Markdown without HTML comments and fenced code blocks, as lines."
    function prose_lines(md)
        md = replace(md, r"<!--.*?-->"s => "")
        out = String[]
        fence = nothing # the opening fence while inside a block; closed only by the same character, at least as long
        for line in split(md, '\n')
            m = match(r"^\s{0,3}(`{3,}|~{3,})", line)
            if m !== nothing && (
                    fence === nothing ||
                        (m.captures[1][1] == fence[1] && length(m.captures[1]) >= length(fence))
                )
                fence = fence === nothing ? m.captures[1] : nothing
                push!(out, "")
                continue
            end
            push!(out, fence === nothing ? String(line) : "")
        end
        return out
    end

    "IDs listed in USED.md, from bullet lines `- <ID> [— note]`, in order."
    parse_used(md) = unique!(
        [
            m.captures[1] for l in prose_lines(md)
                for m in (match(Regex("^\\s*[-*]\\s+($IDPAT)\\b"), l),) if m !== nothing
        ]
    )

    "Normalise `Up.:⨟`, `Up.:(⨟)`, `Up.(⨟)` and `Up.⨟` to `Up.⨟`."
    normname(q) = replace(replace(strip(q), r"\.:" => "."), r"\.\(([^()\s]+)\)$" => s".\1")

    """
        parse_contract(md) -> Dict(ID => (status, names::Vector{String}))

    Entries are `### <ID> <title>` followed by a `since=... status=...` line; `names:` lines inside
    an entry list its qualified names in backticks. An entry ends at the next `#`/`##`/`###` heading,
    so PROVISIONAL sections (no IDs) contribute nothing. A header without the status line is
    recorded with status "invalid"; an ID whose header appears twice, with status "duplicate".
    """
    function parse_contract(md)
        entries = Dict{String, Tuple{String, Vector{String}}}()
        lines = prose_lines(md)
        cur = nothing
        for (i, l) in enumerate(lines)
            m = match(HEADER, l)
            if m !== nothing
                cur = m.captures[1]
                nxt = i < length(lines) ? lines[i + 1] : ""
                s = match(STATUS, nxt)
                if haskey(entries, cur)
                    entries[cur] = ("duplicate", entries[cur][2])
                    cur = nothing
                    continue
                end
                entries[cur] = (s === nothing ? "invalid" : s.captures[1], String[])
                continue
            end
            if occursin(r"^#{1,4} ", l)
                startswith(l, "#### ") || (cur = nothing)  # #### sub-headings stay inside an entry
                continue
            end
            if cur !== nothing && occursin(r"^\s*names:", l)
                for t in eachmatch(r"`([^`]+)`", l)
                    push!(entries[cur][2], normname(t.captures[1]))
                end
            end
        end
        return entries
    end

    "`code` with `#= =#` block comments blanked (newlines kept, so line numbers hold)."
    strip_block_comments(code) = replace(code, r"#=.*?=#"s => m -> repeat("\n", count(==('\n'), m)))

    """
        test_items(root) -> (found, skips, untagged)

    `found`: ID => [file:line, ...] for every `@testitem "<ID> ..."` outside comments; `skips`: lines
    with `@test_skip`/`@test_broken`; `untagged`: ID-named items whose line has no `:contract` tag.
    """
    function test_items(root)
        dir = joinpath(root, "test/contracts")
        found = Dict{String, Vector{String}}()
        skips, untagged = String[], String[]
        isdir(dir) || return found, skips, untagged
        for (r, _, fs) in walkdir(dir), f in fs
            endswith(f, ".jl") || continue
            p = joinpath(r, f)
            for (n, line) in enumerate(split(strip_block_comments(read(p, String)), '\n'))
                occursin(r"^\s*#", line) && continue                # a commented-out line
                where = "$(relpath(p, root)):$n"
                m = match(Regex("@testitem\\s+\"($IDPAT)\\b"), line)
                if m !== nothing
                    push!(get!(found, m.captures[1], String[]), where)
                    occursin(r"\btags\s*=\s*\[[^\]]*:contract\b", line) || push!(untagged, "$where ($(m.captures[1]))")
                end
                occursin(r"@test_(skip|broken)\b", replace(line, r"#.*$" => "")) && push!(skips, where)
            end
        end
        return found, skips, untagged
    end

    const NAME = raw"(:?[\p{L}_][\p{L}\p{N}_!]*|:?\([^\s()]+\)|:?[^\s\w\(\)\[\]\{\},;.:'\"=`#$@]+)"

    "Qualified names (normalised) used in Julia `code` for each upstream in `ups`; comments skipped."
    function used_names(code, ups)
        names = Set{String}()
        for line in split(strip_block_comments(code), '\n')
            line = replace(line, r"#.*$" => "")
            for up in ups
                for m in eachmatch(Regex("\\b(?:using|import)\\s+$up\\s*:\\s*([^;]+)"), line)
                    for n in split(m.captures[1], ',')
                        n = strip(replace(n, r"\s+as\s+.*$" => ""))
                        isempty(n) || push!(names, normname("$up." * replace(n, r"^:?\((.+)\)$" => s"\1")))
                    end
                end
                for m in eachmatch(Regex("(?<![\\w.])$up\\." * NAME), line)
                    push!(names, normname("$up.$(m.captures[1])"))
                end
            end
        end
        return names
    end

    function code_names(root, ups)
        names = Set{String}()
        for d in ("src", "ext")
            isdir(joinpath(root, d)) || continue
            for (r, _, fs) in walkdir(joinpath(root, d)), f in fs
                endswith(f, ".jl") && union!(names, used_names(read(joinpath(r, f), String), ups))
            end
        end
        return names
    end

    """
        check(root; contracts = nothing, strict = false) -> (errors, warnings, summary) or `nothing`
    """
    function check(root; contracts = nothing, strict = false)
        used_md = joinpath(root, "test/contracts/USED.md")
        isfile(used_md) || return nothing
        errors, warnings = String[], String[]
        ids = parse_used(read(used_md, String))
        tests, skips, untagged = test_items(root)
        upf = joinpath(root, "test/contracts/upstreams.toml")
        up = isfile(upf) ? TOML.parsefile(upf) : Dict{String, Any}()
        files = get(up, "contract_files", Dict{String, Any}())
        ups = sort!(collect(union(keys(get(up, "upstreams", Dict())), keys(files))))
        # 1. USED.md <-> test items
        for id in ids
            n = length(get(tests, id, String[]))
            n == 0 && push!(errors, "$id is listed in USED.md but has no `@testitem \"$id ...\"` in test/contracts/")
            n > 1 && push!(errors, "$id has $n contract test items (exactly one expected): $(join(tests[id], ", "))")
        end
        for id in sort!(collect(keys(tests)))
            id in ids || push!(errors, "$id has a contract test item ($(join(tests[id], ", "))) but is not listed in USED.md")
        end
        for w in skips
            push!(errors, "$w: @test_skip/@test_broken in a contract test; an ID is tested for real or not listed")
        end
        for w in untagged
            push!(errors, "$w: contract test item not tagged `:contract` (`tags = [:contract]`); ci.jl contracts runs only those")
        end
        # 2. USED.md <-> contracts
        entries = Dict{String, Tuple{String, Vector{String}}}()
        for name in sort!(collect(keys(files)))
            rel = string(files[name])
            p = contracts === nothing ? joinpath(root, rel) : joinpath(contracts, basename(rel))
            if !isfile(p)
                push!(errors, "contract file for $name not found: $p")
                continue
            end
            merge!(entries, parse_contract(read(p, String)))
        end
        for id in ids
            st = haskey(entries, id) ? entries[id][1] : nothing
            st === nothing && push!(errors, "$id is listed in USED.md but is in no contract file ($(isempty(files) ? "none configured in [contract_files]" : join(values(files), ", ")))")
            st == "retired" && push!(errors, "$id is status=retired; move to its replacement entry")
            st == "duplicate" && push!(errors, "$id has two entries in the contract files; fix the contract (the coordinator's contracts/)")
            st == "invalid" && push!(errors, "$id's header is not followed by a `since=... status=...` line in its contract file")
            st == "deprecated" && push!(warnings, "$id is status=deprecated; plan the move before the breaking release")
        end
        # 3. code <-> USED.md, through the names: lines of stable and deprecated entries
        byname = Dict{String, Vector{String}}()
        for (id, (st, ns)) in entries, n in ns
            st in ("stable", "deprecated") && push!(get!(byname, n, String[]), id)
        end
        names = code_names(root, ups)
        for q in sort!(collect(names))
            upname = q[1:(findfirst('.', q) - 1)]
            if !haskey(files, upname)
                push!(errors, "$q is used but $upname has no contract file in test/contracts/upstreams.toml [contract_files]")
                continue
            end
            mapped = sort!(get(byname, q, String[]))
            if isempty(mapped)
                msg = "$q is used but no stable entry's names: line covers it (PROVISIONAL or unpromised API)"
                push!(strict ? errors : warnings, msg)
            end
            for id in mapped
                id in ids || push!(errors, "$q is covered by $id, which USED.md does not list")
            end
        end
        summary = "$(length(ids)) IDs listed, $(length(tests)) tested, $(length(names)) upstream names used"
        return errors, warnings, summary
    end

    function main(args)
        opts, _ = try
            parse_args(args, ("--strict",), ("--root", "--contracts"))
        catch e
            println(stderr, "contract_usage.jl: ", e isa ErrorException ? e.msg : e)
            return 2
        end
        root = abspath(get(opts, "--root", normpath(joinpath(@__DIR__, ".."))))
        contracts = haskey(opts, "--contracts") ? abspath(opts["--contracts"]) : nothing
        r = check(root; contracts, strict = get(opts, "--strict", false))
        if r === nothing
            println("contract_usage.jl: skipped (no test/contracts/USED.md)")
            return 0
        end
        errors, warnings, summary = r
        foreach(e -> println("  ERROR ", e), errors)
        foreach(w -> println("  warn  ", w), warnings)
        println(
            isempty(errors) ? "contract_usage.jl: OK ($summary; $(length(warnings)) warnings)" :
                "contract_usage.jl: $(length(errors)) errors, $(length(warnings)) warnings ($summary)"
        )
        return isempty(errors) ? 0 : 1
    end

end # module

abspath(PROGRAM_FILE) == @__FILE__() && exit(ContractUsage.main(ARGS))
