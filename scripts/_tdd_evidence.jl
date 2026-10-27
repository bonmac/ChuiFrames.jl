# The tdd.jl evidence rules E1-E5, the TDD ledger and `audit` (factory 0.3.0; spec §0.5, §4.3, §5.2, §6).
# Split from _tdd_history.jl (critic C4: that file was at the 400-line budget). Top-level definitions,
# included by tdd.jl's `module Tdd` after _common.jl and _tdd_history.jl (it uses `git`, `merge_base`,
# `LaneCommit`, `lane_commits`, `lane_segments`, `segment_rules`, `parse_mode`, `git_trailer`; F4's helpers
# also `requested`, `item_spans`, `_show` of _tdd_classify.jl, and tdd.jl's `Evidence`, `append_tdd`); dod.jl does
# not include it (dod has no E rules). No `module` of its own, no side effects. Needs Base and SHA.

using SHA: sha1

# ---- E1-E5: evidence (`<root>/.lanes/evidence/`, written by evidence.jl) and the TDD ledger

"The `key: value` header of an evidence file and its `--- tdd ---` part (\"\" when none)."
function evidence_file(path)
    isfile(path) || return nothing
    t = read(path, String)
    h = Dict{String, String}()
    for l in split(t, '\n')
        startswith(l, "--- ") && break
        m = match(r"^([a-z]+):\s*(.*)$", l)
        m === nothing || (h[m.captures[1]] = m.captures[2])
    end
    i = findfirst("\n--- tdd ---\n", t)
    return (h = h, tdd = i === nothing ? "" : t[(last(i) + 1):end])
end
clean(ev) = get(ev.h, "dirty", "") == "false" && get(ev.h, "termsignal", "") == "0"
const NOT_RED = r"\b(WRONG[-_]REASON|PASSED|NOT[-_]RUN|COLLATERAL)\b"
red_pass(ev, sha) = ev !== nothing && clean(ev) && get(ev.h, "head", "") == sha &&
    occursin(r"\b(ASSERTION|BEHAVIOUR)\b", ev.tdd) && !occursin(NOT_RED, ev.tdd)
# M3: an `exit: 0` alone is no verdict (`evidence.jl green -- true` writes one); tdd.jl's must be there too
green_pass(ev, sha) = ev !== nothing && clean(ev) && get(ev.h, "head", "") == sha && get(ev.h, "exit", "") == "0" &&
    occursin(r"(?m)^green default suite: OK\b", ev.tdd)
mutate_pass(ev) = ev !== nothing && clean(ev) && get(ev.h, "exit", "") == "0" && occursin(r"(?m)^KILLED\b", ev.tdd)

# ---- 0.3.1 F4: a deletion-only test-fix adds or changes no @testitem and removes at least one

"The sorted names of the @testitems in a test file at `sha^` that are gone from that file at `sha`."
function removed_items(root, sha)
    parent = git(root, "rev-parse", "--verify", "--quiet", "$sha^")
    parent === nothing && return String[]
    gone = String[]
    for f in filter(_is_test_file, split(something(git(root, "diff", "--name-only", "--no-renames", parent, sha), ""), '\n'; keepempty = false))
        kept = Set(s.name for s in item_spans(_show(root, sha, f), f))
        append!(gone, [s.name for s in item_spans(_show(root, parent, f), f) if !(s.name in kept)])
    end
    return sort!(unique!(gone))
end
"Commit `sha` adds or changes no @testitem and removes some item (a changed setup module is allowed: `tdd.jl green` runs its users)."
deletion_only(root, sha) = isempty(requested(root, sha).red) && !isempty(removed_items(root, sha))
"The sorted names on the `REMOVED <name>` lines of an evidence file's `--- tdd ---` part."
removed_names(ev) = sort!(unique!([String(m.captures[1]) for m in eachmatch(r"(?m)^\s*REMOVED\s+(.*?)\s*$", ev.tdd)]))
"""
    removal_pass(root, ev, sha) -> Bool

Red evidence `ev` of a deletion-only test-fix (0.3.1 F4): clean, `head` = `sha`, its `--- tdd ---` part only
`red <sha7>: OK ...` and `REMOVED <name>` lines, and those names exactly the items git says `sha` removed,
with `sha` deletion-only by git (`deletion_only`). The caller checks the phase (and, in green, the author).
"""
function removal_pass(root, ev, sha)
    (ev !== nothing && clean(ev) && get(ev.h, "head", "") == sha) || return false
    ls = filter(!isempty, strip.(split(ev.tdd, '\n')))
    (!isempty(ls) && startswith(ls[1], "red $(sha7(sha)): OK") && all(l -> startswith(l, "REMOVED "), ls[2:end])) || return false
    names = removed_names(ev)
    return !isempty(names) && deletion_only(root, sha) && names == removed_items(root, sha)
