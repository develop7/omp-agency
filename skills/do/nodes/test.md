---
name: test
description: Run relevant tests.
---

# Test

## Requires

- Implemented code
- Changes in current branch

## Ensures

- Tests pass
- New behavior is actually exercised

## Strategies

Read `.agency/do.md` and look for a `## Test command` section. Run only the tests relevant to the
code paths changed in this PR — use the `vcs_read` tool with `{ args: ["diff-names"] }` to identify
changed files. If no test command is documented, skip with a note.

If changes are purely internal with no user-facing impact, unit tests may suffice — skip e2e if no
relevant scenarios exist.

**Coverage gap check**: after the test command exits 0, confirm at least one of the tests run actually
exercised the new behavior (per the **implement** step's classification). A green run that didn't
touch the changed code paths is a coverage gap, not a pass — treat it as a real failure: write the
missing test, then loop **fmt** → **commit** → **test**. Refactor/docs/internal-cleanup diffs are
exempt.

**Verify**: tests pass (exit code 0) **and** the new behavior is covered, or the diff is exempt, or no
relevant tests to run.
**If failed** (max 4 attempts): analyze the failure. If flaky, re-run. If real: fix → **fmt** → retry.