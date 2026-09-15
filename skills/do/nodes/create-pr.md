---
name: create-pr
description: Open a draft PR on the detected forge.
---

# Create PR

## Requires

- `--no-vcs` flag
- Primary feature commit pushed

## Ensures

- Draft PR exists
- hickey/lowy findings posted as PR comment

## Strategies

Check whether a PR already exists for this branch by calling the `forge` tool with `{ op: "pr-view", args: [] }`.

**If no PR exists** (first run, normal path):

1. Create a draft PR by calling the `forge` tool with
   `{ op: "pr-create", args: ["--draft", "--head", "<current branch>", "--base", "<base>", "--title", "..."], body: "<body>" }`.

   `<current branch>` must be a real branch/bookmark the forge can target — under jj, the feature
   bookmark from the **branch** node. `head-revision` may still report the **base** bookmark name
   (the bookmark on the working copy's parent) before the branch bookmark exists, so the reported
   branch must also differ from `base`: if it equals `base` or is empty, the feature bookmark is
   missing — create it before opening the PR.

   **MANDATORY**: read the `forge-pr` skill via `read skill://forge-pr` **before** writing the PR
   title/body. Pass the body through the tool's `body` field so backticks and `$` survive unescaped —
   the tool writes a temporary body file and passes it to `gh` verbatim.

2. **Post hickey/lowy results** as a PR comment by calling the `forge` tool with
   `{ op: "pr-comment", args: [], body: "<comment>" }` under a
   `## [Hickey/Lowy](https://kolu.dev/blog/hickey-lowy/) Analysis` header — always when the step ran,
   even if every finding was a No-op. Compose a single findings-ledger table from both sub-agents'
   Actions sections so a reviewer sees disposition at a glance, with each lens's prose underneath:

   ```md
   ## [Hickey/Lowy](https://kolu.dev/blog/hickey-lowy/) Analysis

   | # | Lens   | Finding                                | Disposition      |
   |---|--------|----------------------------------------|------------------|
   | 1 | Hickey | viewportDimensions complects two roles | Fixed in this PR |
   | 2 | Lowy   | clipboard.ts named after a consumer    | ⚠️ **No-op**     |

   ### Hickey rationale
   <prose>

   ### Lowy rationale
   <prose>
   ```

   The Disposition cell mirrors the sub-agent's Actions disposition verbatim. **Render every No-op as
   `⚠️ **No-op**`** so the rows a human most needs to scrutinize (a finding acknowledged but not fixed)
   stand out. There is no Deferred disposition — the audit step flipped any defer to Fixed in this PR.
   If both lenses produced zero findings, write a one-line "No findings — analysis below" instead of an
   empty table.

**If a PR already exists** (followup runs, `--from` entry points): re-check the PR title/body against
current scope. If scope changed, update via the `forge` tool with `{ op: "pr-edit", args: [...], body: "<updated body>" }`
per the `forge-pr` skill.

**Why this runs before `ci`**: the draft PR is the canonical home for CI status — checks land directly
on it, reviewers see run history as it happens, and a failing run doesn't leave an orphaned branch. If
retries exhaust in **ci**, the draft PR remains the visible, reviewable record, ready to resume via
`--from ci-only`.

**Verify**: the `forge` tool with `{ op: "pr-view", args: [] }` succeeds, PR title/body matches the
delivered scope, and the hickey/lowy findings comment was posted.