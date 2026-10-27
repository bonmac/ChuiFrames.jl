# The tdd.jl history rules H1-H9 (factory 0.3.0; spec §0.5, §3.1-3.2, §4.2, §6). The evidence rules
# E1-E5, the ledger and `audit` are in _tdd_evidence.jl (tdd.jl only). Top-level definitions, included
# after _common.jl (it uses `git`, `merge_base`) by tdd.jl's `module Tdd` and by dod.jl; never run on its
# own, no `module` of its own, no side effects. Needs only Base and _common.jl. Every failure String
# starts with its rule id.

"One non-merge lane commit: `author` is `name <email>`, `phase` the `TDD:` trailer, `mode` the
commit's own `TDD-Mode:` trailer as (mode, reason), `paths` repo-relative."
struct LaneCommit
    sha::String
    author::String
    phase::Union{Nothing, String}
    mode::Union{Nothing, Tuple{String, String}}
    paths::Vector{String}
end

const LEAD_AUTHOR = "lead <lead@factory.invalid>"
role_author(role) = "$role <$role@factory.invalid>"
"The test-side roles (critic C1): each may author the test phases, under its own identity."
const TEST_ROLES = ("test-writer", "law-tester", "property-tester", "differential-tester")
"The side of each phase: \"implementer\" or \"test-writer\" (the test side, any of TEST_ROLES)."
const PHASE_ROLE = Dict(
    "stub" => "implementer", "green" => "implementer", "refactor" => "implementer",
    "red" => "test-writer", "test-fix" => "test-writer", "test-refactor" => "test-writer", "backfill" => "test-writer",
)
phase_authors(ph) = PHASE_ROLE[ph] == "implementer" ? (role_author("implementer"),) : role_author.(TEST_ROLES)
const ROLE_AUTHORS = (role_author.(TEST_ROLES)..., role_author("implementer"))
const SEEDED_RUNNERS = ("test/runtests.jl", "test/Project.toml")
is_code_path(p) = startswith(p, "src/") || startswith(p, "ext/")
is_test_path(p) = startswith(p, "test/")
sha7(s) = first(s, 7)

# ---- Commits

"""The trailers of a commit message as git parses them (`git interpret-trailers --parse --no-divider`, critic
C2: git is the one parser; a commit has no `---` divider): key => its first value; `TDD` and `TDD-Mode` matched case-insensitively, as `%(trailers:key=)`."""
function trailers(msg)
    out, canon_key = Dict{String, String}(), k -> get(Dict("tdd" => "TDD", "tdd-mode" => "TDD-Mode"), lowercase(k), k)
    for l in eachline(pipeline(`git interpret-trailers --parse --no-divider`; stdin = IOBuffer(msg)))
        m = match(r"^([^:]+):\s*(.*)$", l)
        m === nothing || get!(out, canon_key(m.captures[1]), String(strip(m.captures[2])))
    end
    return out
end
"Trailer `key` of commit `sha` as git's `%(trailers:key=…,valueonly)` reads it: the first value, \"\" when none."
git_trailer(root, sha, key) = String(strip(first(split(something(git(root, "log", "-1", "--format=%(trailers:key=$key,valueonly)", sha), ""), '\n'))))
"""`TDD-Mode: <mode> <sep> <reason>` as (mode, reason); <sep> is ` — `, ` – `, ` - ` or ` -- ` (critic C3), its first
occurrence: later separators stay in the reason. The reason is \"\" when there is none (also `skip -`)."""
function parse_mode(v)
    m = match(r"^(.*?)\s+(?:—|–|--|-)(?:\s+(.*))?$"s, v)
    m === nothing && return (String(strip(v)), "")
    return (String(strip(m.captures[1])), String(strip(something(m.captures[2], ""))))
end

"The paths commit `sha` changes (`--root`: a root commit's files count as added), as (status, path)."
changed(root, sha) = [
    (String(first(l, 1)), String(split(l, '\t')[end])) for l in
        split(something(git(root, "diff-tree", "--root", "--no-commit-id", "-r", "--no-renames", "--name-status", sha), ""), '\n'; keepempty = false)
]

