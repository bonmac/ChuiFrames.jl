# factory 0.3.0 (plan Task 9): the test-writer role, the narrowed implementer, bodies, the
# lane-lifecycle brief templates, /change-review, CLAUDE.md, VERSION and CHANGELOG.
# Spec: docs/superpowers/specs/2026-10-26-factory-test-writer-design.md (§0.4, §2.1–2.3, §4.5, §6, §9.2).
# Included from the end of test_gen.jl.

"Frontmatter of a rendered agent file as key => value (the text between the first two `---` lines)."
function agent_frontmatter(path)
    lines = split(read(path, String), '\n')
    @assert strip(lines[1]) == "---"
    stop = findnext(l -> strip(l) == "---", lines, 2)
    fm = Dict{String, String}()
    for l in lines[2:(stop - 1)]
        m = match(r"^([A-Za-z_]+):\s*(.*)$", l)
        m === nothing || (fm[m.captures[1]] = m.captures[2])
    end
    return fm
end
"A comma-separated frontmatter list (`tools: Read, Grep`) as a vector of names."
fm_list(fm, k) = haskey(fm, k) ? String.(strip.(split(fm[k], ','))) : String[]
registry_agent(reg, slug) = only(filter(a -> a["slug"] == slug, reg["agents"]))
readroot(rel) = read(joinpath(ROOT, rel), String)
"The text of the `## <ver>` section of a changelog, up to the next `## ` heading."
function changelog_section(txt, ver)
    m = match(Regex("(?ms)^## " * replace(ver, "." => "\\.") * "\\b.*?(?=^## |\\z)"), txt)
    return m === nothing ? "" : m.match
end

