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

"""
    base_ref(dir, base) -> String

The ref that stands for `base` (factory 0.2.6): the local `base` when it contains
`origin/<base>` (local ahead or equal) or there is no `origin/<base>`; `origin/<base>` when the
local branch is missing, behind or diverged. Before 0.2.6 `origin/<base>` always won, so work
merged locally but not pushed counted as the lane's own changes (`lane audit`, `dod.jl`).
An explicit `origin/<b>` is taken as given, except when it does not resolve here (no remote, a
pruned tracking ref) and a local branch `<b>` exists: then `<b>` (0.2.7; 0.2.6 returned the
missing ref and `dod.jl --base origin/main` failed with "no merge base"). An expression over it
follows the same rule (`origin/main~1` -> `main~1`). `base_note` says when this happened.
"""
function base_ref(dir, base)
    has(ref) = git(dir, "rev-parse", "--verify", "--quiet", "$ref^{commit}") !== nothing
    if startswith(base, "origin/")
        b = base[(length("origin/") + 1):end]
        return !isempty(b) && !has(base) && has("refs/heads/$b") ? b : base
    end
    # a SHA, tag or expression (`HEAD~1`, `feat/x~2`) that is not a local branch is taken as given
    has("refs/heads/$base") || !has(base) || return base
    has("refs/remotes/origin/$base") || return base
    has("refs/heads/$base") || return "origin/$base"
    # `merge-base --is-ancestor A B` exits 0 (git returns "") when A is an ancestor of B
    return git(dir, "merge-base", "--is-ancestor", "origin/$base", base) === nothing ? "origin/$base" : base
end

"""
    base_note(dir, base) -> String or nothing

A one-line notice when `base_ref` put a local branch in place of an `origin/<b>` that does not
resolve here (0.2.7 review S1: the fallback must be visible), else `nothing`. Callers print it.
"""
function base_note(dir, base)
    r = base_ref(dir, base)
    return r == base ? nothing : startswith(base, "origin/") ?
        "note: `$base` does not resolve here (no remote, or a pruned tracking ref); using the local `$r`" : nothing
end

"The merge base of `head` with `base` (the ref `base_ref` picks, then the other spelling of a branch). `nothing` if none."
function merge_base(dir, base, head = "HEAD")
    b = base_ref(dir, base)
    branch = b == "origin/$base" || b == base && git(dir, "rev-parse", "--verify", "--quiet", "refs/heads/$base") !== nothing
    for r in unique!(branch ? [b, base, "origin/$base"] : [b])
        mb = git(dir, "merge-base", r, head)
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

"""`Base.remove_linenums!`, then each macrocall's own line slot (`args[2]`) set to `nothing` and the
`:toplevel` LineNumberNodes dropped: `remove_linenums!` keeps both (measured on 1.13.2 and 1.10.12).
Used by _tdd_history.jl (H5) and _tdd_classify.jl (`requested`: an item that only moved is unchanged)."""
function strip_lines!(ex)
    Base.remove_linenums!(ex)
    function walk(x)
        x isa Expr || return
        x.head === :macrocall && length(x.args) >= 2 && (x.args[2] = nothing)
        x.head === :toplevel && filter!(a -> !(a isa LineNumberNode), x.args)
        return foreach(walk, x.args)
    end
    walk(ex)
    return ex
end

"Julia environment variables inherited from a parent shell that make a lane or a CI job resolve the wrong project (0.2.4)."
const LEAKY_ENV = ("JULIA_PROJECT", "JULIA_LOAD_PATH", "JULIA_DEPOT_PATH")
env_warnings() = [
    "$k=$(ENV[k]) is set in this environment and is inherited by everything started from here. Unset it unless you mean it."
        for k in LEAKY_ENV if !isempty(get(ENV, k, ""))
]

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
const CONFIG_KEYS = Dict(
    "bash_guard" => ("read_only_roots", "require_read_only_roots"),
    "check_docs" => ("exclude", "external", "ignore_fenced"),
    "check_claims" => ("files", "required")
)   # 0.2.4: scripts/check_claims.jl
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
