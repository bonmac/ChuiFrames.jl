#!/usr/bin/env julia
# sync_factory.jl: pull a factory version into a repo, deliberately.
#
#   julia scripts/sync_factory.jl --from <coordinator>/factory [--to DIR]
#         [--profile package|coordinator] [--apply] [--force]
#
# Without --apply it is a dry run: it prints the plan and the diff of every file that would
# change. With --apply it writes the files, records the version and per-file hashes in
# .factory-version, and runs `julia scripts/gen.jl` to rebuild generated files.
# A managed file the repo edited since the last sync is a CONFLICT: shown, and --apply
# refuses until it is resolved (or --force overwrites it). Seeded files are never updated
# after the first copy. Files the factory dropped are reported, never deleted.
# Bootstrap a new repo: julia <factory>/template/scripts/sync_factory.jl --from <factory> --to <repo> --apply
#
# A MANIFEST profile may set:
#   exclude  template paths (globs) the profile does not take
#   overlay  a directory under the factory whose files replace (or add to) template files
#            for that profile, e.g. profiles/coordinator/.agents/factory.toml
#   adr_dir  where the repo keeps ADRs (default docs/adr): template docs/adr/* lands there,
#            "docs/adr/" in seeded files and managed *.md files is rewritten to it, and it is
#            recorded in .factory-version for scripts/dod.jl.
module SyncFactory

using TOML, SHA
include(joinpath(@__DIR__, "_common.jl"))

sha(path) = bytes2hex(open(sha256, path))
anymatch(globs, rel) = any(g -> globmatch(g, rel), globs)

# Runtime scratch that hooks and lanes write (the template's .gitignore "lanes and agent
# scratch" block). A session rooted in factory/template writes .lanes/ there; never ship it.
const RUNTIME = (".lanes/", ".worktrees/", ".superpowers/", ".claude/worktrees/", ".claude/settings.local.json")

function template_files(tdir)
    files = String[]
    isdir(tdir) || return files
    for (r, _, fs) in walkdir(tdir), f in fs
        f == ".DS_Store" && continue
        rel = relpath(joinpath(r, f), tdir)
        any(p -> startswith(rel, p), RUNTIME) && continue
        push!(files, rel)
    end
    return sort!(files)
end

const DEFAULT_ADR = "docs/adr"

"One file the factory offers: repo path `rel`, its rendered bytes, and whether it is seeded."
struct Source
    rel::String
    bytes::Vector{UInt8}
    seeded::Bool
end

"""
    sources(from, profile) -> (Vector{Source}, adr_dir)

Every file the profile takes: template files minus `exclude` and generated files, with the
profile's overlay files on top, `docs/adr/` remapped to `adr_dir` and rewritten in text.
"""
function sources(from, profile)
    man = TOML.parsefile(joinpath(from, "MANIFEST.toml"))
    seeded = get(man["seeded"], "paths", String[])
    generated = get(man["generated"], "paths", String[])
    haskey(man["profiles"], profile) || error("unknown profile `$profile`")
    prof = man["profiles"][profile]
    for k in keys(prof)
        k in ("exclude", "overlay", "adr_dir") || error("MANIFEST profile `$profile`: unknown key `$k`")
    end
    exclude = get(prof, "exclude", String[])
    adr = rstrip(get(prof, "adr_dir", DEFAULT_ADR), '/')
    tdir = joinpath(from, "template")
    picked = Dict{String, String}() # template-relative path => file on disk
    for rel in template_files(tdir)
        (anymatch(exclude, rel) || anymatch(generated, rel)) && continue
        picked[rel] = joinpath(tdir, rel)
    end
    if haskey(prof, "overlay")
        odir = joinpath(from, prof["overlay"])
        isdir(odir) || error("MANIFEST profile `$profile`: overlay `$(prof["overlay"])` is not a directory")
        for rel in template_files(odir)
            anymatch(generated, rel) && error("overlay file $rel is a generated path")
            picked[rel] = joinpath(odir, rel)
        end
    end
    out = Source[]
    for rel in sort!(collect(keys(picked)))
        isseed = rel in seeded
        bytes = read(picked[rel])
        dst = rel
        if adr != DEFAULT_ADR
            startswith(rel, DEFAULT_ADR * "/") && (dst = adr * rel[length(DEFAULT_ADR)+1:end])
            if (isseed || endswith(rel, ".md")) && isvalid(String, bytes)
                bytes = Vector{UInt8}(replace(String(bytes), DEFAULT_ADR * "/" => adr * "/"))
            end
        end
        push!(out, Source(dst, bytes, isseed))
    end
    return out, adr
end

"""
    plan(from, to, profile, record; force) -> Vector of (action, rel)

Actions: add, update, same, conflict, local-modified, seed, seeded-differs, now-seeded,
removed-upstream.
`local-modified`: the repo edited a managed file the factory did not change; it is kept as is.
`now-seeded`: a file recorded as managed that the factory now seeds; it is dropped from the
managed record (the repo owns it from now on) and its own seed/same/seeded-differs step says
how it compares.
"""
function plan(from, to, profile, record; force = false)
    srcs, _ = sources(from, profile)
    recorded = get(record, "managed", Dict{String, Any}())
    steps = Tuple{String, String}[]
    seen = Set{String}()
    for s in srcs
        rel, dst, isseed = s.rel, joinpath(to, s.rel), s.seeded
        isseed || push!(seen, rel)
        action = if !isfile(dst)
            isseed ? "seed" : "add"
        elseif s.bytes == read(dst)
            "same"
        elseif isseed
            "seeded-differs"
        elseif get(recorded, rel, nothing) == sha(dst) || force
            "update"
        elseif get(recorded, rel, nothing) == bytes2hex(sha256(s.bytes))
            "local-modified"
        else
            "conflict"
        end
        push!(steps, (action, rel))
    end
    nowseeded = Set(s.rel for s in srcs if s.seeded)
    for rel in sort!(collect(keys(recorded)))
        rel in seen && continue
        # a managed file the factory now seeds is still offered (as seed/same/seeded-differs
        # above); it just leaves the managed record and becomes repo-owned
        push!(steps, (rel in nowseeded ? "now-seeded" : "removed-upstream", rel))
    end
    return steps
