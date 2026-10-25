---
name: docs
description: Keep documentation in sync with code changes.
---

# Docs

## Requires

- `--minimal` flag
- Implemented code

## Ensures

- Documentation matches current code

## Strategies

Read `.agency/do.md` and look for a `## Documentation` section listing which docs to keep in sync
(e.g. README.md). Compare those files against changes in this PR; fix what's stale. If no
documentation files are documented, this is a node-local skip: record it with
`agency_driver { op: "end", status: "skipped", reason: "no Documentation section in .agency/do.md" }`
(see [Two skip spellings](../SKILL.md#two-skip-spellings)).

**Verify**: docs match current code.
**If outdated** (max 3 attempts): fix the outdated sections and re-verify.
