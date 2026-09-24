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
documentation files are documented, skip this step with a note.

**Verify**: docs match current code.
**If outdated** (max 3 attempts): fix the outdated sections and re-verify.