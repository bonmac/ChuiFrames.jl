---
name: lane-lifecycle
description: Rules for dispatching, monitoring, closing and reporting agent lanes (subagents, teammates, worktree lanes). Use whenever you dispatch an agent or a lane goes quiet.
---
<!-- Factory-managed (see .factory-version). -->
# Lane lifecycle

**Dispatch**
- One lane = one repo, one file scope, one deliverable, one definition of done. No two open
  lanes share a file.
- Give the agent its brief, its scope, and the output format from its registry entry.
- Worktree lanes: `scripts/lane new <name> --owns '<globs>' [--base main]` creates
  `.worktrees/<name>` and records the globs the lane may touch (`changelog.d/<name>.md` is
  added). The brief's file scope and `--owns` are the same list. It copies the machine-local,
  gitignored `.agents/factory.local.toml` into the lane and runs `scripts/gen.jl` there (the
  user's own file; without it a repo that requires read-only roots blocks every Bash call in the lane).
- Sub-lanes: `scripts/lane new` run inside a lane creates a SIBLING, `<repo>/.worktrees/<sub>`.
  A session rooted in a lane worktree may write the repo's other lane worktrees (`.worktrees/*`,
  `.claude/worktrees/*`) and `<repo>/.lanes/reports/`, not the main checkout; T3 paths stay
  blocked there. Do not work in scratch copies. The parent lane still owns the merge.
- The brief says: change files with Edit/Write only, never `sed -i`, redirects or heredocs.
- Each lane records its change in `changelog.d/<name>.md`, never in `CHANGELOG.md`.
- The cap is `[lanes] max_open` (default 4). `dispatch_limit.sh` refuses the next spawn. A lane
  is an Agent dispatch, open until its call returns (foreground), its background agent stops, or
  you `TaskStop <name>` it (a teammate). Give every teammate a `name`. A lane whose agent is gone
  (TaskStop says no task found; a dispatch that never ran) is released with
  `scripts/lane release <name>`. A spawned teammate or background agent is never dropped by time.

**Test-first lanes (factory 0.3.0, ADR-0015)**
- Each task gets two agents, each a fresh `subagent_type` dispatch (Agent call, the brief as
  `prompt`): `test-writer` (RED, test-fix, test-refactor, backfill) then `implementer` (STUB,
  GREEN, REFACTOR). Never a fork, never one agent switching roles, never one resumed with the other's transcript, no
  `team_name`: subagents only, not teammates. Continue an agent only within its own task.
- **TDD roles are dispatched unnamed (0.3.1).** The TDD roles (`test-writer`, the other test-side
  roles `law-tester`, `property-tester` and `differential-tester`, and `implementer`) are
  dispatched UNNAMED, as plain subagents: no `name`. Their final reply is the report. A named
  dispatch is a teammate, and TeammateIdle then demands a SendMessage or a `.lanes/reports/` file;
  the TDD roles have no SendMessage, and `tdd_boundary` bars them from writing `.lanes/reports/`,
  so a named TDD role cannot report. An unnamed subagent fires no TeammateIdle.
- This applies only to the TDD roles. The other roles (the ones `lane audit --reported` checks:
  reviewer, critic, sub-leads and other worktree-lane agents) are dispatched named, as above.
- The hooks key the role on `agent_type` only, never `agent_id`. The lead is the caller with no
  `agent_type`. SubagentStart/SubagentStop never fired here; nothing relies on them.
- Agent types load mid-session: a registry entry added and generated (`scripts/gen.jl`) is
  dispatchable without a restart.
- Dispatch only on a clean lane. `julia scripts/tdd.jl brief --role <role> --root
  <lane checkout>` prints the header, the public API and the stub diffs, and saves the brief under
  `<main>/.lanes/briefs/<lane>/`; add the rest by hand. `tdd_boundary` checks the header (role,
  `checkout=` a lane worktree, `head=` its HEAD) and saves the prompt under `dispatched/`.
- **The brief is the only channel.** Never relay src beyond the stub diffs, a GREEN/REFACTOR diff,
  or the other agent's report or reasoning. A test-fix request passes on verbatim.
- test-writer brief:

  ```
  <!-- tdd-brief role=test-writer lane=<lane> checkout=<abs path of the lane worktree> head=<sha> -->
  ## Task    (the plan task text)
  ## Spec    (the path)
  ## Public API   (tdd.jl api output; docs/src pages)
  ## Stub diffs   (git show of each stub commit, only if H5 passed)
  ## Test-fix requests   (verbatim, if any)
  ## Boundary  (spec §0.4 and §0.6, quoted)
  ```

- implementer brief: the same header with `role=implementer`, then `## Task`, `## Spec`,
  `## Red tests` (paths and shas), `## Red evidence` (paths) and `## Boundary`. Never the
  test-writer's report or messages.
