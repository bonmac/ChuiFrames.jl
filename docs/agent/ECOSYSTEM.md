<!-- ecosystem rules: coordinator commit 16b9e6a, prompts/common.md, copied 2026-10-19 -->
# Chui ecosystem: shared rules for the lead and every agent

The lead session and every subagent or teammate it dispatches read this file before starting work. The lead copies it into each repo as `docs/agent/ECOSYSTEM.md` and keeps the copies in sync; each repo's copy carries a version stamp at the top.

---

## 1. Ground rules

1. **Verify; don't guess.**
   - Every API claim about Julia, a package or an inspiration library must come from running code, official docs (Context7 first, then the web), or source code.
   - If you can't verify something, mark it `UNVERIFIED`.
2. **Evidence before assertions.**
   - Never report a test, benchmark or review as done unless it ran. Paste the command and its output.
   - If a lane failed or was skipped, say so.
3. **Composition and adapters first.**
   - Build small orthogonal pieces that compose through multiple dispatch and the existing ecosystem interfaces: Tables.jl, the Arrow columnar format, DBInterface.jl, the iteration protocol, Base `map`/`filter`/`reduce`/broadcasting, and `AbstractArray`.
   - Integrate through adapters (package extensions), never through copies.
4. **Few dependencies, chosen deliberately.**
   - Every dependency needs an ADR (an Architecture Decision Record, a short file in `docs/adr/`) explaining why.
   - Optional integrations go in package extensions (`[weakdeps]` + `ext/`).
5. **Think, critique, refine.** Every major design is written down, critiqued by a reviewer agent, and revised before it is implemented. Each ADR lists the alternatives rejected and why.
6. **Outward-facing actions need the user's confirmation:**
   - creating repositories, or choosing their visibility;
   - pushing to a remote;
   - registering packages or tagging releases;
   - deleting anything;
   - posting issues to GitHub.

   Local commits on feature branches are fine.
7. **Julia best practices:**
   - `[compat]` bounds on every dependency, and semantic versioning;
   - PrecompileTools workloads, with measured time-to-first-x (TTFX, the delay before the first result after loading);
   - JET.jl type-stability checks, Aqua.jl, and ExplicitImports.jl;
   - Documenter.jl docs with doctests;
   - Runic.jl as the formatter (zero-config; ADR-0007, decided at the L0 checkpoint).

## 2. Independence: each repo stands alone

- **Runs alone:** each repo must clone, install, test, benchmark and build its docs **by itself**, using only *released* versions of the other Chui packages. A fresh clone plus `]instantiate; ]test` must pass.
- **Upstream versions:** depend on upstream Chui packages through `[compat]` ranges, never through `Pkg.develop` paths that are committed.
  - For local cross-repo work, use an untracked `dev/` environment.
  - Before the packages are in Julia's General registry, use the ecosystem's personal registry (set up by meta with LocalRegistry.jl; verify how it works).
- **Upstream contract tests:** each downstream repo has contract tests (`test/contracts/`) covering exactly the upstream API it relies on, as listed in `<root>/contracts/`. CI runs them twice:
  - against the **latest release** (this run blocks a merge);
  - against **upstream main** (this run only warns).
- **Requests go through the lead:** a lane working on a downstream package never edits an upstream repo. It writes a request (§5); the lead schedules an upstream lane, which implements and releases it, and only then does the downstream lane adopt the new release.
- **Breaking changes** need a contract ADR in the root repo, a major version bump (or a minor bump while below 1.0) in the upstream package, and a changelog entry with migration notes.

## 3. Development process (the "software factory")

The lead builds this once as a versioned template (`<root>/factory/`). Each repo vendors a copy and records the template version it uses. A `sync-factory` script pulls updates deliberately and shows the diff, so repos can evolve separately.

