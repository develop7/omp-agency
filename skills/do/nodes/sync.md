---
name: sync
description: Fetch origin, detect forge, resolve base, initialize workflow state.
---

# Sync

## Requires

- `--no-vcs` flag (parsed by `agency_driver` `init`)

## Ensures

- `vcs` — the detected VCS
- `forge` — `github`, `bitbucket`, or `unknown` (classified by the `forge` tool's `detect` operation; the sole classifier)
- `supportsPrCreate`, `supportsPrComment`, `supportsIssueView`, `supportsPrChecks` — capability
  booleans pre-computed by querying the `forge` tool's `supports` operation for the ops nodes branch
  on. Nodes and skip predicates branch on these instead of on the forge string, so the forge →
  supported-ops map lives in one place (the `forge` tool's capability table).
- `branch`, `defaultBranch`, `base` — current branch, origin HEAD ref name, and the resolved base
  (branch-from + PR target). `base` equals `defaultBranch` unless `--base <branch>` or `--stack` was
  passed; this is what enables stacked PRs.

## Strategies

Call the `agency_driver` tool **once** with `{ op: "sync", args: [<noVcs>, "--base", <branch>] }`,
`{ op: "sync", args: [<noVcs>, "--stack"] }`, or just `{ op: "sync", args: [<noVcs>] }` when neither
base selector is requested. This single model-facing call performs all context resolution in the
shared PureScript core — it resolves the VCS and forge, fetches the default remote, pins `origin/HEAD`
(git), fast-forwards when clean (preserving the tree under `--no-vcs`), prints the dirty-tree hint to
stderr (no pause) when the tree is dirty and `--no-vcs` is not set, computes the forge capability
booleans, resolves `base`, writes all resolved fields to `.do-results.json`, records the sync step,
and prints `vcs=`, `forge=`, `branch=`, `defaultBranch=`, `base=` on stdout for downstream steps. It
does not recursively re-enter the model-facing tools.

**Only `github` has an active code path today.** Both `bitbucket` and `unknown` yield
`supportsX = false` for all ops, causing forge-dependent steps (PR creation, PR comments, PR edits,
CI status) to skip gracefully. Bitbucket support is planned — [srid/agency#10](https://github.com/srid/agency/issues/10).
When it lands, only the `forge` tool's capability table and dispatch arms change; sync, nodes, and
`workflow.ncl` are untouched.

**Verify**: the `agency_driver` `sync` operation exited 0 and printed all five lines — `vcs=`, `forge=`,
`branch=`, `defaultBranch=`, `base=` — on stdout. (Sync silences the underlying state-operation
confirmation echoes so the protocol stays clean.)

`branch=` is whatever the `vcs_read` op `head-revision` reports — under jj the bookmark on `@`,
else the bookmark on `@-`. It is empty when no feature bookmark is checked out (the state before
the **branch** node runs); that line stays present but carries no value, and `base=` remains the
usable fact for downstream steps.