- **Test-side roles (critic C1).** `law-tester`, `property-tester` and `differential-tester` are
  test-side roles like the test-writer: each may author `red`, `test-fix`, `test-refactor` and
  `backfill` under its own identity (`<role> <<role>@factory.invalid>`), gets the test-writer's
  boundary, reads only its own `.lanes/briefs/<lane>/<role>-*`, and is dispatched by the lead with
  `julia scripts/tdd.jl brief --role <role>` (header `role=<role>`, the test-writer's sections).
- **The one commit form (critic C2).** Every role commits with
  `git -C <lane> commit -q --author "<role> <<role>@factory.invalid>" -m "<subject>" --trailer "TDD: red" --trailer "Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"`
  (the phase varies), in its own Bash call, never chained with `tdd.jl red` or anything else (a
  cancelled chained call leaves a late commit). git reads trailers only from the last paragraph, and
  git's `%(trailers)` is the one parser (post hook, H1/H9, `tdd.jl`): a phase in a paragraph of its
  own (a separate `-m`, a heredoc) is no phase. The post hook flags a role commit with no phase
  (`no-phase`, exit 2) while it is still HEAD: amend it then with
  `git -C <lane> commit -q --amend --no-edit` plus `--trailer` and the phase.
- **A cancelled commit call (critic C4).** A commit whose Bash call was cancelled (Esc) fires no post
  event; the sweep records it `tdd-commit-late`, which E5 rejects. The lead's recovery: while that
  commit is HEAD, have its role amend it through the hooks (`--amend --no-edit`); otherwise reset the
  lane to before the commit and re-dispatch the role, or attest the commit with a lead waiver:
  `git -C <lane> commit -q --allow-empty --author "lead <lead@factory.invalid>" -m "chore: waive E5" --trailer "TDD-Waiver: E5 <sha> — <reason>"`
  (sha full or at least 7 hex; a reason; the waiver covers only a late-only record, never a sha with
  no record or a violation; the guard denies the trailer to role callers).
- **Sub-leads (critic C3).** A sub-lead teammate has an `agent_type`, so it can neither dispatch the
  TDD roles nor write a mode commit: a sub-lead asks the lead for the TDD dispatch and the mode commit
  (a `TDD-Mode: skip — <reason>` for its non-TDD code lanes too).
- **Mode.** The lead records it as a `TDD-Mode: required|refactor|skip — <reason>` trailer on a
  commit authored `lead <lead@factory.invalid>` (e.g. `git commit --allow-empty --author "lead
  <lead@factory.invalid>"`). The commit guard denies the lead identity to any caller with an
  `agent_type`, and a `TDD-Mode:` trailer line to the role callers (the test-side roles, implementer). Default `required`; no `src/`/`ext/` change needs none.
  The reason separator is ` — `, ` - ` or ` -- `. On an integration branch the mode is per merged
  sub-lane (critic C6): each `--no-ff` merge's `M^1..M^2` follows its own mode commit, and the commits
  made directly on the branch follow the branch's own.
- **The TDD ledger.** The post hook writes every `tdd-commit`, `tdd-commit-violation` and `tdd-commit-late`
  record to the ledger of the MAIN checkout of the repo that owns the commit's checkout
  (`<main>/.lanes/ledger.jsonl`, `owning_ledger` in `_lib.sh` and `_tdd_evidence.jl`), whether the role ran
  as a subagent (session root: the coordinator) or a teammate (session root: the package); `tdd.jl audit`
  reads that ledger when `--ledger` is not given. Lane dispatch records stay in the session ledger.
- Before the merge: `/change-review` runs `tdd.jl audit --base main` (its default ledger is the
  owning repo's main ledger) and `dod.jl`.
  **Merge, never rebase:** evidence is keyed by sha; after a rebase run `tdd.jl green` at the tip, and audit
  lists the missing reds for the lead to decide.

**Monitor**
- Wait for completion notifications; do not poll output files.
- Bound every long run with `julia scripts/ci.jl <job> --timeout SECONDS` (or `CI_TIMEOUT`), and
  put that in the brief. Never use `perl -e 'alarm N; exec @ARGV'` or `timeout`: they kill only
  ci.jl, and Pkg.test's child julia runs on (a hung property test ran ~6 h at 97% CPU). On expiry
  ci.jl kills the whole process group and exits 124, which is TIMED OUT, not a pass. Ctrl-C does the
  same and exits 130. Killing ci.jl with any other signal (`kill`, `timeout`) orphans the group.
- Reviewers may send a preview first. Wait for the final report.

**Idle**
- An agent idle without a report is unproven: nudge it once (SendMessage) asking for the report.
- Still nothing: it is a FAILED lane. Re-dispatch with a narrower brief, or review its diff
  yourself, and say which you did. Never count its work as reviewed.

**Close**
- Before a lane lands, `scripts/lane audit <name> --reported <file>` (the changed files the lane
  reported) must pass; a path outside `--owns` is a finding, not a formality. It diffs against
  the local base when that contains `origin/<base>` (local merges not yet pushed are not the
  lane's); `--base B` audits against another base.
- A lane's report: SendMessage, or `.lanes/reports/<name>.md` in its worktree or the repo root
  (`teammate_idle` reads both).
- Close the agent (TaskStop) in the same step as reading its report. A listing is not proof of
  closure. Before recording a lane as `no_report`, check once more for a late message: a report
  can arrive after the stop.
- Remove a merged worktree lane with `scripts/lane remove <name>`; show `git worktree list`.

**Report**
- `subagent_mode: actual | simulated | mixed`. Simulated means the pass was not spawned.
- The roster: which agents ran, which lanes were skipped and why, which failed or went idle.
- Verify a lane's claims (re-run its test command) before building on them. Test counts come
  from an evidence file (`julia scripts/evidence.jl tests -- <cmd>`); cite it.
