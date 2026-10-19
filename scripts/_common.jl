# _common.jl: helpers shared by the factory scripts. `include`d, never run. Stdlib only.

"""
    globmatch(glob, path) -> Bool

Match `path` (relative, `/`-separated) against `glob` with sh `case` semantics, which is the
rule documented in risk.toml and ratchets.toml: `*` matches any run of characters INCLUDING
`/`, `?` matches one character, everything else is literal. Same as write_guard.sh.
"""
function globmatch(glob::AbstractString, path::AbstractString)
    io = IOBuffer()
    print(io, "^")
    for c in glob
        if c == '*'
            print(io, ".*")
        elseif c == '?'
            print(io, ".")
        elseif c in raw"\.^$+()[]{}|"
            print(io, '\\', c)
        else
            print(io, c)
        end
    end
    print(io, "\$")
    return occursin(Regex(String(take!(io))), path)
end

"Run a git command in `dir`; return stdout (chomped) or `nothing` on failure."
function git(dir, args...; strict = false)
    out = IOBuffer()
    err = IOBuffer()
    ok = success(pipeline(Cmd(`git -C $dir $args`; ignorestatus = true); stdout = out, stderr = err))
    if !ok
        strict && error("git $(join(args, ' ')) failed: $(String(take!(err)))")
        return nothing
    end
    return chomp(String(take!(out)))
end

"The merge base of `head` with `base`; tries `origin/<base>` first. `nothing` if none."
function merge_base(dir, base, head = "HEAD")
    for b in (startswith(base, "origin/") ? (base,) : ("origin/$base", base))
        mb = git(dir, "merge-base", b, head)
        mb === nothing || return mb
    end
    return nothing
end

"Files under `dir` that git tracks or would track (not ignored); a directory walk outside a repo."
function tracked_files(dir)
    out = git(dir, "ls-files", "--cached", "--others", "--exclude-standard")
    out === nothing || return filter!(!isempty, split(out, '\n'))
    files = String[]
    for (r, _, fs) in walkdir(dir), f in fs
        push!(files, relpath(joinpath(r, f), dir))
    end
    return files
end

"Julia environment variables inherited from a parent shell that make a lane or a CI job resolve the wrong project (0.2.4)."
const LEAKY_ENV = ("JULIA_PROJECT", "JULIA_LOAD_PATH", "JULIA_DEPOT_PATH")
env_warnings() = ["$k=$(ENV[k]) is set in this environment and is inherited by everything started from here. Unset it unless you mean it."
                  for k in LEAKY_ENV if !isempty(get(ENV, k, ""))]

"Parse `--key value` / `--flag` arguments. Returns (Dict, positional)."
function parse_args(args, flags::Tuple = (), options::Tuple = ())
    opts = Dict{String, Any}()
    pos = String[]
    i = 1
    while i <= length(args)
        a = args[i]
        if a in flags
            opts[a] = true
        elseif a in options
            i < length(args) || error("$a needs a value")
            opts[a] = args[i += 1]
        elseif startswith(a, "--")
            error("unknown option $a")
        else
            push!(pos, a)
        end
        i += 1
    end
    return opts, pos
end

# --- repo-owned factory config and the sync record -------------------------------------
const FACTORY_CONFIG = ".agents/factory.toml"
# Machine-local, gitignored (factory 0.2.3): read-only roots that must not be committed (private
# paths). gen.jl merges its [bash_guard] read_only_roots into .claude/hooks/read-only-roots.txt.
const FACTORY_LOCAL = ".agents/factory.local.toml"
const CONFIG_KEYS = Dict("bash_guard" => ("read_only_roots", "require_read_only_roots"),
                         "check_docs" => ("exclude", "external", "ignore_fenced"),
                         "check_claims" => ("files", "required"))   # 0.2.4: scripts/check_claims.jl
const BOOL_KEYS = ("ignore_fenced", "require_read_only_roots")

"""
    factory_config(root, rel = FACTORY_CONFIG; keys = CONFIG_KEYS) -> Dict

The repo-owned `.agents/factory.toml` (seeded per profile), validated; empty when absent.
Unknown tables or keys are an error so a typo cannot silently disable a guard.
"""
function factory_config(root, rel = FACTORY_CONFIG; keys = CONFIG_KEYS)
    p = joinpath(root, rel)
    isfile(p) || return Dict{String, Any}()
    cfg = TOML.parsefile(p)
    for (k, v) in cfg
        k == "version" && continue
        haskey(keys, k) || error("$rel: unknown table `$k`")
        v isa AbstractDict || error("$rel: `$k` must be a table")
        for (kk, vv) in v
            kk in keys[k] || error("$rel: unknown key `$k.$kk`")
            if kk in BOOL_KEYS
                vv isa Bool || error("$rel: `$k.$kk` must be true or false")
            else
                (vv isa AbstractVector && all(x -> x isa AbstractString, vv)) ||
                    error("$rel: `$k.$kk` must be a list of strings")
            end
        end
    end
    return cfg
end
"The machine-local `.agents/factory.local.toml`: only `[bash_guard] read_only_roots`."
factory_local(root) = factory_config(root, FACTORY_LOCAL; keys = Dict("bash_guard" => ("read_only_roots",)))
config_list(cfg, table, key) = String[string(x) for x in get(get(cfg, table, Dict()), key, String[])]

"The sync record `.factory-version` (empty Dict when the repo was never synced)."
factory_record(root) = (p = joinpath(root, ".factory-version"); isfile(p) ? TOML.parsefile(p) : Dict{String, Any}())

"Where this repo keeps its ADRs: `adr_dir` in `.factory-version` (set from the MANIFEST profile), default `docs/adr`."
adr_dir(root) = rstrip(string(get(factory_record(root), "adr_dir", "docs/adr")), '/')