"The non-merge commits of `base..head` (from the merge base), oldest first; `nothing` without a merge base."
function lane_commits(root, base, head = "HEAD")
    mb = merge_base(root, base, head)
    mb === nothing && return nothing
    shas = split(something(git(root, "rev-list", "--no-merges", "--reverse", "$mb..$head"), ""), '\n'; keepempty = false)
    return map(shas) do s
        author = something(git(root, "log", "-1", "--format=%an <%ae>", s), "")
        ph, md = git_trailer(root, s, "TDD"), git_trailer(root, s, "TDD-Mode")
        LaneCommit(String(s), author, isempty(ph) ? nothing : ph, isempty(md) ? nothing : parse_mode(md), [p for (_, p) in changed(root, s)])
    end
end

# ---- H1-H9

"The lane's mode and any H8 failure about the mode trailer (spec §4.2, §6): the oldest trailer decides."
function lane_mode(commits)
    i = findfirst(c -> c.mode !== nothing, commits)
    i === nothing && return ("required", String[])
    c = commits[i]
    m, reason = c.mode
    at = "$(sha7(c.sha)) TDD-Mode: $m"
    c.author == LEAD_AUTHOR || return ("required", m == "skip" ? ["H8 $at is not authored $LEAD_AUTHOR: skip refused"] : String[])
    m in ("required", "refactor", "skip") || return ("required", ["H8 $at: unknown mode (required, refactor or skip)"])
    m == "skip" && isempty(reason) && return ("required", ["H8 $at has no reason: skip mode refused"])
    return (m, String[])
end

"""
    history_rules(commits; stub_ok) -> Vector{String}

H1-H9 of spec §4.2 over `commits` (oldest first). `stub_ok(sha)` decides H5 for each `stub`. Pure.
"""
function history_rules(commits::AbstractVector; stub_ok::Function)
    out = String[]
    fail(id, c, what) = push!(out, "$id $(sha7(c.sha)) $(something(c.phase, "(no phase)")): $what")
    # H9 always applies; an unknown phase is reported as H1
    for c in commits
        if c.phase === nothing
            c.author in ROLE_AUTHORS && fail("H9", c, "a phase-less commit authored $(c.author)")
        elseif !haskey(PHASE_ROLE, c.phase)
            fail("H1", c, "unknown phase `$(c.phase)`")
        elseif !(c.author in phase_authors(c.phase))
            fail("H9", c, "authored $(c.author), not $(join(phase_authors(c.phase), " or "))")
        end
    end
    mode, mode_fails = lane_mode(commits)
    append!(out, mode_fails)
    mode == "skip" && return out
    any(c -> any(is_code_path, c.paths), commits) || return out           # H1: no code, H2-H8 off
    for c in commits
        tw = c.phase !== nothing && get(PHASE_ROLE, c.phase, "") == "test-writer"
        impl = c.phase !== nothing && get(PHASE_ROLE, c.phase, "") == "implementer"
        tests = filter(is_test_path, c.paths)
        c.phase === nothing && any(is_code_path, c.paths) && fail("H1", c, "changes code with no `TDD:` trailer")
        impl && !isempty(tests) && fail("H3", c, "changes test files: $(join(tests, ", "))")
        if tw
            bad = filter(p -> is_code_path(p) || p == "Project.toml" || startswith(p, "changelog.d/"), c.paths)
            isempty(bad) || fail("H3", c, "changes code, Project.toml or changelog.d: $(join(bad, ", "))")
        end
        if c.phase !== nothing
            r = filter(in(SEEDED_RUNNERS), c.paths)
            isempty(r) || fail("H3", c, "a phase commit changes the seeded runners: $(join(r, ", "))")
        end
        exempt = c.phase === nothing && c.author == LEAD_AUTHOR && all(in(SEEDED_RUNNERS), tests)
        !tw && !isempty(tests) && !exempt && fail("H4", c, "touches test/** outside a test-writer phase: $(join(tests, ", "))")
        c.phase == "stub" && !stub_ok(c.sha) && fail("H5", c, "the stub does more than declare")
    end
    if mode == "refactor"
        for c in commits
            c.phase in ("red", "test-fix", "green", "stub") && fail("H8", c, "refactor mode allows no red, green or stub")
            any(is_test_path, c.paths) && fail("H8", c, "refactor mode allows no test/** change")
        end
        return out
    end
    count(c -> c.phase == "red", commits) >= 1 || push!(out, "H2 mode required: the lane has no `TDD: red` commit")
    open, greened = false, false
    for (i, c) in enumerate(commits)
        p = c.phase
        if p == "stub"
            open && fail("H6", c, "a stub after a red that has no green yet; a stub comes before its red")
            any(x -> x.phase == "red", commits[(i + 1):end]) || fail("H6", c, "no red after this stub")
        elseif p in ("red", "test-fix")
            open = true
        elseif p == "green"
            open || fail("H6", c, "a green with no red or test-fix open before it")
            open, greened = false, true
        elseif p in ("refactor", "test-refactor")
            (greened && !open) || fail("H6", c, "a $p before a green (or while a red is open)")
        end
    end
    open && push!(out, "H7 the lane ends on a red: its green is missing")
    return out
