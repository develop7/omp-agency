---
name: ci
description: Run CI and verify it covers HEAD.
---

# CI

## Requires

- Changes in current branch
- Draft PR created (if the forge supports PRs)

## Ensures

- Local CI command outcome and remote PR-check outcome recorded as separate structured facts on the step

## Strategies

Read `.agency/do.md` and look for a `## CI command` section, plus any verification method documented
there. If no command is documented, record `local=not-run` and skip this step with a note. Run CI with
`async: true` on the bash tool if the command takes more than a few seconds — never pipe to
`tail`/`head`, never append `2>&1`.

**Active state**: before waiting for background CI, call `agency_driver` with
`{ op: "set", args: ["active", "waiting"] }`; when it returns, call
`{ op: "set", args: ["active", "working"] }` before proceeding.

CI commands are local and **forge-independent — run them regardless of forge**. Only the *verification
method* may be forge-specific: if `.agency/do.md` describes verification via PR checks and
`supportsPrChecks` is false (read from state), fall back to exit code + command output.

## Structured facts (mandatory on `end`)

Local command success and remote PR-check status are **separate facts**. On `end`, the verification
string must be (whitespace-separated, any order):

```
local=<passed|failed|not-run> remote=<passed|failed|pending|none|unavailable> head=<sha>
```

- `local` — the `.agency/do.md` CI command's exit outcome: `passed`, `failed`, or `not-run`.
- `remote` — the `forge` tool's `{ op: "pr-checks", args: [] }` outcome:
  - `passed` — checks reported and all green;
  - `failed` — checks reported and at least one failed;
  - `pending` — checks reported but still running;
  - `none` — the PR reports no checks;
  - `unavailable` — PR checks cannot be consulted (`!supportsPrChecks` or no PR).
- `head` — the commit SHA the `remote` facts were observed against (`vcs_read` with
  `{ args: ["head-commit-sha"] }`), not merely the local CI commit.

**A successful local command never implies a remote check.** `local=passed remote=none` is an honest
record of a local-only run, not a CI pass on the provider.

**require-remote policy** (read `require_remote` from the ci step's `pattern_config`): when
`require_remote = true`, the step may not be recorded `passed` unless `remote=passed` **and** `head`
matches the commit SHA CI ran against. If the local command passed but remote coverage is absent or
stale (`remote` = `none`/`pending`/`unavailable`/`failed` on a different SHA), record `status: failed`
with the structured facts and let the check-loop retry (or halt if retries are exhausted) — the draft
PR stays open as the record of the attempt. When `require_remote = false` (the default), record the
step `passed` only when the local command passed and HEAD coverage holds, with the remote fact carried
verbatim.

**Verify coverage of `HEAD`.** Before recording the step as passed, compare the commit SHA CI ran
against with the `vcs_read` tool using `{ args: ["head-commit-sha"] }`. If they differ, re-run CI
against current HEAD — CI passing on a stale commit does not satisfy verification.

**Flaky vs real**: a failure is flaky only if it **passes on a subsequent retry**. Consistent failure =
real bug.

- **If flaky** (max 3 retries): retry just the failing step.
- **If real bug** (max 5 fixes): fix → **fmt** → **commit** → retry CI. Under `--no-vcs`, drop **commit**
  from the loop. The draft PR already exists — pushes update it automatically.
- **If retries exhausted**: record `status: failed` with the structured facts and halt. The draft PR
  stays open as the record of the failed attempt.