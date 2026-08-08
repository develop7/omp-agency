---
name: sync
description: Fetch origin, detect forge, resolve base, initialize workflow state.
---

# Sync

## Requires

- `--no-vcs` flag (parsed by `do-driver init`)

## Ensures

- `forge` — `github`, `bitbucket`, or `unknown` (classified by `forge-op detect`; the sole classifier)
- `supportsPrCreate`, `supportsPrComment`, `supportsIssueView`, `supportsPrChecks` —
  capability booleans pre-computed by querying `forge-op supports <op>` for the ops
  nodes actually branch on. Nodes and skip predicates branch on these instead of on
  the forge string; `pr-view`/`pr-edit` are omitted (no reader — trusted to follow
  `pr-create`).
- `branch` — current branch name
- `defaultBranch` — origin HEAD ref name (the base-resolution input)
- `base` — resolved base branch (branch-from + PR target). Equals `defaultBranch` unless `--base <branch>` or `--stack` was passed; this is what enables stacked PRs.

## Strategies

Run the `bash scripts/steps/sync` script in this skill's directory, passing `true` or `false` for `--no-vcs` plus any base-selection flag:

```
bash .../skills/do/scripts/steps/sync <noVcs> [--base <branch> | --stack]
```

The script:

- Detects the VCS (`.jj/` → `jj`, `.git/` → `git`, else `unknown`) via `bash scripts/vcs-op detect`
  (which reads `.do-results.json#vcs` if present, else probes the filesystem). All subsequent VCS
  operations delegate to `bash scripts/vcs-op` which maps semantic operation names to the active tool.
- Fetches the default remote (`git fetch origin` / `jj git fetch`).
- Pins `origin/HEAD` (git only).
- If `--no-vcs` is **not** set and the branch is behind origin (ahead-count 0), fast-forwards
  with `git pull --ff-only`. Under `--no-vcs`, fetch happens but the working tree is not touched —
  uncommitted work is preserved.
- Prints the dirty-tree hint to stderr (no pause) when the tree is dirty and `--no-vcs` is not set:

  > _Dirty tree detected. Continuing will create a fresh branch on top of these changes. If
  > you wanted the agent to extend your WIP in place without touching git, re-run with
  > `--no-vcs`._
- Classifies the forge by calling `bash scripts/forge-op detect` — forge-op owns the URL→forge
  classifier (`github.com` → `github`, `bitbucket.` (covers `bitbucket.org` and self-hosted servers
  like `bitbucket.juspay.net`) → `bitbucket`, otherwise `unknown`). Sync no longer carries its own
  copy of the glob set.
- Pre-computes forge capability booleans by calling `bash scripts/forge-op supports <op>` for each
  op nodes branch on (`pr-create`, `pr-comment`, `issue-view`, `pr-checks`) and stashes them via
  `do-results set supportsX <bool>`. Downstream nodes and skip predicates read these booleans
  instead of branching on the forge string — the forge → supported-ops map lives in `forge-op`'s
  capability table.
- Resolves `base` (`--base <branch>` → that branch; `--stack` → the current feature branch, else
  default; otherwise the default branch) and stashes it via `do-results set base <value>`;
  downstream ops read it in-process via vcs-op's `get_base_branch` rather than re-threading it.
- Calls `bash scripts/do-results init` then `bash scripts/do-results step sync passed ...`.
- Prints `vcs=`, `forge=`, `branch=`, `defaultBranch=`, `base=` on stdout for downstream steps.

**Only `github` has an active code path today.** Both `bitbucket` and `unknown` yield `supportsX = false` for all ops,
causing forge-dependent steps (PR creation, PR comments, PR edits, CI status) to skip gracefully. Bitbucket support is
planned — see [srid/agency#10](https://github.com/srid/agency/issues/10). When it lands, only `forge-op`'s capability
table and dispatch arms change; sync, nodes, and `workflow.ncl` are untouched.

**Verify**: Script exited 0 and printed `vcs=`, `forge=`, `branch=`, `defaultBranch=`, `base=` lines on stdout. (Sync silences
`do-results`' own confirmation echoes so the protocol stays clean.)