end

# ---- H5: a stub only declares

# `strip_lines!` (line-stripped statements) is in _common.jl: _tdd_classify.jl's `requested` uses it too.
is_compat_name(n) = n === Symbol("@compat") || n == Expr(:., :Compat, QuoteNode(Symbol("@compat")))
is_names(x) = x isa Symbol || (x isa Expr && x.head === :tuple && !isempty(x.args) && all(a -> a isa Symbol, x.args))
is_export(x) = x isa Expr && x.head in (:export, :public) && all(a -> a isa Symbol, x.args)
"A `@compat public a, h` / `@compat export g` (also `Compat.@compat`) statement, as it parses."
function is_compat_decl(ex)
    (ex isa Expr && ex.head === :macrocall && length(ex.args) >= 2 && is_compat_name(ex.args[1])) || return false
    rest = ex.args[3:end]
    length(rest) == 1 && return is_export(rest[1]) && rest[1].head === :export
    return length(rest) == 2 && rest[1] === :public && is_names(rest[2])
end
"(kind, names) of an export/public/@compat statement, else nothing."
function decl_names(ex)
    is_export(ex) && return (ex.head, Set{Symbol}(ex.args))
    is_compat_decl(ex) || return nothing
    rest = ex.args[3:end]
    length(rest) == 1 && return (:export, Set{Symbol}(rest[1].args))
    return (:public, Set{Symbol}(rest[2] isa Symbol ? [rest[2]] : rest[2].args))
end
const DOC_NAMES = (GlobalRef(Core, Symbol("@doc")), Symbol("@doc"), Expr(:., :Core, QuoteNode(Symbol("@doc"))))
function field_only(body)
    for x in body.args
        (x isa Symbol || x isa String) && continue          # a field, or a field docstring
        x isa Expr && x.head === :const && length(x.args) == 1 && (x = x.args[1])
        x isa Symbol || (x isa Expr && x.head === :(::) && length(x.args) == 2 && x.args[1] isa Symbol) || return false
    end
    return true
end
"Is the added statement `ex` one H5 allows? `inc(path)` checks an `include(path)`."
function allowed_decl(ex, inc; doc = true)
    ex isa Expr || return false
    h = ex.head
    h === :function && length(ex.args) == 1 && return ex.args[1] isa Symbol
    h === :struct && return field_only(ex.args[3])
    h in (:abstract, :primitive, :using, :import) && return true
    (is_export(ex) || is_compat_decl(ex)) && return true
    h === :call && length(ex.args) == 2 && ex.args[1] === :include && ex.args[2] isa String && return inc(ex.args[2])
    if doc && h === :macrocall && length(ex.args) == 4 && ex.args[1] in DOC_NAMES && ex.args[3] isa String
        return allowed_decl(ex.args[4], _ -> false; doc = false)
    end
    return false
end
"The statements of `ex`, flattened through `module`/`baremodule` bodies, keyed by module path."
function statements!(out, ex, path = ())
    for x in (ex isa Expr && ex.head in (:toplevel, :block) ? ex.args : [ex])
        if x isa Expr && x.head === :module
            push!(out, (path, Expr(:module_decl, x.args[1], x.args[2])))   # a new module is no decl
            statements!(out, x.args[3], (path..., x.args[2]))
        elseif !(x === nothing || x isa LineNumberNode)
            push!(out, (path, x))
        end
    end
    return out
