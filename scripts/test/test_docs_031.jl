# factory 0.3.1 findings 3, 5 and 6: documentation and text fixes, pinned as text assertions.
# Each testset names the phrase (or regex) the docs must hold; the wording around it is free.
#
#   F3  TDD roles had no way to report: a named TDD dispatch is a teammate, and TeammateIdle then
#       demands a SendMessage (disallowed for these roles) or a .lanes/reports/ file (outside test/**).
#       So the TDD roles are dispatched UNNAMED, as plain subagents; their final reply is the report.
#       Only the TDD roles: the other roles (those audited with `lane audit --report`) stay named.
#   F5  stale claims: agent types DO load mid-session; a `TDD: red` commit holds only items that fail
#       today; the audit commands use the owning repo's ledger (finding 2), not `<root>/...`.
#   F6  CHECK_COVERAGE gains two blind spots (sync_factory's T3 writes; discarding an applied sync
#       without T3), and factory/CHANGELOG.md gets a 0.3.1 note on `:doctest`/`:snapshot` (spec §3.4).
#
# The helpers take a path relative to ROOT (not the text), so a failure prints the path, not the file.

doc(rel) = read(joinpath(ROOT, rel), String)

"The doc at `rel` contains `pat` (a String or Regex)."
has(rel, pat) = occursin(pat, doc(rel))

"In the doc at `rel`, `b` matches within `n` characters after `a`, or `a` after `b` (case-insensitive)."
near(rel, a::Regex, b::Regex; n = 250) =
    has(rel, Regex(a.pattern * "[\\s\\S]{0,$n}?" * b.pattern, "i")) ||
    has(rel, Regex(b.pattern * "[\\s\\S]{0,$n}?" * a.pattern, "i"))

"The clauses of a markdown table/prose text: lines split at `;` and `|`."
clauses(text) = [strip(c) for l in split(text, '\n') for c in split(l, r"[;|]")]

"Some clause of docs/CHECK_COVERAGE.md holds both `a` and `b`."
coverage_clause(a, b) = any(c -> occursin(a, c) && occursin(b, c), clauses(doc("docs/CHECK_COVERAGE.md")))

"The argument strings of every inline `tdd.jl audit ...` command in the doc at `rel`."
audit_args(rel) = [String(m[1]) for m in eachmatch(r"tdd\.jl audit([^`]*)`", doc(rel))]

const SKILL_031 = ".claude/skills/lane-lifecycle/SKILL.md"
const TW_BODY_031 = ".agents/bodies/test_writer.md"
const IMPL_BODY_031 = ".agents/bodies/implementer.md"

