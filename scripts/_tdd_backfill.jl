# _tdd_backfill.jl: `tdd.jl mutate` and `tdd.jl gaps` (factory 0.3.0; spec 2026-10-26 §5.1, §5.2).
# Included by scripts/tdd.jl inside `module Tdd` (it uses run_items, spans_at, classify, report,
# refuse_dirty, have_ci and Evidence from there); never run on its own.

"The evidence slug of item `name` (spec §5.2): `evidence_slug` of _tdd_evidence.jl, at most 33 characters."
slug(name) = evidence_slug(name)

const MANIFESTS = ("Manifest.toml", "Manifest-v1.10.toml")

"""
    scratch(root; sha = HEAD) -> path

The persistent mutation scratch `<root>/.lanes/scratch/mutate/`: a detached git worktree of `root`'s
repo, checked out (forced) at `sha`, with `root`'s Manifest.toml and Manifest-v1.10.toml copied in.
Created on first use; reused afterwards so its precompile cache stays warm.
"""
function scratch(root; sha = Evidence.head_sha(root))
    sc = joinpath(root, ".lanes", "scratch", "mutate")
    if !isfile(joinpath(sc, ".git"))
        git(root, "worktree", "prune")                     # a deleted scratch stays registered otherwise
        mkpath(dirname(sc))
        git(root, "worktree", "add", "-q", "--detach", "--force", sc, sha; strict = true)
    end
    git(sc, "checkout", "-q", "--force", "--detach", sha; strict = true)
    for m in MANIFESTS
        src = joinpath(root, m)
        isfile(src) && cp(src, joinpath(sc, m); force = true)
    end
    return sc
end

"`(file, line)` from \"F:LINE\", or nothing."
function file_line(s)
    m = match(r"^(.+):(\d+)$", s)
    return m === nothing ? nothing : (String(m.captures[1]), parse(Int, m.captures[2]))
end

"`text` with the first `from` on line `n` replaced by `to`; nothing when `from` is not on that line."
function mutated(text, n, from, to)
    lines = split(text, '\n')
    (1 <= n <= length(lines) && occursin(from, lines[n])) || return nothing
    lines[n] = replace(lines[n], from => to; count = 1)
    return join(lines, '\n')
end

"""Rewrite evidence `path` as kind `kind` with `exit:` set to mutate's verdict; append `extra`. A
`dirty` Bool replaces the `dirty:` line: the mutant run's file says `true` (the scratch holds the
mutation), so a survivor's evidence takes the real tree's state instead (review minor 2)."""
function seal_evidence(src, path, kind, verdict, extra; dirty = nothing)
    t = read(src, String)
    i = findfirst("\n--- output ---\n", t)
    head = replace(t[1:first(i)], r"(?m)^kind: .*$" => "kind: $kind", r"(?m)^exit: .*$" => "exit: $verdict")
    dirty === nothing || (head = replace(head, r"(?m)^dirty: .*$" => "dirty: $dirty"))
    write(path, head * t[(first(i) + 1):end] * extra)
    return path
end

"""
    item_run(dir, name, spans; io) -> (class, run)

Run item `name` in `dir` (`run_items`, evidence kind `mutant` in `dir`) and classify it. NOT-RUN
when it was not selected or the `Test Summary:` total is 0 (a vacuous run, spec §3.4).
"""
function item_run(dir, name, spans; io)
    r = run_items(dir, "mutant", [name]; io)
    tt = Evidence.test_totals(r.output)
    total = tt === nothing ? 0 : tt["total"]
    name in r.matched || return (NOT_RUN, r, Pair{String, Symbol}[name => NOT_RUN])
    # an `Unexpected Pass` is WRONG-REASON in `classify` itself (review M1), as for red and green
    result = classify(r.output, spans, ItemSpan[], r.matched; termsignal = r.termsignal)
    own = [p.second for p in result if p.first == name]
    class = any(p -> p.second === WRONG_REASON, result) ? WRONG_REASON :
        (isempty(own) || total < 1) ? NOT_RUN : first(own)
    return (class, r, result)
end