end
function parsed_statements(text, file)
    ex = Meta.parseall(text; filename = file)
    has_err(x) = x isa Expr && (x.head in (:error, :incomplete) || any(has_err, x.args))
    has_err(ex) && return nothing
    return statements!(Tuple{Tuple, Any}[], strip_lines!(ex))
end
counts(v) = (d = Dict{Any, Int}(); foreach(x -> d[x] = get(d, x, 0) + 1, v); d)
"The elements of multiset `a` not in `b`, with multiplicity."
minus(a, b) = [k for (k, n) in a for _ in 1:(n - get(b, k, 0))]

"""
    stub_declares_only(root, sha) -> Bool

H5 of spec §4.2 for the `stub` commit `sha`: every changed src/ext file only gains declarations,
compared as multisets of line-stripped statements; removals only as an export/public replaced by
a superset; `include` only of a file the commit adds, itself declaration-only.
"""
function stub_declares_only(root, sha)
    ch = changed(root, sha)
    added = Set(p for (s, p) in ch if s == "A")
    parent = git(root, "rev-parse", "--verify", "--quiet", "$sha^")
    show_(rev, p) = something(git(root, "show", "$rev:$p"), "")
    seen = Set{String}()
    function inc_ok(file, arg)
        p = normpath(joinpath(dirname(file), arg))
        (p in added && !(p in seen)) || return false
        push!(seen, p)
        st = parsed_statements(show_(sha, p), p)
        return st !== nothing && all(x -> allowed_decl(x[2], a -> inc_ok(p, a)), st)
    end
    for (s, f) in ch
        is_code_path(f) || continue
        endswith(f, ".jl") || return false
        old = s == "A" || parent === nothing ? Tuple{Tuple, Any}[] : parsed_statements(show_(parent, f), f)
        new = s == "D" ? Tuple{Tuple, Any}[] : parsed_statements(show_(sha, f), f)
        (old === nothing || new === nothing) && return false
        co, cn = counts(old), counts(new)
        plus, gone = minus(cn, co), minus(co, cn)
        all(x -> allowed_decl(x[2], a -> inc_ok(f, a)), plus) || return false
        for (path, x) in gone
            d = decl_names(x)
            d === nothing && return false
            any(y -> y[1] == path && (e = decl_names(y[2]); e !== nothing && e[1] == d[1] && d[2] ⊆ e[2]), plus) || return false
        end
    end
    return true
end

# ---- Segments (critic C6, option a): the mode is per merged sub-lane

"""
    lane_segments(root, base, commits, head = "HEAD") -> Vector{Vector{LaneCommit}}

The H-rule segments of `commits` (`lane_commits(root, base, head)`): for each merge M on the first-parent
chain of base..head, the commits of `M^1..M^2` form one segment, under that sub-lane's own mode commit (a later
merge whose `M^2` first-parent chain holds an earlier `M^2` is the same sub-lane: one segment); every other commit (made directly on the integration branch) forms the first, under the branch's own mode commit.
"""
function lane_segments(root, base, commits, head = "HEAD")
    mb = merge_base(root, base, head)
    (mb === nothing || isempty(commits)) && return [commits]
    by = Dict(c.sha => c for c in commits)
    revs(a...) = split(something(git(root, "rev-list", "--reverse", a...), ""), '\n'; keepempty = false)
    ms = revs("--first-parent", "--merges", "$mb..$head")
    subs = [[by[s] for s in revs("--no-merges", "$m^1..$m^2") if haskey(by, s)] for m in ms]
    tips = [something(git(root, "rev-parse", "$m^2"), "") for m in ms]
    for k in eachindex(ms)   # review FIX-1: a sub-lane merged again (an earlier M^2 on this M^2's first-parent chain)
        chain = Set(revs("--first-parent", "$mb..$(ms[k])^2"))   # joins the segment of its first merge
        j = findfirst(i -> i < k && tips[i] in chain, eachindex(ms))
        j === nothing || (append!(subs[j], subs[k]); empty!(subs[k]))
    end
    inner = Set(c.sha for s in subs for c in s)
    return [[filter(c -> !(c.sha in inner), commits)]; filter(!isempty, subs)]
end
"H1-H9 (`history_rules`) over each segment of `lane_segments`, concatenated."
segment_rules(segs; stub_ok) = reduce(vcat, (history_rules(s; stub_ok) for s in segs); init = String[])
