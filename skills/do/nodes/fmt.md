---
name: fmt
description: Run the project's format command.
---

# Fmt

## Requires

- Code changes (implementation or fixes)

## Ensures

- Formatted code

## Strategies

Read `.agency/do.md` and look for a `## Format command` section. Run it. If no format command is
documented, this is a node-local skip: record it with
`agency_driver { op: "end", status: "skipped", reason: "no format command in .agency/do.md" }`
(see [Two skip spellings](../SKILL.md#two-skip-spellings)).

**Verify**: format command ran without error, or no command configured.
