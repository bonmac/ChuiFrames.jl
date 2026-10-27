#!/usr/bin/env julia
# ci.jl: the ONE list of CI commands. GitHub workflows and local runs both call it, so a
# command is never copied into a Makefile or a second YAML file.
#
#   julia scripts/ci.jl --list                 jobs and the commands they run
#   julia scripts/ci.jl <job> [--dry-run] [--timeout SECONDS] [-- extra args]
#
# --timeout S (or env CI_TIMEOUT=S; 0.2.7) bounds the whole job: on expiry the running command's
# whole process group is killed, child julias of Pkg.test included, and ci.jl exits 124. This is
# the way to bound a run; `perl -e alarm` or `timeout` kill only the outer process.
#
# Jobs: setup, test, quality, jet, format, docs, contracts, bench, coverage, guards, dod.
# Extra args after `--` go to the job: `test -- laws property`, `contracts -- main`.
#
# A job that cannot run returns a Skip of one of three kinds (0.2.4: 0.2.3 printed "skipped" and
# exited 0 for all of them, so deleting test/jet/runjet.jl turned the jet job green):
#   not_applicable  the job does not apply to this repo (not a package)      exit 0
#   waiting         it applies but waits on something external (no upstream  exit 0, with a loud
#                   URL, no benchmark suite yet)                              NOT RUN notice
#   missing         a file the profile seeds or expects is gone               exit 1 (red)
module CI

    using TOML
    include(joinpath(@__DIR__, "_common.jl"))

    const PKG_TEST = "using Pkg; Pkg.test(; coverage = get(ENV, \"CI_COVERAGE\", \"false\") == \"true\", test_args = ARGS)"
    const RUNIC_ADD = "using Pkg; Base.find_package(\"Runic\") === nothing && Pkg.add(\"Runic\")"
    const RUNIC_RUN = "using Runic; exit(Runic.main(ARGS))"

    # Jobs with their own environment (docs/, test/jet/, test/contracts/) run from a TEMPORARY COPY
    # of its Project.toml: `ARGS = [env dir, scratch dir, mode]`. Pkg.develop of the checkout
    # (mode `develop`) or of upstream main (mode `main`) then writes only the copy. In place, Julia
    # >= 1.11 wrote `[sources] Pkg = {path = "/abs/..."}` into the tracked file, added the package
    # to [deps] and dropped its comments: the committed-develop-path hazard (common.md §2).
    # Relative `[sources]` paths are made absolute for the copy; Manifests are resolved afresh.
    const SCRATCH_ENV = """
    using Pkg, TOML
    src, dst, mode = ARGS[1], ARGS[2], get(ARGS, 3, "")
    proj = TOML.parsefile(joinpath(src, "Project.toml"))
    for s in values(get(proj, "sources", Dict()))
        s isa Dict && haskey(s, "path") && (s["path"] = abspath(src, s["path"]))
    end
    mkpath(dst)
    open(io -> TOML.print(io, proj), joinpath(dst, "Project.toml"), "w")
    Pkg.activate(dst)
    mode == "develop" && Pkg.develop(PackageSpec(path = pwd()))
    if mode == "main"
        for u in values(TOML.parsefile("test/contracts/upstreams.toml")["upstreams"])
            Pkg.add(url = u, rev = "main")
        end
    end
    Pkg.instantiate()
    """
    const SCRATCH = String[] # scratch environments of the running job, removed when it ends
    scratch_env() = (p = tempname(); push!(SCRATCH, p); p)
    "`julia` commands that resolve a scratch copy of env `dir` (in `mode`), then run `script` in it."
    function in_scratch(dir, script, mode = "")
        env = scratch_env()
        return [["julia", "-e", SCRATCH_ENV, "--", dir, env, mode], ["julia", "--project=$env", script]]
    end

    # A command is an argv whose first element "julia" is replaced by the running julia binary.
    const Argv = Vector{String}

    struct Job
        summary::String
        commands::Function # (root, extra) -> Vector{Argv}, or a Skip
    end

    "A job that did not run: `kind` is one of SKIP_KINDS (see the header), `why` says what is absent."
    struct Skip
        kind::Symbol
        why::String
        Skip(kind, why) = kind in SKIP_KINDS ? new(kind, why) : error("unknown skip kind $kind")
    end
    const SKIP_KINDS = (:not_applicable, :waiting, :missing)

    upstreams(root) = (
        p = joinpath(root, "test/contracts/upstreams.toml");
        isfile(p) ? get(TOML.parsefile(p), "upstreams", Dict()) : Dict()
    )
    "Top-level tables of upstreams.toml other than [upstreams] and [contract_files] (a typo would read as \"no upstreams\")."
    upstream_typos(root) = (
        p = joinpath(root, "test/contracts/upstreams.toml");
        isfile(p) ? sort!([k for k in keys(TOML.parsefile(p)) if !(k in ("upstreams", "contract_files"))]) : String[]
    )
    profile(root) = try
        string(get(factory_record(root), "profile", "none"))
    catch
        "unreadable"
    end
    "A package checkout: synced with the package profile, or a Project.toml at the root."
    is_package(root) = profile(root) == "package" || isfile(joinpath(root, "Project.toml"))
    """
        needs(root, files, cmds) -> commands or Skip

    `:not_applicable` outside a package; `:missing` (red) when one of `files`, which the package
    profile seeds (test/jet/*, test/contracts/*) or expects (docs/ for Docs.yml), is gone; else `cmds()`.
    """
    function needs(root, files, cmds)
        profile(root) == "unreadable" && return Skip(:missing, ".factory-version is not valid TOML, so the profile is unknown")
        is_package(root) || return Skip(:not_applicable, "not a Julia package (no Project.toml; profile `$(profile(root))`)")
        for f in files
            isfile(joinpath(root, f)) ||
                return Skip(:missing, "$f is missing, and the package profile seeds or expects it. Restore it (`julia scripts/sync_factory.jl --from <factory>` shows the seed)")
        end
        return cmds()
    end

    # Deliberately broken test fixtures (a ParseError on purpose); Runic 1.13 has no exclude option.
    const FORMAT_EXCLUDE = "scripts/test/fixtures/"
    """
        format_files(root) -> Vector{String}

    The `.jl` files the format job checks (factory 0.3.1): paths relative to `root`, sorted, each an
    existing file, minus everything under `$FORMAT_EXCLUDE`. In a git checkout: tracked plus
    untracked-but-not-ignored files (a fresh `git init` with nothing committed still counts);
    otherwise a walk of the tree that skips `.git`, `.worktrees` and `.lanes`. A bare "." made
    Runic walk into the fixtures and fail on their deliberate ParseError (0.3.0).
    """
    function format_files(root)
        listed = git(root, "ls-files", "-z", "--cached", "--others", "--exclude-standard", "--", "*.jl")
        rels = if listed === nothing
            out = String[]
            for (dir, dirs, files) in walkdir(root)
                filter!(d -> !(d in (".git", ".worktrees", ".lanes")), dirs)
                for f in files
                    push!(out, relpath(joinpath(dir, f), root))
                end
            end
            out
        else
            String.(split(listed, '\0'; keepempty = false))
        end
        rels = map(r -> replace(r, '\\' => '/'), rels)
        keep(r) = endswith(r, ".jl") && !startswith(r, FORMAT_EXCLUDE) && isfile(joinpath(root, r))
        return sort!(unique!(filter(keep, rels)))
    end

    const SETUP = "using Pkg; Pkg.Registry.add(\"General\"); u = get(ENV, \"ECOSYSTEM_REGISTRY_URL\", \"\"); isempty(u) || Pkg.Registry.add(Pkg.RegistrySpec(url = u))"

    const JOBS = Dict{String, Job}(
        "setup" => Job(
            "Add the General registry, plus the personal registry when ECOSYSTEM_REGISTRY_URL is set (ADR-0005).",
            (root, extra) -> [["julia", "-e", SETUP]]
        ),
        "test" => Job(
            "Unit tests via Pkg.test; extra args select tags (`all` = every tag).",
            (root, extra) -> [["julia", "--project=.", "-e", PKG_TEST, "--", extra...]]
        ),
        "jet" => Job(
            "JET in a scratch copy of test/jet/ (JET 0.12 needs Julia >= 1.12; run on stable only).",
            (root, extra) -> needs(
                root, ("test/jet/Project.toml", "test/jet/runjet.jl"),
                () -> in_scratch("test/jet", "test/jet/runjet.jl", "develop")
            )
        ),
        "quality" => Job(
            "Aqua and ExplicitImports test items (tag :quality). JET is the separate `jet` job.",
            (root, extra) -> [["julia", "--project=.", "-e", PKG_TEST, "--", "quality"]]
        ),
        "format" => Job(
            "Runic check (ADR-0007) of format_files(root): fails if any file is not formatted; skips $FORMAT_EXCLUDE.",
            (root, extra) -> (
                files = format_files(root);
                isempty(files) ? Skip(:not_applicable, "no .jl files to format outside $FORMAT_EXCLUDE") : [
                        ["julia", "--project=@runic", "-e", RUNIC_ADD],
                        ["julia", "--project=@runic", "-e", RUNIC_RUN, "--", "--check", "--diff", files...],
                    ]
            )
        ),
        "docs" => Job(
            "Build Documenter docs from a scratch copy of docs/ (doctests run in the test suite too).",
            (root, extra) -> needs(
                root, ("docs/Project.toml", "docs/make.jl"),
                () -> in_scratch("docs", "docs/make.jl", "develop")
            )
        ),
        "contracts" => Job(
            "Contract tests (tag :contract) in their own env test/contracts/ (a scratch copy): the latest upstream release, or `-- main`.",
            (root, extra) -> needs(
                root, ("test/contracts/upstreams.toml", "test/contracts/Project.toml", "test/contracts/runtests.jl"),
                () -> !isempty(upstream_typos(root)) ?
                    Skip(:missing, "test/contracts/upstreams.toml has unknown tables $(upstream_typos(root)) (expected [upstreams], [contract_files])") :
                    isempty(upstreams(root)) ?
                    Skip(:waiting, "no upstreams in test/contracts/upstreams.toml yet (no upstream URL; a root package has none)") :
                    in_scratch("test/contracts", "test/contracts/runtests.jl", "main" in extra ? "main" : "")
            )
        ),
        "bench" => Job(
            "Benchmark HEAD vs the merge base; fails beyond ratchets.toml bench.time_tolerance.",
            (root, extra) -> needs(
                root, (), () -> isfile(joinpath(root, "benchmark/benchmarks.jl")) ?
                    [["julia", "scripts/bench.jl", extra...]] : isdir(joinpath(root, "benchmark")) ?
                    Skip(:missing, "benchmark/ exists but benchmark/benchmarks.jl is missing") :
                    Skip(:waiting, "no benchmark suite yet (no benchmark/ directory)")
            )
        ),
        "coverage" => Job(
            "Check lcov.info (from julia-processcoverage) against the coverage floor.",
            (root, extra) -> [["julia", "scripts/ratchet.jl", "--lcov", isempty(extra) ? "lcov.info" : extra[1]]]
        ),
        "guards" => Job(
            "Factory guards: generated files, ratchets, doc references, doc claims, contract usage, factory tests.",
            (root, extra) -> [
                ["julia", "scripts/gen.jl", "--check"], ["julia", "scripts/ratchet.jl"],
                ["julia", "scripts/check_docs.jl"], ["julia", "scripts/check_claims.jl"],
                ["julia", "scripts/contract_usage.jl"],
                ["julia", "scripts/test/runtests.jl"],
            ]
        ),
        "dod" => Job(
            "Definition of done for a PR (PR_LABELS, PR_BODY_FILE, BASE_REF from the environment).",
            (root, extra) -> [
                [
                    "julia", "scripts/dod.jl", "--base", get(ENV, "BASE_REF", "main"),
                    "--labels", get(ENV, "PR_LABELS", ""),
                    (haskey(ENV, "PR_BODY_FILE") ? ["--body-file", ENV["PR_BODY_FILE"]] : String[])...,
                ],
            ]
        ),
    )

    function tocmd(argv::Argv, root)
        exe = first(argv) == "julia" ? [Base.julia_cmd().exec; "--startup-file=no"] : [first(argv)]
        return Cmd(Cmd([exe; argv[2:end]]); dir = root)
    end
    show_argv(argv) = join(
        (
            a == SCRATCH_ENV ? "<SCRATCH_ENV in scripts/ci.jl>" :
                occursin(r"[\s\"'$;&|]", a) ? repr(a) : a for a in argv
        ), ' '
    )

    "Print a skip by its kind; the exit status: 1 for :missing, else 0."
    function report_skip(name, s::Skip; io = stdout)
        if s.kind == :missing
            println(io, "ci.jl $name: FAILED (missing): ", s.why)
            return 1
        elseif s.kind == :waiting
            println(io, "ci.jl $name: NOT RUN (waiting): ", s.why, ". This job did not run: its exit 0 is not a pass.")
            get(ENV, "GITHUB_ACTIONS", "") == "true" && println(io, "::warning title=ci.jl $name did not run::", s.why)
            return 0
        end
        println(io, "ci.jl $name: skipped (not applicable): ", s.why)
        return 0
    end

    # --- time limit (0.2.7) ------------------------------------------------------------------
    # `perl -e 'alarm N; exec @ARGV' julia scripts/ci.jl test` kills only ci.jl: Pkg.test's child julia
    # keeps running (a hung property test ran ~6 h at 97% CPU). With a limit, each command starts
    # DETACHED (libuv setsid: its own session and process group, pgid = its pid), and on timeout the
    # whole group gets SIGTERM, then SIGKILL after KILL_GRACE seconds. Exit TIMEOUT_EXIT.
    const TIMEOUT_EXIT = 124      # as coreutils `timeout`
    const INTERRUPT_EXIT = 130    # 128 + SIGINT: Ctrl-C during a bounded run (review B2)
    const KILL_GRACE = 10.0
    killpg(pgid, sig) = ccall(:kill, Cint, (Cint, Cint), -pgid, sig)
    group_alive(pgid) = killpg(pgid, 0) == 0

    "The time limit in seconds: `--timeout S`, else `CI_TIMEOUT`, else `nothing`. An error for a bad value."
    function time_limit(opt)
        s = something(opt, get(ENV, "CI_TIMEOUT", ""))
        isempty(s) && return nothing
        t = tryparse(Float64, s)
        (t === nothing || !(t > 0) || !isfinite(t)) && error("time limit must be a positive number of seconds, got `$s`")
        return t
    end

    "Run `cmd` (stdout/stderr inherited) until `deadline` (time()); `:ok`, `:failed` or `:timeout`."
    function run_until(cmd::Cmd, deadline; io = stdout, grace = KILL_GRACE)
        # SIGINT must arrive as an InterruptException, not end the process before the group is killed.
        # Not restored afterwards (Julia has no getter for it): an in-process caller, such as the factory
        # tests, keeps Ctrl-C as an exception, which is the REPL's default anyway (review round-4 nit).
        Base.exit_on_sigint(false)
        p = run(pipeline(Cmd(cmd; detach = true, ignorestatus = true); stdout, stderr); wait = false)
        pgid = getpid(p)
        try
            while process_running(p) && time() < deadline
                sleep(0.1)
            end
        catch
            # review B2: Ctrl-C reaches ci.jl's process group only, never the detached one, so an
            # interrupt (main sets exit_on_sigint(false) under a limit) must take the group down here
            kill_group(p, pgid, grace)
            rethrow()
        end
        if !process_running(p)
            # the leader is done; anything it left behind in its group goes with it. Its pid cannot be
            # reused while that group still has members, so a live group here is still ours (review N5)
            Sys.iswindows() || (group_alive(pgid) && killpg(pgid, 9))
            return success(p) ? :ok : :failed
        end
        kill_group(p, pgid, grace)
        return :timeout
    end

    "SIGTERM the group, wait up to `grace` s, SIGKILL what is left, reap the leader."
    function kill_group(p, pgid, grace)
        if Sys.iswindows()
            kill(p, Base.SIGKILL)
        else
            killpg(pgid, 15)
            t = time() + grace
            while group_alive(pgid) && time() < t
                Libc.systemsleep(0.1)   # not `sleep`: no task switch, so a second Ctrl-C cannot cut this short
            end
            group_alive(pgid) && killpg(pgid, 9)
        end
        wait(p)
        return nothing
    end

    function run_job(name, root, extra; dry = false, io = stdout, timeout = nothing, grace = KILL_GRACE)
        haskey(JOBS, name) || (println(stderr, "ci.jl: unknown job `$name` (try --list)"); return 2)
        deadline = timeout === nothing ? Inf : time() + timeout
        try
            foreach(w -> println(io, "ci.jl $name: warning: ", w), env_warnings())
            cmds = JOBS[name].commands(root, extra)
            cmds isa Skip && return report_skip(name, cmds; io)
            for argv in cmds
                println(io, "ci.jl $name\$ ", show_argv(argv))
                dry && continue
                if timeout === nothing
                    ok = success(pipeline(tocmd(argv, root); stdout, stderr))
                    ok || (println(io, "ci.jl $name: FAILED"); return 1)
                else
                    r = try
                        run_until(tocmd(argv, root), deadline; io, grace)
                    catch e
                        e isa InterruptException || rethrow()
                        println(io, "ci.jl $name: INTERRUPTED: killed the command's whole process group. This is not a pass.")
                        return INTERRUPT_EXIT
                    end
                    r === :timeout && (
                        println(io, "ci.jl $name: TIMED OUT after $(timeout) s: killed the command's whole process group (SIGTERM, then SIGKILL after $(grace) s). This is not a pass."); return TIMEOUT_EXIT
                    )
                    r === :failed && (println(io, "ci.jl $name: FAILED"); return 1)
                end
            end
            dry || println(io, "ci.jl $name: OK")
            return 0
        finally
            foreach(p -> rm(p; force = true, recursive = true), SCRATCH)
            empty!(SCRATCH)
        end
    end

    function main(args)
        root = normpath(joinpath(@__DIR__, ".."))
        i = findfirst(==("--"), args)
        head, extra = i === nothing ? (args, String[]) : (args[1:(i - 1)], String.(args[(i + 1):end]))
        if head == ["--list"]
            for k in sort!(collect(keys(JOBS)))
                println(rpad(k, 10), JOBS[k].summary)
            end
            println("\nSkips: not_applicable (exit 0), waiting (exit 0, a loud NOT RUN notice), missing (exit 1).")
            return 0
        end
        usage = "usage: julia scripts/ci.jl <job> [--dry-run] [--timeout SECONDS] [-- args] | --list"
        opts, jobs = try
            parse_args(head, ("--dry-run",), ("--timeout",))
        catch e
            println(stderr, "ci.jl: ", e isa ErrorException ? e.msg : e, "\n", usage)
            return 2
        end
        timeout = try
            time_limit(get(opts, "--timeout", nothing))
        catch e
            println(stderr, "ci.jl: ", e.msg)
            return 2
        end
        length(jobs) == 1 || (println(stderr, usage); return 2)
        return run_job(only(jobs), root, extra; dry = haskey(opts, "--dry-run"), timeout)
    end

end # module

abspath(PROGRAM_FILE) == @__FILE__() && exit(CI.main(ARGS))
