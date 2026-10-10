---
name: check
description: Fast static-correctness gate.
---

# Check

## Requires

- Implemented code

## Ensures

- Static correctness verified

## Strategies

Read `.agency/do.md` and look for a `## Check command` section — a fast static-correctness gate (e.g.
`tsc --noEmit`, `cargo check`, `mypy`). Run it. This is the cheapest gate in the pipeline, so it runs
first — fail fast on broken code before any downstream step works over it. If no check command is
documented, skip this step with a note.

**Verify**: check ran without errors, or no command configured.
**If failed** (max 3 attempts): fix the errors and re-run check. Do not fall back to **implement** —
the failure is local to just-written code and this step stays in fix mode.