end

function showdiff(io, a, b)
    out = IOBuffer()
    run(pipeline(ignorestatus(`git diff --no-index --no-color -- $a $b`); stdout = out, stderr = devnull))
    print(io, String(take!(out)))
end

function apply!(from, to, profile, steps, version, recorded)
    srcs, adr = sources(from, profile)
    bysrc = Dict(s.rel => s for s in srcs)
    modes = source_modes(from, profile)
    for (action, rel) in steps
        if action == "same" && filemode(joinpath(to, rel)) & 0o777 != modes[rel] # a mode-only change
            chmod(joinpath(to, rel), modes[rel])
        end
        action in ("add", "update", "seed") || continue
        dst = joinpath(to, rel)
        mkpath(dirname(dst))
        write(dst, bysrc[rel].bytes)
        chmod(dst, modes[rel])
    end
    managed = Dict{String, String}()
    for (action, rel) in steps # seeded files are repo-owned, so only managed ones are hashed
        action in ("add", "update", "same") && !bysrc[rel].seeded && (managed[rel] = sha(joinpath(to, rel)))
        action == "local-modified" && (managed[rel] = recorded[rel]) # still the factory's hash
    end
    rec = Dict("version" => version, "profile" => profile, "synced" => string(Dates_today()), "adr_dir" => adr,
               "source_commit" => something(git(from, "rev-parse", "HEAD"), "unknown"),
               "managed" => managed)
    open(joinpath(to, ".factory-version"), "w") do io
        println(io, "# Written by scripts/sync_factory.jl. Do not edit by hand.")
        TOML.print(io, rec; sorted = true)
    end
end

"Permission bits of each source file, keyed by repo path (keeps scripts/lane executable)."
function source_modes(from, profile)
    man = TOML.parsefile(joinpath(from, "MANIFEST.toml"))
    prof = man["profiles"][profile]
    adr = rstrip(get(prof, "adr_dir", DEFAULT_ADR), '/')
    modes = Dict{String, UInt16}()
    dirs = [joinpath(from, "template")]
    haskey(prof, "overlay") && push!(dirs, joinpath(from, prof["overlay"]))
    for d in dirs, rel in template_files(d)
        dst = (adr != DEFAULT_ADR && startswith(rel, DEFAULT_ADR * "/")) ? adr * rel[length(DEFAULT_ADR)+1:end] : rel
        modes[dst] = filemode(joinpath(d, rel)) & 0o777
    end
    return modes
end
Dates_today() = Base.Libc.strftime("%Y-%m-%d", time())

function main(args; io = stdout)
    opts, _ = try
        parse_args(args, ("--apply", "--force"), ("--from", "--to", "--profile"))
    catch e
        println(stderr, "sync_factory.jl: ", e isa ErrorException ? e.msg : e)
        return 2
    end
    haskey(opts, "--from") || (println(stderr, "sync_factory.jl: --from <factory dir> is required"); return 2)
    from = abspath(opts["--from"])
    to = abspath(get(opts, "--to", pwd()))
    isfile(joinpath(from, "VERSION")) || (println(stderr, "sync_factory.jl: $from has no VERSION"); return 2)
    version = strip(read(joinpath(from, "VERSION"), String))
    recpath = joinpath(to, ".factory-version")
    record = isfile(recpath) ? TOML.parsefile(recpath) : Dict{String, Any}()
    profile = get(opts, "--profile", get(record, "profile", "package"))
    steps = plan(from, to, profile, record; force = get(opts, "--force", false))
    println(io, "sync_factory: $(get(record, "version", "none")) -> $version ($profile) into $to")
    bysrc = Dict(s.rel => s for s in first(sources(from, profile)))
    for (action, rel) in steps
        action == "same" && continue
        println(io, "  ", rpad(action, 17), rel)
        if action in ("update", "conflict", "local-modified", "seeded-differs")
            tmp = tempname()
            write(tmp, bysrc[rel].bytes) # the rendered file, as it would be written
            showdiff(io, joinpath(to, rel), tmp)
            rm(tmp; force = true)
        end
    end
    counts = Dict{String, Int}()
    foreach(s -> counts[s[1]] = get(counts, s[1], 0) + 1, steps)
    println(io, "sync_factory: ", join(("$k=$v" for (k, v) in sort!(collect(counts))), " "))
    nconf = get(counts, "conflict", 0)
    if !get(opts, "--apply", false)
        println(io, "sync_factory: dry run; re-run with --apply to write.")
        return nconf == 0 ? 0 : 1
    end
    nconf > 0 && (println(io, "sync_factory: $nconf conflicts (local edits to managed files); resolve them or pass --force."); return 1)
    apply!(from, to, profile, steps, version, get(record, "managed", Dict{String, Any}()))
    println(io, "sync_factory: applied; recorded $version in .factory-version")
    gen = joinpath(to, "scripts", "gen.jl")
    if isfile(gen)
        ok = success(pipeline(Cmd([Base.julia_cmd().exec; "--startup-file=no"; gen; "--root"; to]); stdout = io, stderr))
        ok || (println(io, "sync_factory: gen.jl failed; fix the sources and run it again."); return 1)
    end
    return 0
end

end # module

abspath(PROGRAM_FILE) == @__FILE__() && exit(SyncFactory.main(ARGS))
