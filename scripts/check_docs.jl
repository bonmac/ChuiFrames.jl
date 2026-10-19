#!/usr/bin/env julia
# check_docs.jl: cheap doc-reference checker.
#
#   julia scripts/check_docs.jl [--root DIR] [--config FILE] [--external a.md,b/*]
#
# For every tracked *.md file (generated ones included) it checks that
#   - relative Markdown links [text](path) resolve, relative to the file;
#   - backticked repo paths (tokens starting with a known top-level directory such as
#     `scripts/`, `docs/`, `.claude/`) exist, relative to the repo root.
# Skipped: URLs, anchors, and tokens with placeholders (< > * { } $ YYYY ...).
# --external lists paths provided by someone else (e.g. the lead copies docs/agent/*.md).
# Repo-owned settings live in .agents/factory.toml [check_docs] (seeded per profile):
#   exclude        globs of Markdown files not checked (e.g. "research/**")
#   external       globs of references allowed to be missing (merged with --external)
#   ignore_fenced  skip references inside ``` / ~~~ fenced code blocks
# --config FILE reads those settings from FILE instead (e.g. to try a profile's defaults).
# In a checkout that holds the factory (factory/MANIFEST.toml, i.e. the coordinator), files
# under factory/ document the template, so their backticked paths also resolve against
# factory/template/ (`docs/adr/` there is the template's, not the repo's).
# Globs follow risk.toml: `*` matches any characters including `/`.
# Exit 0 = all references resolve, 1 = stale references.
module CheckDocs

using TOML
include(joinpath(@__DIR__, "_common.jl"))

const PREFIXES = ("scripts/", "docs/", ".claude/", ".agents/", ".github/", ".codex/",
                  "test/", "src/", "ext/", "benchmark/")
const SKIP_DIRS = (".worktrees/", ".lanes/", ".superpowers/", "docs/build/")
# Layout conventions the factory docs name before a package has created them.
const CONVENTIONS = Set(["src", "ext", "benchmark/benchmarks.jl", "test/snapshots", "test/differential/fixtures",
                         "test/laws", "test/property", "docs/src", "docs/make.jl", ".agents/checks.local.toml"])

placeholder(t) = occursin(r"[<>*{}$|]|YYYY|\.\.\.", t)

"""
Return (line, reference) pairs in `text` that fail to resolve. `external` holds exact paths or
globs; `also` lists further directories a backticked path (not a link) may resolve against.
"""
function stale(root, mdrel, text; external = Set{String}(), ignore_fenced = false, also = String[])
    bad = Tuple{Int, String}[]
    # `dir/*` also covers a bare `dir/` reference (it is rstripped to `dir` below)
    ext(rel) = rel in external || any(g -> occursin('*', g) && (globmatch(g, rel) || globmatch(g, rel * "/")), external)
    exists(rel; roots = [root]) = ext(rel) || rel in CONVENTIONS || any(r -> ispath(joinpath(r, rel)), roots)
    fence = nothing # the opening fence (``` or ~~~, possibly longer) while inside a block
    for (n, line) in enumerate(split(text, '\n'))
        if ignore_fenced
            m = match(r"^\s{0,3}(`{3,}|~{3,})", line)
            if fence === nothing
                m === nothing || (fence = m.captures[1]; continue)
            else
                (m !== nothing && m.captures[1][1] == fence[1] && length(m.captures[1]) >= length(fence) &&
                 isempty(strip(line[m.offsets[1] + length(m.captures[1]):end]))) && (fence = nothing)
                continue
            end
        end
        for m in eachmatch(r"\]\(([^)\s]+)\)", line)
            t = m.captures[1]
            (occursin(r"^[a-z]+:", t) || startswith(t, "#") || placeholder(t)) && continue
            t = split(t, '#')[1]
            rel = normpath(joinpath(dirname(mdrel), t))
            exists(rstrip(rel, '/')) || push!(bad, (n, t))
        end
        for m in eachmatch(r"`([^`]+)`", line), tok in split(m.captures[1])
            tok = rstrip(tok, ['.', ',', ':', ';', ')'])
            tok = replace(tok, r":\d+(-\d+)?$" => "")
            any(p -> startswith(tok, p), PREFIXES) || continue
            placeholder(tok) && continue
            exists(rstrip(tok, '/'); roots = [root; also]) || push!(bad, (n, tok))   # links never use `also`
        end
    end
    return bad
end

function main(args)
    opts, _ = try
        parse_args(args, (), ("--root", "--external", "--config"))
    catch e
        println(stderr, "check_docs.jl: ", e isa ErrorException ? e.msg : e)
        return 2
    end
    root = abspath(get(opts, "--root", normpath(joinpath(@__DIR__, ".."))))
    cfg = try
        haskey(opts, "--config") ? factory_config(dirname(abspath(opts["--config"])), basename(opts["--config"])) :
            factory_config(root)
    catch e
        println(stderr, "check_docs.jl: ", e isa ErrorException ? e.msg : sprint(showerror, e))
        return 2
    end
    external = Set(filter!(!isempty, String.(split(get(opts, "--external", ""), ','))))
    union!(external, config_list(cfg, "check_docs", "external"))
    exclude = config_list(cfg, "check_docs", "exclude")
    ignore_fenced = get(get(cfg, "check_docs", Dict()), "ignore_fenced", false) === true
    tmpl = joinpath(root, "factory", "template")
    factory_also = isfile(joinpath(root, "factory", "MANIFEST.toml")) && isdir(tmpl) ? [tmpl] : String[]
    total = 0
    nfiles = 0
    nexcl = 0
    for f in sort!(tracked_files(root))
        endswith(f, ".md") || continue
        any(d -> startswith(f, d), SKIP_DIRS) && continue
        isfile(joinpath(root, f)) || continue
        any(g -> globmatch(g, f), exclude) && (nexcl += 1; continue)
        nfiles += 1
        also = startswith(f, "factory/") ? factory_also : String[]
        for (n, ref) in stale(root, f, read(joinpath(root, f), String); external, ignore_fenced, also)
            println("  $f:$n: missing `$ref`")
            total += 1
        end
    end
    skipped = nexcl == 0 ? "" : ", $nexcl excluded by [check_docs] exclude"
    println(total == 0 ? "check_docs.jl: OK ($nfiles files$skipped)" : "check_docs.jl: $total stale references ($nfiles files$skipped)")
    return total == 0 ? 0 : 1
end

end # module

abspath(PROGRAM_FILE) == @__FILE__() && exit(CheckDocs.main(ARGS))
