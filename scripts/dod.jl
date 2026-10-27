#!/usr/bin/env julia
# dod.jl: the automated definition of done for a branch or PR.
#
#   julia scripts/dod.jl [--base main] [--head HEAD] [--labels T1,docs] [--body-file F | --body TEXT]
#
# Tier = max(the T0-T3 label, the tiers of the touched paths in risk.toml, default_tier).
# Each tier's `requires` (risk.toml) is checked:
#   ref        the PR body (or a commit message) names docs/superpowers/specs/ or plans/
#   spec       ... names docs/superpowers/specs/
#   tests      src/ or ext/ changed  =>  test/ changed
#   changelog  CHANGELOG.md changed, or a changelog.d/<name>.md fragment ADDED (0.2.4): lanes in one
#              repo then never share a file; the release manager folds the fragments into
#              CHANGELOG.md with `julia scripts/changelog.jl fold`. An added or modified fragment
#              holding a Markdown heading fails it (0.3.0): the fold refuses it (deleted: not checked)
#   adr        an NNNN-*.md file in the ADR directory (not the template) changed, or the body cites
#              ADR-NNNN. The directory is `adr_dir` in .factory-version (from the MANIFEST profile;
#              `adr` for the coordinator), default docs/adr; --adr-dir overrides it.
#   tdd        (0.3.0) the lane history passes H1-H9 (_tdd_history.jl, spec §4.2): its first problem
#              fails it; "no src/ext change" or "tdd history OK (N commits, mode M)" passes it
#   ci, review reported only: CI is the caller; review is branch protection's job
# In CI the labels and body come from the pull_request event (see .github/workflows/Guards.yml).
# Exit 0 = done, 1 = not done, 2 = could not evaluate.
module DoD

    using TOML
    include(joinpath(@__DIR__, "_common.jl"))
    # 0.3.0: LaneCommit, lane_commits, history_rules, stub_declares_only (needs _common.jl first).
    # Its short top-level names (changed, counts, clean, ...) are only shadowed by locals here.
    include(joinpath(@__DIR__, "_tdd_history.jl"))

    const TIERS = ("T0", "T1", "T2", "T3")
    tierindex(t) = findfirst(==(t), TIERS)

    function path_tier(risk, path)
        best = nothing
        for p in get(risk, "protected", Any[]), g in p["globs"]
            if globmatch(g, path) && (best === nothing || tierindex(p["tier"]) > tierindex(best))
                best = p["tier"]
            end
        end
        return best
    end

    "A changelog fragment: `changelog.d/<name>.md` (one level, not README.md, not a dotfile: what changelog.jl folds)."
    is_fragment(f) = occursin(r"^changelog\.d/[^/.][^/]*\.md$", f) && f != "changelog.d/README.md"

    # 0.3.0: a Markdown heading line, which `changelog.jl fold` refuses in a fragment. A DUPLICATE of the
    # regex in changelog.jl's `problems` (inline there, and `problems` reads the working tree, not
    # `head`); test_dod.jl checks the two patterns stay identical.
    const FRAGMENT_HEADING = r"^\s{0,3}#{1,6}(\s|$)"
    has_heading(text) = any(l -> occursin(FRAGMENT_HEADING, l), split(strip(text), '\n'))

    label_tier(labels) = (
        ts = filter(l -> l in TIERS, [replace(l, r"^tier:" => "") for l in labels]);
        isempty(ts) ? nothing : TIERS[maximum(tierindex.(ts))]
    )

    """
        evaluate(risk, changed, labels, text; commits, stub_ok) -> (tier, results)

    Pure core: `changed` is the list of changed paths, `text` the PR body plus commit messages.
    `commits` is the lane's `LaneCommit`s (oldest first) and `stub_ok(sha)` decides H5; with
    `commits === nothing` (or an empty list) a src/ext change fails `tdd`: it was not checked.
    `results` is a vector of (requirement, status, detail) with status :pass, :fail or :info.
    """
    function evaluate(
            risk, changed::Vector{<:AbstractString}, labels, text::AbstractString;
            kept::Vector{<:AbstractString} = changed, added::Vector{<:AbstractString} = kept,
            adr_dir::AbstractString = "docs/adr", commits = nothing, stub_ok::Function = _ -> true, segments = nothing,
            headed::Vector{<:AbstractString} = String[]   # added/modified fragments with a heading (fold refuses them)
        )
        lt = label_tier(labels)
        pts = filter(!isnothing, [path_tier(risk, f) for f in changed])
        candidates = String[risk["default_tier"]; pts]
        (lt === nothing || lt == "T0") || push!(candidates, lt)
        # A T0 label is trusted only when no touched path is protected.
        tier = (lt == "T0" && isempty(pts)) ? "T0" : TIERS[maximum(tierindex.(candidates))]
        results = Tuple{String, Symbol, String}[]
        if lt !== nothing && tierindex(lt) < tierindex(tier)
            push!(results, ("tier", :info, "label $lt raised to $tier by protected paths"))
        end
        # `changed` (every path, deletions included) sets the tier; `kept` (paths that still
        # exist) must carry the evidence, so deleting a test or the CHANGELOG proves nothing.
        src_changed = any(f -> startswith(f, "src/") || startswith(f, "ext/"), changed)
        for req in get(risk["tiers"][tier], "requires", String[])
            r = if req == "ref"
                occursin(r"docs/superpowers/(specs|plans)/", text) ? (:pass, "spec/plan referenced") :
                    (:fail, "link a spec or plan under docs/superpowers/ in the PR body, or label T0")
            elseif req == "spec"
                occursin(r"docs/superpowers/specs/", text) ? (:pass, "spec referenced") :
                    (:fail, "a $tier change must link its spec under docs/superpowers/specs/")
            elseif req == "tests"
                !src_changed ? (:pass, "no src/ or ext/ change") :
                    any(f -> startswith(f, "test/"), kept) ? (:pass, "test/ changed with src/") :
                    (:fail, "src/ or ext/ changed but nothing under test/ did")
            elseif req == "changelog"
                frag = filter(is_fragment, added)
                # checked first: the release fold would fail even when CHANGELOG.md changed too
                !isempty(headed) ? (:fail, "$(first(headed)) contains a Markdown heading, which `julia scripts/changelog.jl fold` refuses; write list items only (a bold lead-in, not a heading)") :
                    "CHANGELOG.md" in kept ? (:pass, "CHANGELOG.md changed") :
                    !isempty(frag) ? (:pass, "changelog fragment $(first(frag)) added") :
                    (:fail, "add a changelog.d/<lane>.md fragment (or a CHANGELOG.md entry under ## Unreleased)")
            elseif req == "adr"
                dir = rstrip(adr_dir, '/') * "/"
                adr = any(
                    f -> startswith(f, dir) && occursin(r"^\d{4}-.+\.md$", chopprefix(f, dir)) &&
                        !occursin("0000-template", f), kept
                )
                (adr || occursin(r"ADR-\d{4}", text)) ? (:pass, "ADR changed or cited") :
                    (:fail, "a T3 change needs an ADR ($dir or a cited coordinator ADR-NNNN)")
            elseif req == "tdd"
                tdd_result(commits, src_changed, stub_ok, segments)
            elseif req == "ci"
                (:info, "CI is the caller")
            elseif req == "review"
                (:info, "review approval is enforced by branch protection, not here")
            else
                (:fail, "unknown requirement `$req` in risk.toml")
            end
            push!(results, (req, r...))
        end
        return tier, results
    end

    "Requirement `tdd`: H9 applies to every lane, H2-H8 only when code changed (spec §4.2 H1)."
    function tdd_result(commits, src_changed, stub_ok, segments = nothing)
        # review B3 / minor 5: code changed and no history to check is a failure, never a pass or info
        commits === nothing &&
            return src_changed ? (:fail, "not checked: no lane history given") : (:pass, "no src/ext change")
        src_changed && isempty(commits) && return (:fail, "src/ or ext/ changed but no lane commits were found")
        problems = segment_rules(something(segments, [commits]); stub_ok)   # critic C6: per merged sub-lane
        isempty(problems) || return (:fail, first(problems))
        src_changed || return (:pass, "no src/ext change")
        return (:pass, "tdd history OK ($(length(commits)) commits, mode $(first(lane_mode(commits))))")
    end

    function main(args)
        root = normpath(joinpath(@__DIR__, ".."))
        opts, _ = try
            parse_args(args, (), ("--base", "--head", "--labels", "--body", "--body-file", "--root", "--adr-dir"))
        catch e
            println(stderr, "dod.jl: ", e isa ErrorException ? e.msg : e)
            return 2
        end
        root = abspath(get(opts, "--root", root))
        base = get(opts, "--base", "main")
        head = get(opts, "--head", "HEAD")
        labels = filter(!isempty, strip.(split(get(opts, "--labels", get(ENV, "PR_LABELS", "")), ',')))
        body = haskey(opts, "--body-file") ? read(opts["--body-file"], String) : get(opts, "--body", "")
        mb = merge_base(root, base, head)
        note = base_note(root, base)   # 0.2.7: say when a local branch stands in for `origin/<b>`
        note === nothing || println("dod.jl: ", note)
        if mb === nothing
            println(stderr, "dod.jl: no merge base between $base and $head")
            return 2
        end
        # --no-renames: a moved protected file counts at its old path too
        names(args...) = String.(filter!(!isempty, split(something(git(root, "diff", "--name-only", "--no-renames", args..., mb, head), ""), '\n')))
        changed = names()
        kept = names("--diff-filter=d")
        # an empty fragment would never reach CHANGELOG.md (changelog.jl fold refuses it): not evidence
        frag_text(f) = something(git(root, "show", "$head:$f"), "")
        added = filter(f -> !is_fragment(f) || !isempty(strip(frag_text(f))), names("--diff-filter=A"))
        # 0.3.0: fold refuses these; added OR modified (kept = not deleted), so an edit cannot sneak one in
        headed = filter(f -> is_fragment(f) && has_heading(frag_text(f)), kept)
        msgs = something(git(root, "log", "--format=%B", "$mb..$head"), "")
        risk = TOML.parsefile(joinpath(root, "risk.toml"))
        # lane_commits reads base..head (review B3); an empty list (tdd fails on a src change) when none
        commits = something(lane_commits(root, base, head), LaneCommit[])
        tier, results = evaluate(
            risk, changed, labels, body * "\n" * msgs; kept, added,
            adr_dir = haskey(opts, "--adr-dir") ? opts["--adr-dir"] : adr_dir(root),
            commits, stub_ok = s -> stub_declares_only(root, s), headed, segments = lane_segments(root, base, commits, head)
        )
        println("dod.jl: $(length(changed)) files changed since $(first(mb, 10)); tier $tier")
        for (req, st, detail) in results
            println("  [", st == :pass ? "PASS" : st == :fail ? "FAIL" : "info", "] ", rpad(req, 10), detail)
        end
        ok = !any(r -> r[2] == :fail, results)
        println(ok ? "dod.jl: DONE" : "dod.jl: NOT DONE")
        return ok ? 0 : 1
    end

end # module

abspath(PROGRAM_FILE) == @__FILE__() && exit(DoD.main(ARGS))