The template is adapted from three private local projects, called here reference projects A, B and C; meta's ADR-0001 records what was kept and what was changed. Their paths are machine-local (the gitignored `.agents/factory.local.toml`).
- **Base: reference project A, the best-defined process.**
  - The flow is Classify → Design → Plan → Execute → Verify → Review → Finish, run through `superpowers:*` skills.
  - Specs go in `docs/superpowers/specs/`, plans in `docs/superpowers/plans/`, and run artifacts in `.superpowers/sdd/<date-slug>/`.
  - ADRs live in `docs/adr/`, starting from `0000-template.md`.
  - A lane script manages worktree lanes, and gate stamps record what passed.
  - A registry-generated agent roster, with commands such as `intake`, `lanes`, `change-review`, `release-check` and `test-changed`.
  - Hooks such as `bash_guard`, `write_guard`, `teammate_idle` and a pre-compact summary.
  - Test tiers, gate tiers, a coverage floor that only rises, and pre-commit guards.
- **From reference project B:**
  - one `.agents/agent-registry.toml` generated into the Claude and Codex agent files, with a `--check` that fails if they drift;
  - per-agent `scorecard` and `output_format`;
  - risk tiers T0–T3 tied to protected paths;
  - lane lifecycle rules: close each lane when done, an idle lane counts as failed, mark simulated work;
  - checks whose limits only tighten; handoff templates; a debt register.
- **From reference project C:**
  - `CLAUDE.md` as the source, with `AGENTS.md` generated from it;
  - adversarial agents (`critic`, `red-team`, `adjudicator`);
  - lane dispatch, close and idle skills, with a cap on open lanes and a lane ledger;
  - a merge gate that runs on the merged commit;
  - rules written as "prevented by X", with each check's blind spots documented (`CHECK_COVERAGE.md`);
  - status derived from evidence files.

**Problems in those projects to fix, not copy:**
- **Long instruction files:** prose files of several hundred lines that drift apart. Keep `CLAUDE.md` short and link out.
- **Too many agents:** dozens in one project. Aim for about 12 sharply defined roles per repo.
- **Duplicated or local-only CI:** runners on one machine, or the same gates copied into several places. Use a single GitHub Actions pipeline.
- **Red main tolerated:** main must stay green.
- **Decision logs nobody can navigate:** use short ADRs plus an index.
- **Hundreds of loose scripts:** keep scripts in Julia `scripts/`, with tests.
- **Junk at the repo root:** test output, coverage files, trace logs.
- **No automated definition of done:** a merge check must require spec → plan → tests → review diff → CHANGELOG entry.

**Agent roster per repo (adjust per package; record it in the registry):**
- `architect`: writes ADRs.
- `researcher`: verified API and parity research, Context7 then web.
- `implementer`.
- `law-tester`: algebraic laws.
- `property-tester`.
- `differential-tester`.
- `benchmarker`.
- `reviewer`: read-only.
- `critic`/`red-team`: attacks designs.
- `docs-writer`.
- `release-manager`.
- `contract-steward`: owns `test/contracts/` and cross-repo requests.

**How the work runs:**
- **Lanes:** one `git worktree` per lane, with separate file scopes per agent. Merges and rebases done by a subagent are reviewed before they land.
- **Workflows:** use multi-agent workflow scripts for fan-out; the user has asked for workflows, worktrees, parallel subagents and agent teams.
- **Agent lifecycle:**
  - close each agent when its work is done;
  - an idle agent that didn't report is a failed lane;
  - report the roster at the end of each phase: which agents ran, which were skipped, which failed;
  - reviewers sometimes send a short report first and the complete one later, so wait for the final report.
- **CI (GitHub Actions, julia-actions):**
  - a test matrix across Julia LTS, stable and nightly (nightly may fail without blocking);
  - Aqua, JET, docs and coverage;
  - contract tests against both upstream versions;
  - benchmark-regression checks (AirspeedVelocity.jl or PkgBenchmark);
  - CompatHelper and TagBot.
- **Commits:** Conventional Commits, on feature branches; the main branch is protected.

## 4. Testing and benchmarking

- **Unit tests:** TestItemRunner or `Test`, as chosen in the ecosystem ADR.
- **Law tests** for every typeclass instance, property-based with Supposition.jl or similar (verify the library before adopting it).
- **Differential tests:** compare against reference implementations. Run R through `Rscript` and Python through `uv` (Homebrew Python is broken on this machine).
- **Snapshot (golden-output) tests** for everything that prints.
- **Benchmarks:** reproducible, and reported with hardware, versions, cold vs warm runs, and median with spread. Publish losses as well as wins. Each repo's ADR sets a performance budget, and CI fails on regressions.

