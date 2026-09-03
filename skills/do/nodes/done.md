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

Present a summary of all steps with their verification status. If any step has a non-success status, retry it (max 3 attempts from done). If still failing after retries, set `status: "failed"`.

`"completed"` requires **all steps `passed`**, with six exceptions that count toward completion:

1. A step `skipped` with `reason` `"forge does not support PR comments"`.
2. A step `skipped` with `reason` `"--no-vcs"`.
3. A step `skipped` with `reason` `"no PR evidence section in .agency/do.md"`.
4. A step `skipped` with `reason` `"--minimal"`.
5. A step `skipped` with `reason` beginning `"no * command configured"`.
6. A step `skipped` with `reason` `"docs-only changes"`.

A `failed` step always blocks `"completed"`.

#### Timing summary

Call the `agency_driver` tool with `{ op: "summary", args: [] }`. It emits:

1. A markdown timing table (step, status, duration, verification), with any step that took ≥30% of total time shown in **bold**.
2. A total wall-clock line.
3. A `**Slowest step**:` line.
4. A `<<<FACTS ... FACTS` block with machine-readable summary data.

Do not compute durations yourself — the `agency_driver` tool handles all timestamp arithmetic.

#### Optimization suggestions

Read the `FACTS` block the `agency_driver` summary operation emitted and generate **2–4 concrete suggestions** for reducing time-to-completion in future runs. Base these on the actual timing data — for example:

- If **ci** dominates: suggest `--from ci-only` for re-runs.
- If **research** was slow: suggest pre-reading relevant code before invoking `/do`.
- If **test** had retries: note the flaky test and suggest hardening it.
- If **police** required fix iterations: note which pass caught issues.
- If **implement** was the bottleneck: suggest breaking the task into smaller PRs.

Be specific to this run's data, not generic advice.

#### PR comment & wrap-up

**If `--no-vcs`**: Print the timing table and optimization suggestions to the terminal only. List files modified in the working tree (call the `vcs_read` tool with `{ args: ["dirty"] }`). Remind the user that changes are uncommitted.

**If `!supportsPrComment`** (read from state): Report the branch name (and remote URL via the `vcs_read` tool with `{ args: ["remote-url"] }`). Print timing table and suggestions to the terminal only.

**If `supportsPrComment`**: Report the PR URL. Then post the final step status table as a **PR comment** by calling the
`forge` tool with `{ op: "pr-comment", args: [], body: "<comment>" }`. Use the markdown table and slowest-step line emitted by the
`agency_driver` summary operation verbatim (strip the trailing `<<<FACTS ... FACTS` block — that's internal). Format:

This uses the body-bearing `forge` `pr-comment` variant; read operations such
as `pr-view` remain args-only.

```text
call the `forge` tool with `{ op: "pr-comment", args: [], body: """`
## [`/do`](https://github.com/srid/agency) results

| Step | Status | Duration | Verification |
|------|--------|----------|-------------|
| sync | ✓ | 3s | ... |
| research | ✓ | 45s | ... |
...
| **Total** | | **4m 32s** | |

### Optimization suggestions

- <2–4 concrete suggestions based on timing data>

Workflow completed at <timestamp>.
""" }`
```
