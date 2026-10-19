---
description: Turn a request or issue into a classified, scoped piece of work (tier, spec or plan stub, lanes).
argument-hint: <issue URL, request text, or file>
---
<!-- Factory-managed (see .factory-version). -->
Intake for: $ARGUMENTS

1. Restate the request in two sentences: the problem, and what "done" looks like.
2. Classify the risk tier with `risk.toml`: list the paths it will touch and take the highest
   tier any of them carries; never classify below that.
3. By tier:
   - T0: no spec. Go straight to the change; the PR gets the `T0` label.
   - T1: write a short plan at `docs/superpowers/plans/YYYY-MM-DD-<slug>.md`.
   - T2/T3: dispatch the `architect` for a spec at `docs/superpowers/specs/YYYY-MM-DD-<slug>-design.md`
     (T3 also needs an ADR from `docs/adr/0000-template.md`), then the `critic` to attack it.
4. If it needs another package's API, stop and run `/contract-check` first.
5. Split the work into lanes: one repo, one file scope, one deliverable each, no shared files.
   Name the agent for each lane from `.agents/agent-registry.toml`.
6. Output: tier with the path evidence, the spec/plan path, the lane table
   (lane | agent | file scope | deliverable | definition of done), and open questions.
