---
name: police
description: Three-pass quality gate.
---

# Police

## Requires

- `--minimal` flag
- `--no-vcs` flag
- Diff from the `vcs_read` tool with `{ op: "diff-range" }`

## Ensures

- All 3 passes clean
- Violation fixes committed individually (or working-tree fixes under --no-vcs)

## Strategies

Use the `vcs_read` tool with `{ op: "diff-names" }` to check if the PR contains code changes. If all
changed files are documentation-only (`.md`, `.txt`, README, docs/) — this is a node-local skip: record it
with `agency_driver { op: "end", status: "skipped", reason: "docs-only changes" }`
(see [Two skip spellings](../SKILL.md#two-skip-spellings)).

**Resolve leftover jobs first.** At step start, before spawning any work, read the `jobs` array in `.do-results.json` and resolve EVERY unfinished entry, whichever step owns it (a crash leaves these behind, and a carried or stale job of ANY step blocks the final summary): `agency_driver { op: "job-end", id, outcome: "escalated", verification: "stale — worker process died in a previous run" }` — stale, its process died — or `agency_driver { op: "job-end", id, outcome: "cancelled", verification: "stale — worker process died; dropping this work" }` to drop that work. This is the one remediation point for stale jobs of every step; police-owned leftovers then spawn replacements under fresh ids. Never spawn while any job is unfinished.

Otherwise, read the `code-police` skill via `read skill://code-police` and invoke it. When it asks about scope: **changes in the current branch/PR only**. Its worker budgets come from this step's `pattern_config` as surfaced by `workflow cli`: `worker_budget_minutes` per worker, `worker_retries` fallback attempt, `police_budget_minutes` for the whole step.

The orchestrator resolves optional project rules once using the skill's **Project rules** protocol before spawning passes. Apply `skill://review-handoff`: publish the complete rules bundle at a native URI and require every reviewer, elegance call, and retry to read it in full; reviewers must not rediscover project-rule files. Optional absence selects built-in rules only; genuine discovery or read failures stop the review.

**Commit each violation fix individually** — same rule as hickey+lowy: one commit per violation, not a
lump. For each violation reported across the three passes, in turn:

1. Apply the fix for that one violation — scope the edit tightly.
2. Run the project's format command on changed files, if configured.
3. Call the `vcs_write` tool with `{ op: "fix-commit", message: "<prefix>: <short description>", files: ["<file1>", "<file2>", ...] }` with the conventional prefix:
   - Rules pass: `fix(police): <rule-id> — <short description>`
   - Fact-check pass: `fix(police): fact-check — <short description>`
   - Elegance pass: `refactor(police): elegance — <short description>`

**Under `--no-vcs`**: skip commit/push. Apply fixes to the working tree.

**Verify**: All 3 passes clean ("All clear").
**If violations found** (max 3 attempts — `max_attempts = 3` for this step in `workflow.ncl`): fix them and re-invoke the `code-police` skill.

**At step end every `step == "police"` job must be resolved** (`finishedAt` + `outcome` present). The driver enforces this: `agency_driver { op: "end" }` refuses with an `unfinished job` error listing the offending ids and leaves state unchanged.