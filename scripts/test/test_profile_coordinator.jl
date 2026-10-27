# Guard (factory 0.3.0, lane tw-032): the managed tests pass in a coordinator-profile sync.
#
# 0.3.0 shipped tests that read the HOST repo's seeded risk.toml (expecting `tdd` in T1-T3) and
# test/runtests.jl (the seeded package runner). A coordinator has neither: no `tdd` in its tiers
# (migration list) and no test/. The lead's coordinator synced to 0.3.0 had 20 fails and 35 errors
# (4 more fails there: its own risk.toml did not yet protect the tdd scripts); a fresh scratch
# coordinator sync had 16 fails and 35 errors in the whole suite, 16 and 30 in this guard's selection.
# This syncs the template into a scratch git repo with --profile coordinator and runs the
# scratch's own scripts/test/runtests.jl there on the files that exercise the seeded content,
# selected with FACTORY_TEST_ONLY (runtests.jl). Expects no Fail and no Error.
#
# Only inside factory/ (it needs the factory to sync from). Cost: by default (GUARD_DEFAULT below)
# about 30 s with the sync. FACTORY_GUARD_FULL=1 adds the tdd files that build scratch repos from
# the seeds; their package runs make it about 4.5 min (measured on 1.13, tw-032), over the suite's
# budget for one guard, so it is opt-in. Every factory change that touches scripts/test/ or the tdd
# scripts runs it before merge, with 0 fail and 0 error (factory/README.md "Test it").
# (test_tdd_c1/c2/c4/c5 need the hook tests' helpers, so they do not run alone; c5's seeded risk.toml
# comes through c3_repo, which test_tdd_c3.jl exercises.)
#
# factory 0.3.2 (lane tw-035): 0.3.1's test_ci_format.jl failed 3 times in the real coordinator
# (sync-031 evidence tests-8028094.txt) and passed here, because this scratch did not look like
# the coordinator: no vendored factory/ (whose template carries scripts/test/fixtures/) and no
# unformatted non-factory .jl files (contracts/*.jl, reference/prototype/**). The scratch now has
# both (vendor_factory!, contracts/bad.jl) and the guard runs test_ci_format.jl by default, with
# the other cheap files that read ROOT-relative host files (generated agents, docs): test_gen.jl
# and test_check_docs.jl. test_ci.jl (profile-aware reachability, checkout_profile) took 85 s
# there, so it is in the full list only. Measured on 1.13 (tw-035): the default selection's
# scratch run 22.4 s (19.6 s with test_dod.jl and test_ci_format.jl alone), the whole item 27.6 s.
const GUARD_DEFAULT = ["test_dod.jl", "test_ci_format.jl", "test_gen.jl", "test_check_docs.jl"]
const GUARD_FILES = get(ENV, "FACTORY_GUARD_FULL", "") == "1" ?
    [GUARD_DEFAULT; "test_ci.jl"; "test_tdd.jl"; "test_tdd_backfill.jl"; "test_tdd_review.jl"; "test_tdd_c3.jl"] :
    GUARD_DEFAULT

"Copy the factory (MANIFEST.toml, VERSION, profiles/, template/ with its fixtures) to `dst`, as the coordinator vendors it."
function vendor_factory!(dst)
    for (dir, dirs, files) in walkdir(FACTORY)
        filter!(d -> !(d in (".git", ".worktrees", ".lanes")), dirs)
        for f in files
            to = joinpath(dst, relpath(joinpath(dir, f), FACTORY))
            mkpath(dirname(to))
            cp(joinpath(dir, f), to)
        end
    end
    return dst
end

"`(pass, fail, error)` of the outermost `factory` row of a Test Summary in `out`, or nothing."
function factory_counts(out)
    lines = split(out, '\n')
    h = findlast(l -> startswith(l, "Test Summary:"), lines)
    (h === nothing || h == length(lines) || !startswith(lines[h + 1], "factory ")) && return nothing
    hl, vl = String(split(lines[h], '|')[2]), String(split(lines[h + 1], '|')[2])
    # Test prints each count right-aligned under its header word and omits a zero column's number:
    # a count is the text between the previous header word's end and this one's.
    words = [(m.match, m.offset + ncodeunits(m.match) - 1) for m in eachmatch(r"\S+", hl)]
    got = Dict{String, Int}()
    prev = 0
    for (w, e) in words
        s = strip(vl[(prev + 1):min(e, ncodeunits(vl))])
        got[w] = isempty(s) || w == "Time" ? 0 : parse(Int, s)
        prev = e
    end
    return (; pass = get(got, "Pass", 0), fail = get(got, "Fail", 0), error = get(got, "Error", 0))
end

"Print where the scratch run failed: each failing `file:line` with its count, then the first error."
function guard_report(txt)
    at = Dict{String, Int}()
    for m in eachmatch(r"(?:Test Failed|Error During Test) at \S*/scripts/test/(\S+)", txt)
        at[m.captures[1]] = get(at, m.captures[1], 0) + 1
    end
    println("coordinator-profile guard: failing sites in the scratch run")
    foreach(((k, v),) -> println("  $v  $k"), sort(collect(at); by = last, rev = true))
    e = findfirst("Error During Test", txt)
    e === nothing || println(first(SubString(txt, first(e)), 1200))
    return nothing
end

@testset "coordinator-profile sync, the dod, format and tdd tests pass there (tw-032, tw-035)" begin
    if !IN_FACTORY
        @test !IN_FACTORY
        @info "not inside factory/: the coordinator-profile guard needs the factory to sync from"
    else
        c = tmp_repo()
        rc, out = capture(() -> SyncFactory.main(["--from", FACTORY, "--to", c, "--profile", "coordinator", "--apply"]))
        @test rc == 0 || (print(out); false)
        @test !isdir(joinpath(c, "test"))                                            # the coordinator's shape
        # the rest of its shape (0.3.2): the vendored factory, and a host .jl file that is not Runic-clean
        vendor_factory!(joinpath(c, "factory"))
        @test isfile(joinpath(c, "factory", "template", "scripts", "test", "fixtures", "tdd", "scratchpkg", "test", "parse_tests.jl"))
        mkpath(joinpath(c, "contracts"))
        write(joinpath(c, "contracts", "bad.jl"), "x=[1,2 ,3]\n")
        sh(`git -C $c add -- .`)
        sh(`git -C $c commit -q -m sync`)
        log = joinpath(c, ".lanes", "guard.log")
        mkpath(dirname(log))
        # --color=no: a parent run with --color=yes passes it on, and escapes break the summary parse
        cmd = Cmd(`$JULIA --color=no scripts/test/runtests.jl`; dir = c)
        cmd = addenv(cmd, "FACTORY_TEST_ONLY" => join(GUARD_FILES, ","), "JULIA_PKG_OFFLINE" => "true")
        t = time()
        # one handle for both streams: two truncating opens of the same path overwrite each other
        ok = open(log, "w") do io
            success(pipeline(ignorestatus(cmd); stdout = io, stderr = io))
        end
        txt = read(log, String)
        n = factory_counts(txt)
        @info "coordinator-profile guard" seconds = round(time() - t; digits = 1) counts = n
        @test n !== nothing || (print(last(txt, 4000)); false)
        if n !== nothing
            @test n.pass > 0
            @test n.fail == 0 && n.error == 0 || (guard_report(txt); false)
            @test ok == (n.fail == 0 && n.error == 0) || (println("guard: exit status disagrees with the summary"); print(last(txt, 4000)); false)
        end
    end
end