end
"""
    red_removed(root, sha, gone; io) -> exit code

`tdd.jl red` on a deletion-only test-fix: no item to run, so the evidence red-<sha7> (evidence.jl, the
commit's `git diff --stat`) records what it removed: `red <sha7>: OK ...` and one `REMOVED <name>` per item.
"""
function red_removed(root, sha, gone; io)
    code = Evidence.run_evidence(root, "red", String["git", "diff", "--stat", "--no-renames", "$sha^", sha]; io)
    verdict = "red $(sha7(sha)): $(code == 0 ? "OK" : "NOT OK") (deletion-only test-fix, run exit $code)\n"
    append_tdd(joinpath(Evidence.evidence_dir(root), "red-$(sha7(sha)).txt"), verdict * join("REMOVED $n\n" for n in gone); io)
    return code == 0 ? 0 : 1
end

"The evidence kind's slug for item `name` (spec §5.2): at most 33 characters."
evidence_slug(name) = first(replace(lowercase(name), r"[^a-z0-9]+" => "-"), 24) * "-" * bytes2hex(sha1(name))[1:8]

"The `@testitem`s of a test file: name => only `@test_broken` assertions?"
function test_items(text)
    ex = Meta.parseall(text)
    items = Dict{String, Bool}()
    ex isa Expr || return items
    for x in ex.args
        x isa Expr && x.head === :macrocall && x.args[1] === Symbol("@testitem") && length(x.args) >= 4 && x.args[3] isa String || continue
        ms = Symbol[]
        walk(e) = e isa Expr && (e.head === :macrocall && e.args[1] isa Symbol && startswith(string(e.args[1]), "@test") && push!(ms, e.args[1]); foreach(walk, e.args))
        walk(x.args[end])
        items[x.args[3]] = !isempty(ms) && all(==(Symbol("@test_broken")), ms)
    end
    return items
end
"The items a commit adds (new names in its changed test files): name => @test_broken-only?"
function added_items(root, sha)
    out = Dict{String, Bool}()
    for (s, f) in changed(root, sha)
        (is_test_path(f) && endswith(f, ".jl") && s != "D") || continue
        old = s == "A" ? Dict{String, Bool}() : test_items(something(git(root, "show", "$sha^:$f"), ""))
        for (n, broken) in test_items(something(git(root, "show", "$sha:$f"), ""))
            haskey(old, n) || (out[n] = broken)
        end
    end
    return out
end

"The flat string fields of each JSONL line of the ledger (no JSON stdlib)."
function ledger_records(path)
    isfile(path) || return nothing
    return [
        Dict{String, String}(
            m.captures[1] => replace(m.captures[2], r"\\(.)" => s"\1")
                for m in eachmatch(r"\"([A-Za-z_]+)\"\s*:\s*\"((?:[^\"\\]|\\.)*)\"", l)
        ) for l in eachline(path) if !isempty(strip(l))
    ]
end
"""
    owning_ledger(root) -> Union{String, Nothing}

The TDD ledger of checkout `root` (spec §0.5; 0.3.1 F2): the ledger of the MAIN checkout of the repo that owns it,
`<dirname of git's absolute common dir>/.lanes/ledger.jsonl`, whether or not the file exists; nothing when `root`
is not in a git repo. The shell `owning_ledger` in .claude/hooks/_lib.sh is the same rule (tdd_commit_post writes there).
"""
function owning_ledger(root)
    gcd = git(root, "rev-parse", "--path-format=absolute", "--git-common-dir")
    (gcd === nothing || isempty(gcd)) && return nothing
    return joinpath(dirname(gcd), ".lanes", "ledger.jsonl")
end
canon(p) = (q = rstrip(p, '/'); ispath(q) ? realpath(q) : q)

"""
    e5_waivers(root, commits) -> Set{String}

Critic C4: the full shas of `commits` that a lane commit authored exactly `lead <lead@factory.invalid>`
waives with the git trailer `TDD-Waiver: E5 <sha> <sep> <reason>` (sep as `parse_mode`'s; <sha> full or a
prefix of at least 7 hex characters naming exactly one lane commit; a non-empty reason). The waiver lets a
role commit whose only record is `tdd-commit-late` pass E5; it never covers a sha with no record or a violation.
"""
function e5_waivers(root, commits)
    out = Set{String}()
    for w in commits
        w.author == LEAD_AUTHOR || continue
        head, reason = parse_mode(git_trailer(root, w.sha, "TDD-Waiver"))
        m = match(r"^E5\s+([0-9a-f]{7,40})$", head)
        (m === nothing || isempty(reason)) && continue
        hits = filter(c -> startswith(c.sha, m.captures[1]), commits)
        length(hits) == 1 && push!(out, hits[1].sha)
    end
    return out
end

