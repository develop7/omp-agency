---
name: branch
description: Create a descriptive feature branch from the resolved base.
---

# Branch

## Requires

- `--no-vcs` flag
- `base` from sync (the resolved branch-from target)

## Ensures

- Feature branch checked out

## Strategies

Call the `vcs_write` tool with `{ op: "branch", name: "<descriptive-name>" }`.

No base argument — `vcs_write` reads the resolved `base` from state. The tool handles VCS-specific
details: git creates the branch from `origin/<base>` (hard-erroring if that ref is missing — the
parent must be pushed before stacking); jj creates a new change on `<base>` and a bookmark pointing
at it.

`base` is what makes stacked PRs work: it is the parent branch (not necessarily master/main), resolved
by sync from `--base <branch>`, `--stack`, or the default branch. create-pr targets this same `base`
and every review/diff op (hickey-lowy, police, test) diffs against it — a stacked PR's review sees
just that PR's changes.

That's it — just the local branch. commit pushes it, create-pr opens the PR later.

**Verify**: calling the `vcs_read` tool with `{ args: ["head-revision"] }` returns the new branch name
(not master/main).