@testset "factory 0.3.0: test-writer role" begin
    reg = TOML.parsefile(joinpath(ROOT, ".agents/agent-registry.toml"))

    # The registry, AGENTS.md, CLAUDE.md and the rendered agents are seeded or generated from the
    # seeded registry: in a synced repo (IN_FACTORY false) they are the repo's own, so the checks
    # that pin template content run only in the factory. Managed files (bodies, skill, command) are
    # checked everywhere.
    @testset "registry has 13 agents including test-writer" begin
        slugs = [a["slug"] for a in reg["agents"]]
        @test allunique(slugs)
        @test isfile(joinpath(ROOT, ".agents/bodies/test_writer.md"))
        if IN_FACTORY
            @test length(reg["agents"]) == 13
            @test "test_writer" in slugs
            @test isfile(joinpath(ROOT, ".claude/agents/test-writer.md"))
            @test isfile(joinpath(ROOT, ".codex/agents/test_writer.toml"))
        end
    end

    IN_FACTORY && @testset "test_writer registry entry is the spec §2.1 entry" begin
        # an absent entry reads as empty fields, so each assertion fails on its own
        tw = get(Dict(a["slug"] => a for a in reg["agents"]), "test_writer", Dict{String, Any}())
        f(k, d = "") = get(tw, k, d)
        @test f("name") == "test-writer"
        @test f("model") == "inherit"
        @test f("color") == "yellow"
        @test f("default_mode") == "write"
        @test f("tools", []) == ["Read", "Grep", "Glob", "Bash", "Edit", "Write"]
        @test f("disallowed_tools", []) == ["Agent", "Task", "SendMessage", "WebFetch", "WebSearch", "NotebookEdit"]
        @test f("file_scope", []) == ["test/**"]
        @test startswith(f("role"), "Writes unit and example tests from the spec, plan and public API")
        @test occursin("never sees the implementation", f("role"))
        @test occursin("tdd-brief", f("description"))
        @test any(s -> occursin("tdd.jl red", s), f("scorecard", []))
        @test any(s -> occursin("commits authored test-writer", s), f("scorecard", []))
        @test occursin("tdd.jl red output", f("output_format"))
    end

    IN_FACTORY && @testset "implementer file_scope has no test/**" begin
        im = registry_agent(reg, "implementer")
        @test im["file_scope"] == ["src/**", "ext/**", "changelog.d/**"]
        @test !any(g -> startswith(g, "test"), im["file_scope"])
        @test get(im, "tools", nothing) == ["Read", "Grep", "Glob", "Bash", "Edit", "Write", "WebFetch", "WebSearch"]
        @test get(im, "disallowed_tools", nothing) == ["Agent", "Task", "SendMessage"]
        @test im["role"] == "Implements one planned task against the test-writer's red tests: minimal code to green, then refactor with tests unchanged."
        @test any(s -> occursin("tdd.jl audit OK", s), im["scorecard"])
        @test !any(s -> occursin("failing test written first", s), im["scorecard"])
        # the rendered file scope says so too (gen.jl's `File scope:` line; the body, copied
        # verbatim, legitimately says "Never touch `test/**`")
        md = readroot(".claude/agents/implementer.md")
        @test occursin(r"(?m)^Mode: `write`\. File scope: [^\n]*`src/\*\*`", md)
        @test !occursin(r"File scope:[^\n]*`test/\*\*`", md)
    end

    IN_FACTORY && @testset "test-writer tools frontmatter rendered without Agent/SendMessage" begin
        p = joinpath(ROOT, ".claude/agents/test-writer.md")
        @test isfile(p)
        fm = isfile(p) ? agent_frontmatter(p) : Dict{String, String}()
        @test get(fm, "name", "") == "test-writer"
        tools = fm_list(fm, "tools")
        @test tools == ["Read", "Grep", "Glob", "Bash", "Edit", "Write"]
        @test isempty(intersect(tools, ["Agent", "Task", "SendMessage"]))
        @test issubset(["Agent", "Task", "SendMessage", "WebFetch", "WebSearch", "NotebookEdit"], fm_list(fm, "disallowedTools"))
        @test occursin("File scope: `test/**`.", isfile(p) ? read(p, String) : "")
    end

    IN_FACTORY && @testset "implementer frontmatter: tools without Agent/Task/SendMessage, and those disallowed" begin
        fm = agent_frontmatter(joinpath(ROOT, ".claude/agents/implementer.md"))
        tools = fm_list(fm, "tools")
        @test !isempty(tools)                                  # an allowlist now, not "inherit all"
        @test isempty(intersect(tools, ["Agent", "Task", "SendMessage"]))
        @test issubset(["Agent", "Task", "SendMessage"], fm_list(fm, "disallowedTools"))
    end

    IN_FACTORY && @testset "registry header says 13 roles and cites ADR-0015; AGENTS.md roster lists test-writer" begin
        txt = readroot(".agents/agent-registry.toml")
        header = join(filter(l -> startswith(l, "#"), split(split(txt, "\nversion = ")[1], '\n')), '\n')
        @test occursin(r"\b13\b|13th|thirteen"i, header)
        @test occursin("ADR-0015", header)
        @test !occursin("never add a 13th", header)
        agents = readroot("AGENTS.md")
        roster = split(agents, "## Agent roster")[end]
        @test occursin("| `test-writer` | write | inherit |", roster)
    end

    @testset "test_writer body: boundary (§2.2 rule 0), author, red, disputes" begin
        p = joinpath(ROOT, ".agents/bodies/test_writer.md")
        @test isfile(p)
        b = isfile(p) ? read(p, String) : ""
        @test occursin(r"context is the boundary"i, b)
        @test occursin("tdd-brief", b)
        @test occursin("test-writer <test-writer@factory.invalid>", b)
        @test occursin("TDD: red", b) && occursin("tdd.jl red", b)
        @test occursin("TDD: test-fix", b)
        @test occursin("TDD: backfill", b)
        @test occursin("@test_broken", b)
        @test occursin("test-refactor", b) && occursin("tdd.jl green", b)
        for w in ("WRONG-REASON", "PASSED", "COLLATERAL", "NOT-RUN")
            @test occursin(w, b)
        end
        @test occursin("`src/`", b) && occursin("`ext/`", b) && occursin("`changelog.d/`", b)
        @test occursin("test/laws/**", b)                       # what it does not edit (§2.1)
    end

    @testset "implementer and tester bodies (§2.3)" begin
        b = readroot(".agents/bodies/implementer.md")
        @test occursin("implementer <implementer@factory.invalid>", b)
        @test occursin(r"[Nn]ever touch[^\n]*`test/\*\*`", b)
        @test occursin("tdd-brief", b)
        @test occursin("test-fix request", b)
        @test occursin("STUB", b) && occursin("GREEN", b) && occursin("REFACTOR", b)
        for slug in ("law_tester", "property_tester", "differential_tester")
            t = readroot(".agents/bodies/$slug.md")
            @test occursin("In a test-first lane, commit new items with `TDD: red` before the code.", t) ||
                (println("$slug body lacks the TDD: red line"); false)
        end
    end

    @testset "reviewer body carries the §4.5 checklist" begin
        b = readroot(".agents/bodies/reviewer.md")
        @test occursin(r"Boundary first"i, b)
        @test occursin("agent_id", b)
        @test occursin("tdd_boundary", b)
        @test occursin("git show --cc", b)
        @test occursin("HELPER", b)
        @test occursin("mutexp", b)
        @test occursin(r"GREEN is minimal"i, b)
        @test occursin(r"MethodError"i, b)
    end

    @testset "lane-lifecycle skill: brief templates (§0.4) and dispatch rules" begin
        s = readroot(".claude/skills/lane-lifecycle/SKILL.md")
        @test occursin("<!-- tdd-brief role=test-writer", s)
        @test occursin("<!-- tdd-brief role=implementer", s) || occursin(r"`role=implementer`", s)
        @test occursin("checkout=", s)
        for h in (
                "## Task", "## Spec", "## Public API", "## Stub diffs", "## Test-fix requests",
                "## Red tests", "## Red evidence", "## Boundary",
            )
            @test occursin(h, s) || (println("skill lacks $h"); false)
        end
        @test occursin("tdd.jl brief", s)
        @test occursin(r"fresh\W+(a\W+)?`?subagent_type"i, s)
        @test occursin(r"never a fork"i, s)
        @test occursin(r"never rebase"i, s)
        @test occursin("TDD-Mode", s)
        @test occursin("lead <lead@factory.invalid>", s)
        @test occursin("agent_type", s)                         # the role is keyed on agent_type (Task 0)
        @test occursin(r"restart"i, s)                          # a new agent type needs a session restart
    end

    @testset "/change-review runs tdd.jl audit --ledger and dod.jl, reads saved prompts" begin
        c = readroot(".claude/commands/change-review.md")
        @test occursin(r"tdd\.jl audit[^\n]*--ledger"i, c)
        @test occursin("dod.jl", c)
        @test occursin(".lanes/briefs/", c)
    end

    IN_FACTORY && @testset "CLAUDE.md has the tdd.jl lines" begin
        c = readroot("CLAUDE.md")
        @test occursin("scripts/tdd.jl", c)
        @test occursin("tdd.jl audit", c)
        @test occursin("tdd.jl red", c)
    end

    if IN_FACTORY
        @testset "factory VERSION 0.3.1; the 0.3.1 and 0.3.0 CHANGELOG migration lists (§9.2, §6)" begin
            @test strip(read(joinpath(FACTORY, "VERSION"), String)) == "0.3.1"
            cl = read(joinpath(FACTORY, "CHANGELOG.md"), String)
            sec1 = changelog_section(cl, "0.3.1")
            @test occursin("**Migration.**", sec1) && occursin("julia scripts/gen.jl", sec1)
            sec = changelog_section(cl, "0.3.0")   # 0.3.0's section keeps its migration items
            @test !isempty(sec)
            for w in ("test_writer", "implementer", "risk.toml", "test/runtests.jl", "ADR-0015")
                @test occursin(w, sec) || (println("CHANGELOG 0.3.0 lacks $w"); false)
            end
            @test occursin(r"selection"i, sec)                  # runtests.jl's selection block
            @test occursin(r"handoff"i, sec)                    # the dogfood numbers (§6, plan Task 9 step 5)
            r = read(joinpath(FACTORY, "README.md"), String)
            @test occursin("test-writer", r) || occursin("test_writer", r)
            @test occursin("tdd_boundary", r)
        end
    end
end
