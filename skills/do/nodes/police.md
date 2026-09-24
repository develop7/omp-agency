---
name: police
description: Three-pass quality gate.
---

# Police

## Requires

- `--minimal` flag
- `--no-vcs` flag
- Diff from the `vcs_read` tool with `{ args: ["diff-range"] }`

## Ensures

- All 3 passes clean
- Violation fixes committed individually (or working-tree fixes under --no-vcs)

## Strategies

Use the `vcs_read` tool with `{ args: ["diff-names"] }` to check if the PR contains code changes. If all
changed files are documentation-only (`.md`, `.txt`, README, docs/) — skip this step with reason
`"docs-only changes"`.

Otherwise, read the `code-police` skill via `read skill://code-police` and invoke it. When it asks about
scope: **changes in the current branch/PR only**.

**Commit each violation fix individually** — same rule as hickey+lowy: one commit per violation, not a
lump. For each violation reported across the three passes, in turn:

1. Apply the fix for that one violation — scope the edit tightly.
2. Run the project's format command on changed files, if configured.
3. Call the `vcs_write` tool with `{ op: "fix-commit", message: "<prefix>: <short description>", files: ["<file1>", "<file2>", ...] }` with the conventional prefix:
   - Rules pass: `fix(police): <rule-id> — <short description>`
   - Fact-check pass: `fix(police): fact-check — <short description>`
   - Elegance pass: `refactor(police): elegance — <short description>`

**Under `--no-vcs`**: skip commit/push. Apply fixes to the working tree.

**Verify**: All 3 passes clean ("All clear").
**If violations found** (max 3 attempts): fix them and re-invoke the `code-police` skill.