@testset "docs 0.3.1 (findings 3, 5, 6)" begin
    @testset "F3: TDD roles are dispatched UNNAMED and their final reply is the report" begin
        # expected in the skill and both bodies: "unnamed" next to "dispatch"/"subagent", and
        # "final reply is the report" (or "... is your/their report")
        for rel in (SKILL_031, TW_BODY_031, IMPL_BODY_031)
            @testset "$rel says the TDD dispatch is unnamed" begin
                @test near(rel, r"\bunnamed\b", r"(dispatch|subagent)")
            end
            @testset "$rel says the final reply is the report" begin
                @test has(rel, r"final (reply|message) is (the|your|their|its) report"i)
            end
        end
        @testset "skill: the unnamed rule names every TDD role" begin
            # test-writer, the other test-side roles and the implementer, within 600 chars of "unnamed"
            for role in ("test-writer", "law-tester", "property-tester", "differential-tester", "implementer")
                @test near(SKILL_031, r"\bunnamed\b", Regex(role); n = 600)
            end
        end
    end

    @testset "F3: unnamed applies ONLY to the TDD roles; other roles are dispatched NAMED" begin
        # expected phrases: "only the TDD roles" (unnamed) and
        # "other roles (the ones `lane audit --report` checks) are dispatched named"
        @test near(SKILL_031, r"\bonly\b", r"\bTDD roles\b"; n = 120)
        @test near(SKILL_031, r"\bother roles\b", r"(?<!un)named\b")
        @test near(SKILL_031, r"lane audit[^`]*--report", r"(?<!un)named\b"; n = 400)
    end

    @testset "F3: the skill no longer recommends a `name` for TDD dispatches" begin
        # the 0.3.0 text "A `name` is allowed (`tw-<lane>-<task>`, `impl-<lane>-<task>`)" must go
        @test !has(SKILL_031, "A `name` is allowed")
        @test !has(SKILL_031, "tw-<lane>-<task>")
        @test !has(SKILL_031, "impl-<lane>-<task>")
    end

    @testset "F5: no claim that a new agent type needs a session restart" begin
        # agent types load mid-session: "not dispatchable until the session restarts" and
        # "restart the session before the first TDD dispatch" must go from the skill
        @test !has(SKILL_031, r"not dispatchable until the session restarts"i)
        @test !has(SKILL_031, r"restart the session before the first TDD dispatch"i)
    end

    @testset "F5: a `TDD: red` commit holds ONLY items that fail today" begin
        # expected in the test-writer body: "a `TDD: red` commit holds only items that fail today"
        @test near(TW_BODY_031, r"TDD: red", r"\bonly\b[^.]{0,80}\bfail"; n = 120)
        # and: behaviour the code already has goes in a separate `TDD: backfill` commit
        # (or is left to the existing tests): "already" within 200 chars of "TDD: backfill"/"existing tests"
        @test near(TW_BODY_031, r"\balready\b", r"(TDD: backfill|existing tests)"; n = 200)
    end

    @testset "F5: audit commands use the owning repo's ledger, never `<root>/.lanes/ledger.jsonl`" begin
        # finding 2: `tdd.jl audit` defaults to <owning repo main>/.lanes/ledger.jsonl (owning_ledger).
        # Today reviewer.md and /change-review pass `--ledger <root>/.lanes/ledger.jsonl` (the session
        # root's ledger: the coordinator's, for a subagent), and the skill a bare `tdd.jl audit --ledger`.
        # Expected: no `--ledger`, or `--ledger <owning repo main>/.lanes/ledger.jsonl` / `<main>/...`.
        for rel in (SKILL_031, IMPL_BODY_031, ".agents/bodies/reviewer.md", ".claude/commands/change-review.md")
            @testset "$rel" begin
                @test !has(rel, "--ledger <root>/")
                for args in audit_args(rel)
                    occursin("--ledger", args) || continue
                    @test occursin(r"--ledger\s+<(owning|main)"i, args)
                end
            end
        end
    end

    @testset "F6: CHECK_COVERAGE lists sync_factory's writes to T3 paths (no FACTORY_ALLOW_T3)" begin
        # expected blind spot (in .agents/checks.toml, regenerated into docs/CHECK_COVERAGE.md), one clause:
        # "sync_factory's own writes to T3 paths need no T3 (FACTORY_ALLOW_T3)"
        @test coverage_clause("sync_factory", r"\bT3\b")
    end

    @testset "F6: CHECK_COVERAGE lists that a teammate without T3 cannot discard an applied sync" begin
        # expected blind spot, one clause: "a teammate without T3 cannot discard an applied sync:
        # bash_guard blocks `git clean -f` and `git restore`/`checkout` of T3 paths"
        @test coverage_clause("git clean", r"\bsync\b"i)
        @test coverage_clause("git clean", r"restore|checkout")
    end

    @testset "F6: factory/CHANGELOG.md 0.3.1 notes :doctest/:snapshot are not tag-selectable on non-stable Julia" begin
        # factory/CHANGELOG.md exists only in the factory itself, not in a synced repo.
        log = joinpath(FACTORY, "CHANGELOG.md")
        if IN_FACTORY && isfile(log)
            m = match(r"\n## 0\.3\.1[^\n]*\n([\s\S]*?)(?=\n## |\z)", read(log, String))
            has_031_section = m !== nothing
            @test has_031_section   # expected heading: "## 0.3.1 (...)"
            if has_031_section
                sec = String(m[1])
                # expected: "`:doctest` and `:snapshot` cannot be selected by tag on non-stable Julia (spec §3.4)"
                @test occursin(":doctest", sec)
                @test occursin(":snapshot", sec)
                @test occursin(r"non-stable|stable-only|not (a )?stable"i, sec)
                @test occursin(r"\btags?\b"i, sec)
            end
        else
            @info "skipped: factory/CHANGELOG.md 0.3.1 check (not inside the factory; $log absent or IN_FACTORY=false)"
        end
    end
end
