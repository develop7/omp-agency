---
name: review-handoff
description: Prepare or consume reviewer context through OMP-native URI references. Use for delegated design reviews, diff reviews, cross-validation, correctness audits, and elegance passes, including retries and main-model fallbacks.
---

# Reviewer Handoff

This is the shared transport contract for Agency reviews. The calling workflow still owns scope, rules,
review methodology, output format, retry budgets, and reconciliation; this skill does not change them.

## Prepare once, reference everywhere

The orchestrator prepares all required inputs before spawning reviewers:

- Write authored briefs, assembled evidence, and resolved rules with `write` under a distinct
  `local://review-<round>/` path, regardless of payload size. Never stage reviewer payloads in `/tmp`,
  repository scratch files, or inline task arguments. External-repository scratch clones are not payloads.
- Keep existing harness-spilled output at its `artifact://<id>` URI and completed reviewer output at
  `agent://<id>`; reference those bytes directly rather than copying them just to use `local://`.
  Author an exact diff snapshot in `local://` only when no complete, stable native reference already exists.
- The brief contains the full user task, relevant research, exact review scope (commit IDs for revisions),
  and all workflow-required contracts. Include the full resolved rules and referenced-rule contents, not
  merely their original filenames. Link the complete diff and findings where required; retain deleted-side
  hunks for diff reviews. A plan or evaluation audit names that target instead of inventing a diff baseline.
- Resolve the project-rule files required by the invoking reviewer skills once before fan-out,
  including lens-specific additions when applicable. Preserve their source paths and record successful
  optional absence; discovery or read failures stop preparation, not select an empty rules bundle.
- Fetch a diff once for the review round. Do not substitute a moving branch or live PR diff for that
  snapshot, or ask each reviewer to independently fetch it. Reviewers may inspect source for evidence;
  supplied rules are authoritative and must not be rediscovered.

`task.context` and each item's `task` carry only read-first instructions, native input URIs, and the
reviewer's role/output requirements. For example: `Read skill://review-handoff, then read
local://review-<round>/brief.md and every required input in full before reviewing. Return findings only.`
The referenced brief, not inherited conversation or a prompt summary, supplies the substantive context.

## Consume completely

Before reviewing, read the brief and every required payload in full. Follow read pagination and omitted
ranges until complete; a truncated preview, structural summary, or URI alone is not the payload.
Do not turn original project-rule pointers into reviewer discovery work: their resolved contents must
already be in the supplied rules bundle. If any required input is missing, unreadable, or incomplete,
report the exact input and stop the review rather than silently narrowing scope or falling back to inline
context. The orchestrator repairs the handoff before retrying.

## Preserve the round

- Publish all inputs before fan-out and leave them unchanged until every reader finishes, including
  retries, cross-validation, targeted reconciliation reviews, and main-model fallbacks. Those consumers
  read the same brief, diff, rules, and prior findings; additional pass-specific inputs get separate files.
- `local://` and `agent://` are not immutable snapshots by themselves. Do not overwrite a referenced
  file or resume a referenced reviewer while the round uses its output. If that reviewer must be resumed,
  first preserve its exact completed output in a new `local://` snapshot and use that reference for
  subsequent consumers. Never replace verbatim findings with a summary.
- A changed task, scope, diff, or rules bundle starts a new round with distinct paths. Do not reuse a
  generic `review.md` across rounds. Once readers finish, fixes may proceed under the calling workflow's
  reconciliation rules. An elegance iteration that changes the tree prepares a new round for the next
  iteration rather than reviewing a stale diff.
- Retain payloads for OMP's session lifetime so later turns and fallbacks can read them. Use the native
  devices directly; do not add a storage service, transport switch, or task interception layer.

For a standalone review, the skill may receive the user's target directly. This contract governs context
handed between orchestrators and reviewers, not user input or an audit performed in the current context.
