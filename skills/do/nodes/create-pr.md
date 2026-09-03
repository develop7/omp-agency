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

1. Create a draft PR by calling the `forge` tool with `{ op: "pr-create", args: ["--draft", "--head", "<current_branch_name>", "--base", "<base branch name>", "--title", "..."], body: "<body>" }`.

   **MANDATORY**: Read the `forge-pr` skill via `read skill://forge-pr` BEFORE writing the PR title/body. Pass the body through the tool's `body` field so backticks and `$` survive unescaped — the tool writes a temporary body file and passes it to `gh` verbatim.

2. **Post hickey/lowy results**: Post the hickey and lowy analysis as a PR comment by calling the `forge` tool with `{ op: "pr-comment", args: [], body: "<comment>" }`, with a
   `## [Hickey/Lowy](https://kolu.dev/blog/hickey-lowy/) Analysis` header.

   **Format the comment with a leading findings ledger.** Compose a single table from both sub-agents' Actions sections:

   ```md
   ## [Hickey/Lowy](https://kolu.dev/blog/hickey-lowy/) Analysis

   | # | Lens   | Finding                                  | Disposition         |
   |---|--------|------------------------------------------|---------------------|
   | 1 | Hickey | viewportDimensions complects two roles   | Fixed in this PR    |
   | 2 | Lowy   | useViewport encapsulates ghost concern   | Fixed in this PR    |
   | 3 | Lowy   | clipboard.ts named after a consumer      | ⚠️ **No-op**        |

   ### Hickey rationale
   <prose>

   ### Lowy rationale
   <prose>
   ```

   The Disposition cell mirrors the sub-agent's Actions disposition verbatim — **Fixed in this PR** or **No-op** (
   deletion-only / subsumed by another finding). **Render every No-op as `⚠️ **No-op**`** (warning emoji + bold) so the
   reviewer's eye lands on it; No-op rows are the ones a human most needs to scrutinize (a finding the reviewer
   acknowledged but didn't fix), and plain text lets them blend into the Fixed-in-this-PR rows above. There is no
   Deferred disposition; if a sub-agent emitted one, the audit step above flipped it to Fixed in this PR. The Finding
   cell is the short bolded label the sub-agent emits at the start of each Actions entry. If both lenses produced zero
   findings, write a one-line "No findings — analysis below" instead of an empty table.

**If PR already exists** (followup runs, `--from` entry points):

Re-check the PR title/body against current scope. If scope changed, update via the `forge` tool with `{ op: "pr-edit", args: [...], body: "<updated body>" }` per the `forge-pr` skill.

**Why this runs before `ci`**: The draft PR is the canonical home for CI status. Opening it before CI runs means CI
checks land directly on the PR, reviewers see the run history as it happens, and a failing run doesn't leave an orphaned
branch with red statuses and no PR to explain them.

**Verify**: Draft PR exists (the `forge` tool with `{ op: "pr-view", args: [] }` succeeds), PR title/body matches the delivered scope, hickey/lowy findings
posted if any.
