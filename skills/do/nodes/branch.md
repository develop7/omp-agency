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

Read `vcs` and `base` from `.do-results.json`. Then:

```
bash .../skills/do/scripts/vcs-op branch <descriptive-name>
```

No base argument — `vcs-op` reads the resolved `base` from state. The script handles the VCS-specific details: git creates `git branch <name> origin/<base>` (and hard-errors if `origin/<base>` is missing — the parent must be pushed before stacking); jj creates `jj new <base>` followed by `jj bookmark create <name> -r @`.

`base` is what makes stacked PRs work: it is the parent branch (not necessarily master/main). sync resolves it from `--base <branch>`, `--stack` (auto-detect the current feature branch), or the default branch. The PR created in **create-pr** targets this same `base`, and every review/diff op (hickey-lowy, police, test) diffs against it — so a stacked PR's review sees just this PR's changes, not the cumulative stack.

That's it — just the local branch. No commit, no push, no PR. The branch is pushed later in **commit**, and the PR is created in **create-pr** after all changes are done.

**Verify**: `bash scripts/vcs-op head-revision` returns the new branch name (not master/main).
