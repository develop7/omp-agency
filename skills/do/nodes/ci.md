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
- Local command status and remote PR-check status are recorded as separate facts

## Strategies

Read `.agency/do.md` and look for a `## CI command` section, plus any verification method documented
there. If no command is documented, skip this step with a note. Run CI with `async: true` on the bash
tool if the command takes more than a few seconds — never pipe to `tail`/`head`, never append `2>&1`.

**Active state**: before waiting for background CI, call `agency_driver` with
`{ op: "set", field: "active", value: "waiting" }`; when it returns, call
`{ op: "set", field: "active", value: "working" }` before proceeding.

CI commands are local and **forge-independent — run them regardless of forge**. Only the *verification
method* may be forge-specific: if `.agency/do.md` describes verification via PR checks and
`supportsPrChecks` is false (read from state), fall back to exit code + command output.

**Keep local and remote evidence separate.** A successful local command records only
`local: passed`; it never implies `remote: passed`. The step may be passed only when the local
command passed **and** either remote coverage is unavailable/optional or the remote check actually
passed. Persist both facts, plus the head identity that was checked, as separate structured fields:

```
agency_driver { op: "set", field: "ciLocal", value: "passed" | "failed" | "not-run" }
agency_driver { op: "set", field: "ciRemote", value: "passed" | "failed" | "pending" | "none" | "unavailable" }
agency_driver { op: "set", field: "ciHead", value: "<checked head SHA or empty>" }
```

When `.agency/do.md` documents a `require-remote` policy, persist it as
`{ op: "set", field: "requireRemote", value: true | false }` (default `false`). When
`requireRemote` is true and remote coverage is absent (`none`), failed (`failed`), or pending
(`pending`), the CI node must **not** mark the step passed: fail it (recording the remote state) or
wait/retry until the remote result is visible. Pending is not a pass.

**Verify coverage of `HEAD`.** Before recording the step as passed, compare the commit SHA CI ran
against with the `vcs_read` tool using `{ op: "head-commit-sha" }`. That op is the CI-target
identity: under jj it resolves the feature bookmark's commit (bookmark on `@`, else on `@-`; with
no feature bookmark, the parent commit). **commit** runs before **ci**, so by this step the working
copy is empty and the bookmark names the pushed change — but a bookmark sitting on `@` names the
mutable working copy, so verify the bookmark has advanced past the committed work. If the SHAs
differ, re-run CI against current HEAD — CI passing on a stale commit does not satisfy verification.
Record the resolved SHA as `ciHead`.

Under `--no-vcs` there is no pushed feature revision for CI to cover — `commit` never ran, so
`head-commit-sha` has no pushed identity to compare. Verify coverage with the local command's exit
code and output instead of the SHA comparison. In this mode `ciRemote` is `unavailable`; local
status is authoritative.

Remote checks, when available:

- If `supportsPrChecks` is true and a PR exists, query with the `forge` tool
  `{ op: "pr-checks" }` (optionally `{ op: "pr-checks", watch: true, required: true }` when policy
  requires it) and classify the provider result as `passed`, `failed`, or `pending`.
- If the provider reports no checks for the PR head, record `remote: none` — never convert a local
  pass into `remote: passed`.
- If `supportsPrChecks` is false or no PR exists, record `remote: unavailable`.

**Flaky vs real**: a failure is flaky only if it **passes on a subsequent retry**. Consistent failure =
real bug. Local and remote failures are both real unless a retry passes; remote `none`/`pending` is
an absence of coverage, not a flaky pass.

- **If flaky** (max 3 retries): retry just the failing step.
- **If real bug** (max 5 fixes): fix → **fmt** → **commit** → retry CI. Under `--no-vcs`, drop **commit**
  from the loop. The draft PR already exists — pushes update it automatically.
- **If retries exhausted**: record `status: failed` and halt. The draft PR stays open as the record of
  the failed attempt.

**Recording**: when calling `agency_driver` with `{ op: "end", status: ..., verification: ... }`,
use a verification string of the form
`local: <status>; remote: <status>; head: <sha>` (plus any useful command/provider detail). The step
status must agree with that string: `passed` only for an accepted local+remote result.