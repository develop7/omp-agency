---
name: plan-approval
description: Pause after research for user plan approval (only when --review).
---

# Plan Approval

## Requires

- `--review` flag
- Plan from research

## Ensures

- Approved plan

## Strategies

Use the `ask` tool to present the approach for user approval:

- **Clarify ambiguities** first — ask via the `ask` tool if anything is unclear. Don't guess.
- **High-level plan**: what to do and why, not implementation details. Include an **Architecture section** (affected modules, new abstractions, ripple effects).
- **Split non-trivial plans into phases** — MVP first, each phase functionally self-sufficient.

Present the plan via `ask` and let the user approve or modify. Once approved, continue autonomously.

Structural critique from hickey/lowy isn't available at this point — it runs post-implement on a concrete diff and surfaces as commits + a PR comment later.
