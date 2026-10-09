---
name: done
description: Timing summary, optimization suggestions, and wrap-up.
---

# Done

## Requires

- All prior steps completed

## Ensures

- Timing table emitted
- Final PR comment posted (if the forge supports PR comments)
- Workflow status set to completed or failed

## Strategies

Present a summary of all steps with their verification status. Retry any non-success step (max 3
attempts from done). If still failing after retries, set `status: "failed"`.

`"completed"` requires **all steps `passed`**, with six exceptions that count toward completion:

1. A step `skipped` with `reason` `"forge does not support PR comments"`.
2. A step `skipped` with `reason` `"--no-vcs"`.
3. A step `skipped` with `reason` `"no PR evidence section in .agency/do.md"`.
4. A step `skipped` with `reason` `"--minimal"`.
5. A step `skipped` with a `reason` beginning `"no * command configured"`.
6. A step `skipped` with `reason` `"docs-only changes"`.

A `failed` step always blocks `"completed"` — no redefining "passed". Update via
`{ op: "set", args: ["status", "completed"|"failed"] }`.

#### Timing summary

Call the `agency_driver` tool with `{ op: "summary", args: [] }`. It emits the markdown timing table
(steps ≥30% of total time bold), the total wall-clock line, the `**Slowest step**:` line, and a
`<<<FACTS ... FACTS` block with machine-readable data (`totalSeconds`, `slowestStep`, `dominantSteps`,
`skippedSteps`, `failedSteps`). Do not compute durations yourself.

#### Optimization suggestions

From the FACTS block, generate **2–4 concrete suggestions** for reducing time-to-completion in future
runs — specific to this run's data (dominant step, flaky retries, useful `--from` entry point), not
generic advice.

#### PR comment & wrap-up

- **Under `--no-vcs`**: print the timing table and suggestions to the terminal only. List files
  modified in the working tree (the `vcs_read` tool with `{ args: ["dirty"] }`) and remind the user the
  changes are uncommitted.
- **If `!supportsPrComment`** (read from state): report the branch name (and remote URL via
  `vcs_read` with `{ args: ["remote-url"] }`) instead of a PR URL. Print to the terminal only; post
  nothing.
- **If `supportsPrComment`**: report the PR URL. Post the final step status table as a PR comment by
  calling the `forge` tool with `{ op: "pr-comment", args: [], body: "<comment>" }` — use the emitted
  table and slowest-step line verbatim, strip the trailing FACTS block. Format:

```text
call the `forge` tool with `{ op: "pr-comment", args: [], body: """`
## [`/do`](https://github.com/srid/agency) results

| Step | Status | Duration | Verification |
|------|--------|----------|-------------|
| sync | ✓ | 3s | ... |
...
| **Total** | | **4m 32s** | |

### Optimization suggestions

- <2–4 concrete suggestions based on timing data>

Workflow completed at <timestamp>.
""" }`
```