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

Call the `agency_driver` tool once with `{ op: "sync", args: [<noVcs>, "--base", <branch>] }` or
`{ op: "sync", args: [<noVcs>, "--stack"] }` (omit the base-selection arguments when neither is requested).
This single model-facing call performs all context resolution in the shared PureScript core; it does not recursively call
`vcs_read`, `forge`, or another `agency_driver` tool.

The core sync operation:

- Resolves the VCS from state and filesystem inputs, then resolves the forge from the same context and remote URL.
- Fetches the default remote (`git fetch origin` / `jj git fetch`).
- Pins `origin/HEAD` (git only).
- If `--no-vcs` is **not** set and the branch is behind origin (ahead-count 0), fast-forwards
  with `git pull --ff-only`. Under `--no-vcs`, fetch happens but the working tree is not touched —
  uncommitted work is preserved.
- Prints the dirty-tree hint to stderr (no pause) when the tree is dirty and `--no-vcs` is not set:

  > _Dirty tree detected. Continuing will create a fresh branch on top of these changes. If
  > you wanted the agent to extend your WIP in place without touching git, re-run with
  > `--no-vcs`._
- Computes forge capability booleans for `pr-create`, `pr-comment`, `issue-view`, and `pr-checks` using the shared forge
  capability table.
- Resolves `base` (`--base <branch>` → that branch; `--stack` → the current feature branch, else
  default; otherwise the default branch), writes all resolved fields to `.do-results.json`, and records the `sync` step.
- Prints `vcs=`, `forge=`, `branch=`, `defaultBranch=`, `base=` on stdout for downstream steps. Later nodes use the
  read/write/forge tools independently; sync does not re-enter those model-facing tools.

**Only `github` has an active code path today.** Both `bitbucket` and `unknown` yield `supportsX = false` for all ops,
causing forge-dependent steps (PR creation, PR comments, PR edits, CI status) to skip gracefully. Bitbucket support is
planned — see [srid/agency#10](https://github.com/srid/agency/issues/10). When it lands, only the `forge` tool's capability
table and dispatch arms change; sync, nodes, and `workflow.ncl` are untouched.

**Verify**: The `agency_driver` `sync` operation exited 0 and printed `vcs=`, `forge=`, `branch=`, `defaultBranch=`, `base=` lines on stdout. (Sync silences
the underlying state-operation confirmation echoes so the protocol stays clean.)