"""
    mutate(root; item, src = nothing, expect = nothing, from, to, io) -> exit code

Spec §5.2. At `root`'s committed HEAD, replace the first `from` on line `src` (\"F:LINE\" in src/) or,
as the fallback, `expect` (a test line), in the scratch worktree only; run `item=<item>` there: the
item must be selected and fail as ASSERTION or BEHAVIOUR. The scratch file is restored in `finally`.
Then the item must be selected and pass on the real tree. Evidence `mutate-<slug>` / `mutexp-<slug>`
in `root`, its `exit:` the verdict. 0 killed, 1 survived / wrong reason / not run, 2 could not
evaluate (dirty tree, bad F:LINE, `from` not on the line; no evidence written).
"""
function mutate(root; item, src = nothing, expect = nothing, from, to, io = stdout)
    refuse_dirty(root, io, "mutate") && return 2
    (src === nothing) == (expect === nothing) && (println(io, "tdd.jl mutate: give exactly one of --src F:LINE, --expect F:LINE (exit 2)."); return 2)
    fl = file_line(something(src, expect))
    fl === nothing && (println(io, "tdd.jl mutate: `$(something(src, expect))` is not F:LINE (exit 2)."); return 2)
    file, n = fl
    # review minor 1: a mutation goes in src/ or ext/ (--src), or in test/ (--expect), nowhere else
    np = normpath(file)
    src === nothing || is_code_path(np) || (println(io, "tdd.jl mutate: --src $file is not under src/ or ext/ (exit 2)."); return 2)
    expect === nothing || is_test_path(np) || (println(io, "tdd.jl mutate: --expect $file is not under test/ (exit 2)."); return 2)
    sha = Evidence.head_sha(root)
    text = git(root, "show", "$sha:$file")
    text === nothing && (println(io, "tdd.jl mutate: $file is not in HEAD $(first(sha, 7)) (exit 2)."); return 2)
    text = read(joinpath(root, file), String)              # the clean tree's bytes (git chomps)
    mut = mutated(text, n, from, to)
    mut === nothing && (println(io, "tdd.jl mutate: `$from` is not on $file:$n (exit 2)."); return 2)
    have_ci(root, io, "mutate") || return 2
    kind = (src === nothing ? "mutexp-" : "mutate-") * slug(item)
    spans = spans_at(root, sha, [item])
    sc = scratch(root; sha)
    path = joinpath(sc, file)
    buf = IOBuffer()
    println(buf, "mutate $(first(sha, 7)) item `$item`: $file:$n `$from` -> `$to`")
    local mclass, m, mresult
    try
        write(path, mut)
        mclass, m, mresult = item_run(sc, item, spans; io)
    finally
        write(path, text)
    end
    println(buf, "mutant run (scratch $sc): $mclass")
    report(buf, mresult, headers(m.output))
    verdict, base = 1, m.path
    if mclass in (:ASSERTION, :BEHAVIOUR)
        rclass, r, rresult = item_run(root, item, spans; io)
        ok = rclass === :PASSED && r.code == 0
        println(buf, "real run: $rclass (exit $(r.code))")
        report(buf, rresult, headers(r.output))
        verdict, base = ok ? 0 : 1, r.path
        println(buf, ok ? "KILLED: the item detects the mutation (exit 0)" : "NOT OK: the item does not pass on the real tree (exit 1)")
    elseif mclass === :PASSED
        println(buf, "SURVIVED: `$item` passes with the mutation (exit 1)")
    else
        println(buf, "NOT OK: the mutant run is $mclass, not a detection (exit 1)")
    end
    report_text = String(take!(buf))
    out = joinpath(Evidence.evidence_dir(root), "$kind-$(first(sha, 7)).txt")
    mkpath(dirname(out))
    seal_evidence(
        base, out, kind, verdict, "--- mutant output ---\n" * m.output * "--- tdd ---\n" * report_text;
        dirty = base == m.path ? is_dirty(root) : nothing
    )
    base == out || base == m.path || rm(base; force = true)
    print(io, "--- tdd ---\n", report_text)
    println(io, "tdd.jl mutate: wrote ", out)
    return verdict
end

# The package's exported and public names (Julia >= 1.11: `names` lists both), one per line.
const NAMES_SCRIPT = raw"""
pkg = Symbol(ARGS[1])
@eval using $pkg
M = getfield(Main, pkg)
foreach(n -> n === nameof(M) || println(n), names(M))
"""

"""
    gaps(root; io) -> exit code

Spec §5.1: `UNTESTED <name>` for each exported or `public` name of the package at `root` that
appears nowhere in `root/test/` as a whole identifier; 0. Julia < 1.11: NOT RUN, 2.
"""
function gaps(root; io = stdout)
    if VERSION < v"1.11"
        println(io, "tdd.jl gaps: NOT RUN: needs Julia >= 1.11 (this is $VERSION).")
        return 2
    end
    proj = joinpath(root, "Project.toml")
    name = isfile(proj) ? get(TOML.parsefile(proj), "name", nothing) : nothing
    name === nothing && (println(io, "tdd.jl gaps: no package name in $proj (exit 2)."); return 2)
    out, err = IOBuffer(), IOBuffer()
    cmd = Cmd(`$(julia_exe()) --startup-file=no --project=$root -e $NAMES_SCRIPT $name`; dir = root, ignorestatus = true)
    p = run(pipeline(cmd; stdout = out, stderr = err); wait = true)
    success(p) || (println(io, "tdd.jl gaps: loading $name failed (exit $(p.exitcode)):\n", String(take!(err))); return 1)
    texts = String[]
    tdir = joinpath(root, "test")
    for (d, _, fs) in (isdir(tdir) ? walkdir(tdir) : ()), f in fs
        endswith(f, ".jl") && push!(texts, read(joinpath(d, f), String))
    end
    idents = Set{String}(m.match for t in texts for m in eachmatch(r"[\p{L}_][\p{L}\p{N}_!]*", t))
    is_ident(n) = occursin(r"^[\p{L}_][\p{L}\p{N}_!]*$", n)
    names_ = sort!(split(String(take!(out)), '\n'; keepempty = false))
    untested = filter(n -> is_ident(n) ? !(n in idents) : !any(t -> occursin(n, t), texts), names_)
    foreach(n -> println(io, "UNTESTED ", n), untested)
    println(io, "tdd.jl gaps: $(length(untested)) of $(length(names_)) exported/public name(s) of $name appear nowhere in test/.")
    return 0
end