## 5. One lead session, many repos

One Claude Code session, the **lead**, runs the whole effort in the background (`claude --bg`, watched from `claude agents`). It works from `<root>` = `~/personal-projects/julia-data-analysis`. It plans, dispatches and reviews; the subagents and agent teams do the package work.

- **The root is the coordinator repo.** It holds:
  - the agent workflow: the lead's `CLAUDE.md`/`AGENTS.md`, `.claude/`, `prompts/`, and the `factory/` template;
  - the ecosystem coordination: ADRs, contracts, requests, releases, the compatibility matrix, integration tests, benchmarks and research;
  - `reference/prototype/`.

  Its `.gitignore` lists every package folder (`/Chui*.jl/`), so the packages nested inside it remain **separate git repos**.
- **Boundary:**
  - The lead and every lane write only inside `<root>`.
  - The three reference projects (§3; machine-local paths in the gitignored `.agents/factory.local.toml`) are read-only references.
  - Everything else is off limits.

- **Repos stay separate:** the root repo, `ChuiCore.jl`, `ChuiTypes.jl` and `ChuiFrames.jl` are each their own git repo, with their own history, remote, CI, version and releases.
  - **A commit never spans repos.** A change that touches two packages becomes two commits, in dependency order: upstream first, released, then downstream.
- **Lanes:** each lane is assigned **one repo** and **one file scope** in it, and works in its own `git worktree` *of that repo*, e.g. `<root>/ChuiFrames.jl/.worktrees/<lane>` (added to `.gitignore`).
  - Lanes in different repos run in parallel freely.
  - Lanes in the same repo need separate file scopes.
  - The lead, or a reviewer agent it dispatches, reviews every lane's diff and any merge or rebase before it lands on that repo's main.
- **Agents:**
  - Use **subagents** for bounded tasks: research, review, tests, benchmarks, single-package implementation.
  - Use **agent teams** (`CLAUDE_CODE_EXPERIMENTAL_AGENT_TEAMS=1`) when several agents must work side by side for a while, for example one per package during a coordinated release.
  - **Verify first:** before relying on teams, check that they actually work inside a background session (`teammateMode` is `tmux` on this machine). If they don't, use subagents, and say so in the phase report.
  - Use multi-agent **workflow scripts** for large fan-outs, such as parity research per R package or benchmarks per competitor.
  - Close each agent when its work is done, and keep the number of open lanes within the cap set by the factory.
- **Cross-repo requests:** a lane that needs something from another package writes `<root>/requests/<from>-to-<to>-<slug>.md` (the need, the proposed API, the urgency, the contract affected) and continues with an adapter. The lead triages requests at least once per phase.
- **Releases and upgrades:**
  - An upstream release is tagged in its repo and registered in the personal registry (later, in General). Both need the user's confirmation for anything public.
  - It is recorded in `<root>/releases.md` and `compat-matrix.md`.
  - Downstream lanes then upgrade deliberately, each on its own branch.
- **Git and GitHub:**
  - Each repo is committed independently, with Conventional Commits on feature branches merged to its own main.
  - Each repo gets its own GitHub repository and remote.
  - Creating repositories, setting their visibility, and pushing need the user's confirmation.
  - Once the user approves pushing for a repo, the lead may push that repo's main when it is reviewed and green, without asking again. Anything else still needs confirmation.
- **Checkpoints while running in the background:** at each ★ checkpoint, the lead:
  - stops and writes the decision it needs into `<root>/HANDOFF.md`;
  - notifies the user with PushNotification, if that tool is available;
  - **waits**. The session then shows as waiting in `claude agents`, and the user answers with `claude attach junta`.
- **Handoff:** the lead keeps `<root>/HANDOFF.md` (overall state, open lanes per repo, blockers, decisions waiting) and each repo's `HANDOFF.md` up to date, so `claude --resume <id>` or a fresh lead session can continue.
- **Escalation:** design disagreements between packages become an ADR in the root repo. If one stays unresolved, it goes to the user at the next checkpoint.
