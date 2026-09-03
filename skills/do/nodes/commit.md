---
name: commit
description: Create the primary feature commit and push.
---

# Commit

## Requires

- `--no-vcs` flag
- Formatted code

## Ensures

- Primary feature commit on feature branch
- Branch pushed to remote

## Strategies

Create a NEW commit (never amend) with a conventional commit message for the primary implementation, then push:

```
call the `vcs_write` tool with `{ op: "commit", message: "<message>", files: ["<file1>", "<file2>", ...] }`
call the `vcs_write` tool with `{ op: "push", ref: "<branch>" }`
```

The `vcs_write` schema keeps variants separate: `commit` requires a non-empty
`message` and `files` list, while `push` accepts only its optional `ref`.

**Pass the files that belong to this feature** — the files you changed during **implement**. The dispatcher stages only the files you pass and preserves unrelated working-copy changes (see `SKILL.md` ## Rules for the git/jj mechanics). `vcs_write` push sets upstream on first push (git).

**Follow-up commits (hickey-lowy, police) go through `vcs_write` `fix-commit`** — the dispatcher leaves `@` on a fresh empty change, so the next finding's edits land as a separate commit on top. See `SKILL.md` ## Rules for the no-raw-VCS-commands invariant.

This is the **primary feature commit**. Downstream **hickey-lowy** and **police** steps produce their own follow-up commits — one per finding or violation addressed — which keeps the PR history a readable progression of "what was built, then what was refined" rather than a single opaque squash.

**Verify**: calling the `vcs_read` tool with `{ args: ["log-head"] }` shows a new commit on the feature branch, and it's pushed to remote.