"""
    evidence_rules(root, commits; ledger, base = nothing) -> Vector{String}

E1-E5 of spec §4.3. The refactor-mode merge base is `merge_base(root, base)`, or the first
commit's parent when `base` is nothing.
"""
function evidence_rules(root, commits::AbstractVector; ledger, base = nothing)
    out = String[]
    dir = joinpath(root, ".lanes", "evidence")
    ev(kind, sha) = evidence_file(joinpath(dir, "$kind-$(sha7(sha)).txt"))
    fail(id, c, what) = push!(out, "$id $(sha7(c.sha)) $(something(c.phase, "(no phase)")): $what")
    files = isdir(dir) ? readdir(dir) : String[]
    for c in commits
        c.phase in ("red", "test-fix") && !red_pass(ev("red", c.sha), c.sha) &&
            !(c.phase == "test-fix" && removal_pass(root, ev("red", c.sha), c.sha)) &&   # 0.3.1 F4
            fail("E1", c, "no passing red-$(sha7(c.sha)) (head $(c.sha), clean, ASSERTION/BEHAVIOUR items only, or a deletion-only test-fix's REMOVED items)")
        c.phase in ("green", "refactor", "test-refactor") && !green_pass(ev("green", c.sha), c.sha) &&
            fail("E2", c, "no passing green-$(sha7(c.sha)) (head $(c.sha), clean, exit 0)")
        if c.phase == "backfill"
            for (name, broken) in sort!(collect(added_items(root, c.sha)))
                broken && (push!(out, "note $(sha7(c.sha)): `$name` has only @test_broken assertions: listed, not proved"); continue)
                s = evidence_slug(name)
                ok = any(
                    f -> (startswith(f, "mutate-$s-") || startswith(f, "mutexp-$s-")) && endswith(f, ".txt") &&
                        mutate_pass(evidence_file(joinpath(dir, f))), files
                )
                ok || fail("E3", c, "item `$name` has no passing mutate-$s or mutexp-$s evidence")
            end
        end
        for f in files
            endswith(f, "-$(sha7(c.sha)).txt") || continue
            e = evidence_file(joinpath(dir, f))
            e !== nothing && !clean(e) && fail("E4", c, "evidence $f is dirty or killed")
        end
    end
    if first(lane_mode(commits)) == "refactor" && !isempty(commits)
        mb = base === nothing ? git(root, "rev-parse", "--verify", "--quiet", "$(commits[1].sha)^") : merge_base(root, base)
        (mb !== nothing && green_pass(ev("green", mb), mb)) ||
            push!(out, "E2 refactor mode: no passing green-$(sha7(something(mb, "?"))) at the merge base")
    end
    roles = filter(c -> c.author in ROLE_AUTHORS, commits)
    recs = ledger === nothing ? nothing : ledger_records(ledger)
    if recs === nothing
        isempty(roles) || push!(out, "E5 no TDD ledger ($(something(ledger, "none found above $root"))): $(length(roles)) role commit(s) unchecked")
        return out
    end
    waived = isempty(roles) ? Set{String}() : e5_waivers(root, commits)
    for c in roles
        t = first(split(c.author, ' '))
        any(r -> get(r, "ev", "") == "tdd-commit" && get(r, "sha", "") == c.sha && get(r, "agent_type", "") == t, recs) && continue
        late = any(r -> get(r, "ev", "") == "tdd-commit-late" && get(r, "sha", "") == c.sha, recs)   # B2: a sweep's record
        late && c.sha in waived && continue   # critic C4: the lead's TDD-Waiver: E5 attests a late-only record
        fail(
            "E5", c, "no tdd-commit record with this sha and agent_type $t in $ledger" *
                (late ? " (only a late swept record: amend it through the hooks while it is HEAD, or the lead's TDD-Waiver: E5)" : "")
        )
    end
    shas = Set(c.sha for c in commits)   # B2: a violation is this lane's only by sha
    for r in recs
        get(r, "ev", "") == "tdd-commit-violation" || continue
        get(r, "sha", "") in shas &&
            push!(out, "E5 tdd-commit-violation for $(sha7(get(r, "sha", "?"))): $(get(r, "reason", "(no reason)"))")
    end
    return out
end

"""
    audit(root; base = "main", ledger = nothing, io) -> exit code

H1-H9 (per merged sub-lane, critic C6: `segment_rules`) and E1-E5 over `base..HEAD`; prints each failure
(rule id first). 0 none, 1 some, 2 could not evaluate. `ledger` defaults to `owning_ledger(root)`.
"""
function audit(root; base = "main", ledger = nothing, io = stdout)
    commits = lane_commits(root, base)
    commits === nothing && (println(io, "tdd.jl audit: no merge base with `$base` in $root (exit 2)."); return 2)
    ledger = something(ledger, owning_ledger(root), Some(nothing))
    hs = segment_rules(lane_segments(root, base, commits); stub_ok = s -> stub_declares_only(root, s))
    v = [hs; evidence_rules(root, commits; ledger, base)]
    foreach(l -> println(io, l), v)
    bad = count(l -> occursin(r"^[HE][0-9]", l), v)
    println(io, "tdd.jl audit: ", bad == 0 ? "OK" : "NOT OK, $bad failure(s)", " ($(length(commits)) commit(s), ledger $(something(ledger, "none")))")
    return bad == 0 ? 0 : 1
end
