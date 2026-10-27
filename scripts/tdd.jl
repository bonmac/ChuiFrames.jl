#!/usr/bin/env julia
# tdd.jl: test-first lanes (factory 0.3.0; spec 2026-10-26 §0.4, §3, §4.1).
#
#   julia scripts/tdd.jl red    [--root DIR] [--rev REV]      classify a RED/TEST-FIX commit's items
#   julia scripts/tdd.jl green  [--root DIR] [--base B]       the lane's red items pass, then the default suite
#   julia scripts/tdd.jl api    [--root DIR]                  docstrings of exported/public names (Julia >= 1.11)
#   julia scripts/tdd.jl brief  --role R [--root DIR] [--base B]   header + api + stub diffs; saves it
#   julia scripts/tdd.jl audit  [--root DIR] [--base B] [--ledger PATH]   history H1-H9, evidence E1-E5
#   julia scripts/tdd.jl mutate [--root DIR] --item NAME (--src F:LINE | --expect F:LINE) --from S --to S
#   julia scripts/tdd.jl gaps   [--root DIR]                  public names with no test (Julia >= 1.11)
#   (mutate and gaps: scripts/_tdd_backfill.jl; mutate is run by the mutator agent, spec §5.2)
#
# Exit: 0 OK, 1 NOT OK, 2 could not evaluate (a dirty tree, a bad argument, a red commit with no
# @testitem). Runs go through `julia scripts/ci.jl test -- item=<name> ...` in DIR, recorded by
# evidence.jl as `.lanes/evidence/<red|green>-<sha7>.txt` with the classifier report appended under
# `--- tdd ---`. The run is bounded only by ci.jl itself (`CI_TIMEOUT` in the environment): tdd.jl
# never passes its own `--timeout`, so it never overrides the caller's bound.
module Tdd

    using TOML
    include(joinpath(@__DIR__, "_common.jl"))
    include(joinpath(@__DIR__, "_tdd_classify.jl"))
    include(joinpath(@__DIR__, "_tdd_history.jl"))
    include(joinpath(@__DIR__, "_tdd_evidence.jl"))   # E1-E5, the ledger, audit (split for the line budget)
    include(joinpath(@__DIR__, "evidence.jl"))   # module Tdd.Evidence
    include(joinpath(@__DIR__, "_tdd_backfill.jl"))

    const ROLES = (TEST_ROLES..., "implementer")   # critic C1: the test-side roles of _tdd_history.jl
    const RED_PHASES = ("red", "test-fix")

    # -----------------------------------------------------------------------------------------
    # Git helpers

    is_dirty(root) = !isempty(something(git(root, "status", "--porcelain"), ""))
    "The `TDD:` trailer of commit `rev` (`\"\"` when it has none)."
    phase(root, rev) = git_trailer(root, rev, "TDD")   # git's parse, as lane_commits and the post hook (critic C2)
    "The shas of the non-merge commits in `base..HEAD`, oldest first; `nothing` when `base` has no merge
    base with HEAD. (`lane_commits` in _tdd_history.jl returns them as `LaneCommit`s.)"
    function lane_shas(root, base)
        mb = merge_base(root, base)
        mb === nothing && return nothing
        return split(something(git(root, "rev-list", "--no-merges", "--reverse", "$mb..HEAD"), ""), '\n'; keepempty = false)
    end
    lane_shas(root, base, phases) = (cs = lane_shas(root, base); cs === nothing ? nothing : filter(c -> phase(root, c) in phases, cs))
    "The root of the main checkout of the repo that owns `root` (a worktree's `.git` file names it)."
    function main_checkout(root)
        common = git(root, "rev-parse", "--git-common-dir")
        common === nothing && return nothing
        return realpath(dirname(abspath(joinpath(root, common))))
    end
    "The spans of the items named `names` in the test files at `rev`."
    function spans_at(root, rev, names)
        files = filter(_is_test_file, split(something(git(root, "ls-tree", "-r", "--name-only", rev), ""), '\n'; keepempty = false))
        return ItemSpan[s for f in files for s in item_spans(_show(root, rev, f), f) if s.name in names]
    end

    function refuse_dirty(root, io, what)
        is_dirty(root) || return false
        println(io, "tdd.jl $what: the tree at $root has uncommitted changes; commit or discard them first (exit 2).")
        return true
    end

    # -----------------------------------------------------------------------------------------
    # Runs

    julia_exe() = joinpath(Sys.BINDIR, Base.julia_exename())

    """
        run_items(root, kind, names; io) -> (code, termsignal, output, matched, path)

    `julia scripts/ci.jl test -- item=<name>...` in `root` (no names: the default suite), recorded as
    evidence `kind`. TDD_MATCHED points at a temporary file outside the tree.
    """
    function run_items(root, kind, names; io)
        matched_file = tempname()
        touch(matched_file)
        argv = String[julia_exe(), "--startup-file=no", joinpath("scripts", "ci.jl"), "test"]
        isempty(names) || append!(argv, ["--"; ["item=$n" for n in names]])
        code = withenv("TDD_MATCHED" => matched_file) do
            Evidence.run_evidence(root, kind, argv; io)
        end
        matched = Set{String}(filter!(!isempty, readlines(matched_file)))
        rm(matched_file; force = true)
        path = joinpath(Evidence.evidence_dir(root), "$kind-$(first(Evidence.head_sha(root), 7)).txt")
        h = something(Evidence.header(path), Dict{String, String}())
        sig = something(tryparse(Int, get(h, "termsignal", "0")), 0)
        return (code = code, termsignal = sig, output = Evidence.output(path), matched = matched, path = path)
    end

    "Append `--- tdd ---` and `lines` (the classifier report) to the evidence file, and print them on `io`."
    function append_tdd(path, report_text; io)
        open(f -> (println(f, "--- tdd ---"); print(f, report_text)), path, "a")
        println(io, "--- tdd ---")
        print(io, report_text)
        return nothing
    end

    have_ci(root, io, what) = isfile(joinpath(root, "scripts", "ci.jl")) ||
        (println(io, "tdd.jl $what: $(joinpath(root, "scripts", "ci.jl")) is missing (exit 2)."); false)

    # -----------------------------------------------------------------------------------------
    # red

    """
        red(root; rev = "HEAD", io) -> exit code

    Classify the items commit `rev` (a `red`/`test-fix` commit) added or changed: 0 iff every one
    fails for the right reason (ASSERTION or BEHAVIOUR) and nothing else broke.
    """
    function red(root; rev = "HEAD", io = stdout)
        refuse_dirty(root, io, "red") && return 2
        sha = git(root, "rev-parse", "--verify", "--quiet", "$rev^{commit}")
        sha === nothing && (println(io, "tdd.jl red: `$rev` is not a commit in $root (exit 2)."); return 2)
        # review B2: the run is of the tree at HEAD and its evidence is red-<HEAD sha7>, so `rev` must be HEAD
        sha == Evidence.head_sha(root) ||
            (println(io, "tdd.jl red: `$rev` ($(first(sha, 7))) is not HEAD; check it out (detached) and run red there (exit 2)."); return 2)
        p = phase(root, sha)
        p in RED_PHASES || (println(io, "tdd.jl red: $(first(sha, 7)) has trailer `TDD: $p`, not red or test-fix (exit 2)."); return 2)
        req = requested(root, sha)
        isempty(req.red) && (println(io, "tdd.jl red: $(first(sha, 7)) adds or changes no @testitem (exit 2)."); return 2)
        have_ci(root, io, "red") || return 2
        names = unique!([s.name for s in vcat(req.red, req.must_pass)])
        r = run_items(root, "red", names; io)
        result = classify(r.output, req.red, req.must_pass, r.matched; termsignal = r.termsignal)
        ok = red_ok(result)
        buf = IOBuffer()
        println(buf, "red $(first(sha, 7)): ", ok ? "OK" : "NOT OK", " (run exit $(r.code))")
        report(buf, result, headers(r.output))
        append_tdd(r.path, String(take!(buf)); io)
        return ok ? 0 : 1
    end

    # -----------------------------------------------------------------------------------------
    # green

    """
        renamed_by(root, commits, name) -> sha or nothing

    The test-fix that frees red item `name`, gone at HEAD (plan Task 9 ruling): a commit after the
    last red/test-fix requesting `name`, with trailer `TDD: test-fix`, authored by the test-writer,
    that removes `name`, has red items of its own (the new name) and passing red evidence (E1's
    `red_pass` plus `red <sha7>: OK`). Anything else (another author or phase, no evidence, a
    deletion with no replacement) frees nothing.
    """
    function renamed_by(root, commits, name)
        i = findlast(c -> c.phase in RED_PHASES && any(s -> s.name == name, requested(root, c.sha).red), commits)
        i === nothing && return nothing
        for c in commits[(i + 1):end]
            (c.phase == "test-fix" && c.author in role_author.(TEST_ROLES)) || continue
            isempty(spans_at(root, "$(c.sha)^", [name])) && continue   # not the commit that removed it
            isempty(spans_at(root, c.sha, [name])) || continue
            isempty(requested(root, c.sha).red) && continue            # no replacement
            ev = evidence_file(joinpath(Evidence.evidence_dir(root), "red-$(sha7(c.sha)).txt"))
            red_pass(ev, c.sha) && occursin(Regex("(?m)^red $(sha7(c.sha)): OK\\b"), ev.tdd) && return c.sha
        end
        return nothing
    end

    """
        green(root; base = "main", io) -> exit code

    The items of every `red`/`test-fix` commit in `base..HEAD` must all be selected and pass, with a
    `Test Summary:` total of at least their count; then the default suite must pass. Evidence `green`.
    An item gone at HEAD is NOT-RUN unless a test-writer test-fix renamed it (`renamed_by`); then
    it is dropped and reported as `RENAMED`.
    """
    function green(root; base = "main", io = stdout)
        refuse_dirty(root, io, "green") && return 2
        commits = lane_commits(root, base)
        commits === nothing && (println(io, "tdd.jl green: no merge base with `$base` in $root (exit 2)."); return 2)
        have_ci(root, io, "green") || return 2
        names = unique!([s.name for c in commits if c.phase in RED_PHASES for s in requested(root, c.sha).red])
        buf = IOBuffer()
        present = Set(s.name for s in spans_at(root, "HEAD", names))
        for n in filter(!in(present), names)
            fix = renamed_by(root, commits, n)
            fix === nothing && continue
            println(buf, "RENAMED  $n (test-fix $(sha7(fix)))")
            filter!(!=(n), names)
        end
        if !isempty(names)
            spans = spans_at(root, "HEAD", names)
            r = run_items(root, "green", names; io)
            got = classify(r.output, spans, ItemSpan[], r.matched; termsignal = r.termsignal)
            # a name not selected is NOT-RUN even when the run printed no summary (a vacuous run)
            result = Pair{String, Symbol}[(p.first in names && !(p.first in r.matched) ? p.first => NOT_RUN : p) for p in got]
            for n in names
                any(s -> s.name == n, spans) || push!(result, n => NOT_RUN)   # gone at HEAD
            end
            tt = Evidence.test_totals(r.output)
            total = tt === nothing ? 0 : tt["total"]
            items_ok = r.code == 0 && total >= length(names) && all(p -> p.second === :PASSED, result)
            println(buf, "green items: ", items_ok ? "OK" : "NOT OK", " ($(length(names)) red item(s), run exit $(r.code), total $total)")
            report(buf, result, headers(r.output))
            if !items_ok
                append_tdd(r.path, String(take!(buf)); io)
                return 1
            end
            item_out = r.output
        else
            println(buf, "green items: none (no red or test-fix commit in $base..HEAD)")
            item_out = ""
        end
        d = run_items(root, "green", String[]; io)          # the default suite; replaces the file
        suite_ok = d.code == 0 && d.termsignal == 0 && occursin("Test Summary:", d.output)
        println(buf, "green default suite: ", suite_ok ? "OK" : "NOT OK", " (exit $(d.code))")
        isempty(item_out) || open(f -> (println(f, "--- item run ---"); print(f, item_out)), d.path, "a")
        append_tdd(d.path, String(take!(buf)); io)
        return suite_ok ? 0 : 1
    end

    # -----------------------------------------------------------------------------------------
    # api

    # Runs in a subprocess with the package's project active. It prints the raw docstring text kept
    # in the module's docs table (`Docs.doc` needs the REPL stdlib), never Julia's fallback text,
    # which lists methods and their files.
    const API_SCRIPT = raw"""
    pkg = Symbol(ARGS[1])
    @eval using $pkg
    M = getfield(Main, pkg)
    meta = Base.Docs.meta(M)
    for n in sort!(names(M); by = string)
        n === nameof(M) && continue
        println("## ", n, "\n")
        md = get(meta, Base.Docs.Binding(M, n), nothing)
        texts = md === nothing ? String[] : [strip(join(string.(ds.text))) for ds in values(md.docs)]
        println(isempty(texts) ? "(no docstring)" : join(texts, "\n\n"), "\n")
    end
    """

    """
        api(root; io) -> exit code

    `## name` and the docstring of each exported or `public` name of the package at `root`, never
    method source. Julia >= 1.11 (`public`, `Docs.hasdoc`); on older Julia it prints NOT RUN, exit 2.
    """
    function api(root; io = stdout)
        if VERSION < v"1.11"
            println(io, "tdd.jl api: NOT RUN: needs Julia >= 1.11 (this is $VERSION).")
            return 2
        end
        proj = joinpath(root, "Project.toml")
        name = isfile(proj) ? get(TOML.parsefile(proj), "name", nothing) : nothing
        name === nothing && (println(io, "tdd.jl api: no package name in $proj (exit 2)."); return 2)
        out, err = IOBuffer(), IOBuffer()
        cmd = Cmd(`$(julia_exe()) --startup-file=no --project=$root -e $API_SCRIPT $name`; dir = root, ignorestatus = true)
        p = run(pipeline(cmd; stdout = out, stderr = err); wait = true)
        if !success(p)
            println(io, "tdd.jl api: loading $name failed (exit $(p.exitcode)):")
            print(io, String(take!(err)))
            return 1
        end
        print(io, String(take!(out)))
        return 0
    end

    # -----------------------------------------------------------------------------------------
    # brief

    "The next free `<dir>/<role>-<n>.md`."
    function next_brief(dir, role)
        taken = [something(tryparse(Int, m.captures[1]), 0) for f in (isdir(dir) ? readdir(dir) : String[])
                     for m in (match(Regex("^" * role * raw"-(\d+)\.md$"), f),) if m !== nothing]
        return joinpath(dir, "$role-$(maximum(taken; init = 0) + 1).md")
    end

    """
        brief(root; role, base = "main", io) -> exit code

    The brief for a dispatch of `role` on the lane at `root` (spec §0.4): the header line, then for a
    test-writer `## Public API` and `## Stub diffs` (each stub must pass H5, else exit 1 naming it),
    for an implementer `## Red tests` and `## Red evidence`. Saved to
    `<main>/.lanes/briefs/<lane>/<role>-<n>.md`; the lead adds the task text and the rest.
    """
    function brief(root; role, base = "main", io = stdout)
        role in ROLES || (println(io, "tdd.jl brief: --role must be one of $(join(ROLES, ", ")), got `$role` (exit 2)."); return 2)
        refuse_dirty(root, io, "brief") && return 2
        head = Evidence.head_sha(root)
        main = main_checkout(root)
        commits = lane_shas(root, base)
        (head === nothing || main === nothing || commits === nothing) &&
            (println(io, "tdd.jl brief: $root is not a git checkout with a merge base with `$base` (exit 2)."); return 2)
        checkout = abspath(root)
        lane = basename(rstrip(checkout, '/'))
        b = IOBuffer()
        println(b, "<!-- tdd-brief role=$role lane=$lane checkout=$checkout head=$head -->")
        println(b, "## Task\n\n(the lead pastes the plan task text here)\n\n## Spec\n\n(the lead names the spec path here)\n")
        if role != "implementer"   # a test-side role (critic C1) gets the test-writer's brief
            stubs = filter(c -> phase(root, c) == "stub", commits)
            bad = filter(c -> !stub_declares_only(root, c), stubs)
            if !isempty(bad)
                println(io, "tdd.jl brief: stub commit(s) fail H5 (declarations only): ", join(first.(bad, 7), ", "), ". Nothing saved (exit 1).")
                return 1
            end
            println(b, "## Public API\n")
            a = IOBuffer()
            code = api(root; io = a)
            print(b, String(take!(a)))
            code == 0 || println(b, "(tdd.jl api exited $code)")
            println(b, "\n## Stub diffs\n")
            isempty(stubs) && println(b, "(no `TDD: stub` commit in $base..HEAD)")
            for c in stubs
                println(b, "```diff")
                println(b, something(git(root, "show", "--no-color", c), "(git show $c failed)"))
                println(b, "```\n")
            end
            println(b, "## Test-fix requests\n\n(verbatim, if any; the lead pastes them)\n")
        else
            reds = filter(c -> phase(root, c) in RED_PHASES, commits)
            println(b, "## Red tests\n")
            isempty(reds) && println(b, "(no red or test-fix commit in $base..HEAD)")
            for c in reds
                files = filter(_is_test_file, split(something(git(root, "diff-tree", "--no-commit-id", "--name-only", "-r", c), ""), '\n'; keepempty = false))
                println(b, "- ", c, " (", phase(root, c), "): ", join(files, ", "))
            end
            println(b, "\n## Red evidence\n")
            for c in reds
                ev = joinpath(Evidence.evidence_dir(checkout), "red-$(first(c, 7)).txt")
                println(b, "- ", c, ": ", isfile(ev) ? ev : "(none: run `julia scripts/tdd.jl red --rev $(first(c, 7))`)")
            end
            println(b)
        end
        println(b, "## Boundary\n\n(spec §0.4 and §0.6, quoted by the lead)")
        text = String(take!(b))
        dir = joinpath(main, ".lanes", "briefs", lane)
        mkpath(dir)
        path = next_brief(dir, role)
        write(path, text)
        print(io, text)
        println(io, "tdd.jl brief: saved ", path)
        return 0
    end

    # -----------------------------------------------------------------------------------------
    # CLI

    const USAGE = """
    usage: julia scripts/tdd.jl red   [--root DIR] [--rev REV]
           julia scripts/tdd.jl green [--root DIR] [--base B]
           julia scripts/tdd.jl api   [--root DIR]
           julia scripts/tdd.jl brief --role test-writer|implementer [--root DIR] [--base B]
           julia scripts/tdd.jl audit [--root DIR] [--base B] [--ledger PATH]
           julia scripts/tdd.jl mutate [--root DIR] --item NAME (--src F:LINE | --expect F:LINE) --from S --to S
           julia scripts/tdd.jl gaps  [--root DIR]"""

    function main(args; io = stdout)
        opts, pos = try
            parse_args(args, (), ("--root", "--rev", "--base", "--role", "--ledger", "--item", "--src", "--expect", "--from", "--to"))
        catch e
            println(io, "tdd.jl: ", e isa ErrorException ? e.msg : e, "\n", USAGE)
            return 2
        end
        length(pos) == 1 || (println(io, USAGE); return 2)
        root = abspath(get(opts, "--root", normpath(joinpath(@__DIR__, ".."))))
        base = get(opts, "--base", "main")
        cmd = only(pos)
        allowed = Dict("red" => ("--root", "--rev"), "green" => ("--root", "--base"), "api" => ("--root",), "brief" => ("--root", "--base", "--role"), "audit" => ("--root", "--base", "--ledger"),
            "mutate" => ("--root", "--item", "--src", "--expect", "--from", "--to"), "gaps" => ("--root",))
        haskey(allowed, cmd) || (println(io, "tdd.jl: unknown command `$cmd`\n", USAGE); return 2)
        extra = setdiff(keys(opts), allowed[cmd])
        isempty(extra) || (println(io, "tdd.jl $cmd: unexpected option(s) $(join(sort!(collect(extra)), ", "))\n", USAGE); return 2)
        cmd == "red" && return red(root; rev = get(opts, "--rev", "HEAD"), io)
        cmd == "green" && return green(root; base, io)
        cmd == "api" && return api(root; io)
        cmd == "audit" && return audit(root; base, ledger = get(opts, "--ledger", nothing), io)
        cmd == "gaps" && return gaps(root; io)
        if cmd == "mutate"
            need = filter(k -> !haskey(opts, k), ["--item", "--from", "--to"])
            isempty(need) || (println(io, "tdd.jl mutate: missing $(join(need, ", "))\n", USAGE); return 2)
            return mutate(root; item = opts["--item"], src = get(opts, "--src", nothing), expect = get(opts, "--expect", nothing), from = opts["--from"], to = opts["--to"], io)
        end
        haskey(opts, "--role") || (println(io, "tdd.jl brief: --role is required\n", USAGE); return 2)
        return brief(root; role = opts["--role"], base, io)
    end

end # module

abspath(PROGRAM_FILE) == @__FILE__() && exit(Tdd.main(ARGS))
