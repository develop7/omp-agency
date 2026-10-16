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
changed files are documentation-only (`.md`, `.txt`, README, docs/) — skip this step with reason
`"docs-only changes"`.

**Resolve leftover jobs first.** At step start, before spawning any work, read the `jobs` array in `.do-results.json` and resolve every unfinished entry with `step == "police"` (a crash leaves these behind): `agency_driver { op: "job-end", id, outcome: "escalated" }` — stale, its process died — and spawn a replacement worker under a fresh id, or `outcome: "cancelled"` to drop that work. Never spawn while a stale police job is unfinished.

Otherwise, read the `code-police` skill via `read skill://code-police` and invoke it. When it asks about scope: **changes in the current branch/PR only**. Its worker budgets come from this step's `pattern_config` as surfaced by `workflow cli`: `worker_budget_minutes` per worker, `worker_retries` fallback attempt, `police_budget_minutes` for the whole step.

The orchestrator resolves optional project rules once using the skill's **Project rules** protocol before spawning passes. Reuse that complete rules bundle for every reviewer, elegance call, and retry; reviewers must not rediscover project-rule files. Optional absence selects built-in rules only; genuine discovery or read failures stop the review.

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