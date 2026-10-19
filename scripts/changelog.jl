#!/usr/bin/env julia
# changelog.jl: changelog fragments (factory 0.2.4).
#
#   julia scripts/changelog.jl list [--root DIR]               the fragments waiting to be folded
#   julia scripts/changelog.jl fold [--root DIR] [--dry-run]   fold them into CHANGELOG.md
#
# A lane records its change as a NEW file `changelog.d/<lane>.md` (Markdown list items, e.g.
# `- feat: add X (#12)`) instead of editing CHANGELOG.md, so lanes in one repo never share a
# file; `scripts/dod.jl` accepts an added fragment as the `changelog` evidence. At release the
# release manager runs `fold`: every fragment, sorted by file name, is appended under
# `## Unreleased` (created after the intro when missing) and the fragment files are deleted.
# `changelog.d/README.md` and dotfiles (`.gitkeep`) are never fragments. An empty fragment, or
# one with a Markdown heading, is an error: nothing is written.
# Exit 0 = done, 1 = a bad fragment, 2 = usage or missing CHANGELOG.md.
module Changelog

    include(joinpath(@__DIR__, "_common.jl"))

    const DIR = "changelog.d"

    "Fragment paths (repo-relative), sorted by name."
    function fragments(root)
        d = joinpath(root, DIR)
        isdir(d) || return String[]
        return sort!(
            [
                "$DIR/$f" for f in readdir(d) if endswith(f, ".md") && f != "README.md" &&
                    !startswith(f, ".") && isfile(joinpath(d, f))
            ]
        )
    end

    "Problems with the fragments: empty, or holding a heading (which would split the section)."
    function problems(root, frags)
        bad = String[]
        for f in frags
            t = strip(read(joinpath(root, f), String))
            isempty(t) && push!(bad, "$f is empty")
            any(l -> occursin(r"^\s{0,3}#{1,6}(\s|$)", l), split(t, '\n')) && push!(bad, "$f contains a Markdown heading; write list items only")
        end
        return bad
    end

    """
        fold_text(changelog, entries) -> String

    Insert `entries` (text blocks) at the end of the `## Unreleased` section of `changelog`,
    creating the section before the first `## ` heading (or at the end) when it is missing.
    """
    function fold_text(changelog::AbstractString, entries::Vector{<:AbstractString})
        lines = split(chomp(changelog), '\n')
        block = split(join(strip.(entries), '\n'), '\n')
        u = findfirst(l -> occursin(r"^## +\[?Unreleased\]?\s*$"i, l), lines)   # also Keep a Changelog's `## [Unreleased]`
        if u === nothing
            h = findfirst(l -> startswith(l, "## "), lines)
            at = h === nothing ? length(lines) + 1 : h
            new = ["## Unreleased", "", block..., ""]
            h === nothing && (new = ["", new[1:(end - 1)]...])
            return join([lines[1:(at - 1)]; new; lines[at:end]], '\n') * "\n"
        end
        nxt = findnext(l -> startswith(l, "## "), lines, u + 1)
        stop = nxt === nothing ? length(lines) : nxt - 1
        while stop > u && isempty(strip(lines[stop]))   # insert after the section's last entry
            stop -= 1
        end
        tail = nxt === nothing ? String[] : ["", lines[nxt:end]...]
        return join([lines[1:stop]; (stop == u ? [""] : String[]); block; tail], '\n') * "\n"
    end

    function main(args; io = stdout)
        opts, pos = try
            parse_args(args, ("--dry-run",), ("--root",))
        catch e
            println(stderr, "changelog.jl: ", e isa ErrorException ? e.msg : e)
            return 2
        end
        root = abspath(get(opts, "--root", normpath(joinpath(@__DIR__, ".."))))
        length(pos) == 1 && pos[1] in ("list", "fold") ||
            (println(stderr, "usage: julia scripts/changelog.jl list|fold [--root DIR] [--dry-run]"); return 2)
        frags = fragments(root)
        if pos[1] == "list"
            foreach(f -> println(io, f), frags)
            println(io, "changelog.jl: $(length(frags)) fragment(s) in $DIR/")
            return 0
        end
        cl = joinpath(root, "CHANGELOG.md")
        isfile(cl) || (println(stderr, "changelog.jl: no CHANGELOG.md in $root"); return 2)
        isempty(frags) && (println(io, "changelog.jl: no fragments to fold"); return 0)
        bad = problems(root, frags)
        isempty(bad) || (foreach(b -> println(io, "  FAIL ", b), bad); println(io, "changelog.jl: nothing folded"); return 1)
        text = fold_text(read(cl, String), [read(joinpath(root, f), String) for f in frags])
        if get(opts, "--dry-run", false)
            print(io, text)
            println(io, "changelog.jl: --dry-run, would fold $(length(frags)) fragment(s)")
            return 0
        end
        write(cl, text)
        foreach(f -> rm(joinpath(root, f)), frags)
        println(io, "changelog.jl: folded $(length(frags)) fragment(s) into CHANGELOG.md under ## Unreleased: ", join(frags, ", "))
        return 0
    end

end # module

abspath(PROGRAM_FILE) == @__FILE__() && exit(Changelog.main(ARGS))
