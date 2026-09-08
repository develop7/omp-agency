---
name: ci
description: Run CI and verify it covers HEAD.
---

# CI

## Requires

- Changes in current branch
- Draft PR created (if the forge supports PRs)

## Ensures

- CI passes on current HEAD

## Strategies

Read `.agency/do.md` and look for a `## CI command` section, plus any verification method documented
there. If no command is documented, skip this step with a note. Run CI with `async: true` on the bash
tool if the command takes more than a few seconds — never pipe to `tail`/`head`, never append `2>&1`.

**Active state**: before waiting for background CI, call `agency_driver` with
`{ op: "set", args: ["active", "waiting"] }`; when it returns, call
`{ op: "set", args: ["active", "working"] }` before proceeding.

CI commands are local and **forge-independent — run them regardless of forge**. Only the *verification
method* may be forge-specific: if `.agency/do.md` describes verification via PR checks and
`supportsPrChecks` is false (read from state), fall back to exit code + command output.

**Verify coverage of `HEAD`.** Before recording the step as passed, compare the commit SHA CI ran
against with the `vcs_read` tool using `{ args: ["head-commit-sha"] }`. If they differ, re-run CI
against current HEAD — CI passing on a stale commit does not satisfy verification.

**Flaky vs real**: a failure is flaky only if it **passes on a subsequent retry**. Consistent failure =
real bug.

- **If flaky** (max 3 retries): retry just the failing step.
- **If real bug** (max 5 fixes): fix → **fmt** → **commit** → retry CI. Under `--no-vcs`, drop **commit**
  from the loop. The draft PR already exists — pushes update it automatically.
- **If retries exhausted**: record `status: failed` and halt. The draft PR stays open as the record of
  the failed attempt.