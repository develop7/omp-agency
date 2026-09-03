---
name: sync
description: Fetch origin, detect forge, resolve base, initialize workflow state.
---

# Sync

## Requires

- `--no-vcs` flag (parsed by `agency_driver` `init`)

## Ensures

- `forge` — `github`, `bitbucket`, or `unknown` (classified by the `forge` tool's `detect` operation; the sole classifier)
- `supportsPrCreate`, `supportsPrComment`, `supportsIssueView`, `supportsPrChecks` —
  capability booleans pre-computed by querying the `forge` tool's `supports` operation for the ops
  nodes actually branch on. Nodes and skip predicates branch on these instead of on
  the forge string; `pr-view`/`pr-edit` are omitted (no reader — trusted to follow
  `pr-create`).
- `branch` — current branch name
- `defaultBranch` — origin HEAD ref name (the base-resolution input)
- `base` — resolved base branch (branch-from + PR target). Equals `defaultBranch` unless `--base <branch>` or `--stack` was passed; this is what enables stacked PRs.

## Strategies

Call the `agency_driver` tool with `{ op: "sync", args: [<noVcs>, "--base", <branch>] }` or
`{ op: "sync", args: [<noVcs>, "--stack"] }` (omit the base-selection arguments when neither is requested).

The tool:

- Detects the VCS (`.jj/` → `jj`, `.git/` → `git`, else `unknown`) via the `vcs_read` tool with `{ args: ["detect"] }`
  (which reads `.do-results.json#vcs` if present, else probes the filesystem). All subsequent VCS
  operations delegate to `vcs_read` and `vcs_write`, which map semantic operation names to the active tool.
- Fetches the default remote (`git fetch origin` / `jj git fetch`).
- Pins `origin/HEAD` (git only).
- If `--no-vcs` is **not** set and the branch is behind origin (ahead-count 0), fast-forwards
  with `git pull --ff-only`. Under `--no-vcs`, fetch happens but the working tree is not touched —
  uncommitted work is preserved.
- Prints the dirty-tree hint to stderr (no pause) when the tree is dirty and `--no-vcs` is not set:

  > _Dirty tree detected. Continuing will create a fresh branch on top of these changes. If
  > you wanted the agent to extend your WIP in place without touching git, re-run with
  > `--no-vcs`._
- Classifies the forge by calling the `forge` tool with `{ op: "detect", args: [] }` — the `forge` tool owns the URL→forge
  classifier (`github.com` → `github`, `bitbucket.` (covers `bitbucket.org` and self-hosted servers
  like `bitbucket.juspay.net`) → `bitbucket`, otherwise `unknown`). Sync no longer carries its own
  copy of the glob set.
- Pre-computes forge capability booleans by calling the `forge` tool with `{ op: "supports", args: [<op>] }` for each
  op nodes branch on (`pr-create`, `pr-comment`, `issue-view`, `pr-checks`) and stashes them via
  `agency_driver` with `{ op: "set", args: ["supportsX", <bool>] }`. Downstream nodes and skip predicates read these booleans
  instead of branching on the forge string — the forge → supported-ops map lives in the `forge` tool's
  capability table.
- Resolves `base` (`--base <branch>` → that branch; `--stack` → the current feature branch, else
  default; otherwise the default branch) and stashes it via `agency_driver` with `{ op: "set", args: ["base", <value>] }`;
  downstream ops read it in-process via the `vcs_read` tool rather than re-threading it.
- Calls `agency_driver` with `{ op: "step", args: ["sync", "passed", <verification>, <startedAt>, <completedAt>] }`.
- Prints `vcs=`, `forge=`, `branch=`, `defaultBranch=`, `base=` on stdout for downstream steps.

**Only `github` has an active code path today.** Both `bitbucket` and `unknown` yield `supportsX = false` for all ops,
causing forge-dependent steps (PR creation, PR comments, PR edits, CI status) to skip gracefully. Bitbucket support is
planned — see [srid/agency#10](https://github.com/srid/agency/issues/10). When it lands, only the `forge` tool's capability
table and dispatch arms change; sync, nodes, and `workflow.ncl` are untouched.

**Verify**: The `agency_driver` `sync` operation exited 0 and printed `vcs=`, `forge=`, `branch=`, `defaultBranch=`, `base=` lines on stdout. (Sync silences
the underlying state-operation confirmation echoes so the protocol stays clean.)