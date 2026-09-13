---
name: code-police
description: Review code for quality, simplicity, and common mistakes before declaring work complete.
argument-hint: "[--no-elegance]"
---

# Code Police

Review the current changes (scoped to the current branch/PR) against the rules below plus any project rules. The three passes — rule checklist, fact-check, elegance — run on fresh sub-agent contexts: the implementer's main context just wrote the diff and is biased to rationalize it. The orchestrator stitches their findings into one summary.

## Arguments

`--no-elegance` — skip Pass 3 entirely and report `Elegance | – | Skipped (--no-elegance)`. Passes 1–2 still run. Use when the `elegance` skill loop already ran over this same tree; otherwise Pass 3 repeats a near-guaranteed no-op.

## Project rules

Before spawning passes, read `.agency/code-police.md` if it exists. Its inline rules or file pointers are additions to the built-in list and appear as separate Pass 1 rows under the project's rule IDs. If missing, use the built-in rules only.

## Reviewing principles

Apply these to every pass and to the orchestrator; push back on any sub-agent prose that violates them rather than laundering its dismissal into the summary:

- **NEVER talk yourself out of a finding.** No "However…", "acceptable tradeoff", or "theoretically X but practically Y" dismissal.
- **NEVER issue "no action needed"** on a finding you just described, and never end with reassurance unless you genuinely found zero issues.
- **Assume the code is wrong until proven right.** Review as a prosecutor, not a defense attorney.

## Rules

### dry-rule-of-three

Two similar instances are fine; three is the threshold for extraction. Identical content that must stay in sync (HTML, version strings, ports, paths) is deduplicated immediately regardless of count.

### prefer-focused-library

Before hand-rolling a tokenizer, parser, date/semver/URL helper, CLI argument parser, tree walker, regex matcher, or path normalizer, search for a focused library and prefer it — even as a new dependency — when scope fit and bundle cost are reasonable. "Zero deps" is an easiness judgment: code you do not own does not bitrot and its edge cases are someone else's problem. Hand-roll only when the library adds capabilities you actively do not want, or the hand-roll is genuinely a few branch-free lines. Neither "already in the tree" nor "only ~40 lines" is a gate; judge scope fit and bundle cost in both directions (left-pad exists).

### invalid-states-unrepresentable

Use discriminated unions, not booleans or stringly-typed fields. If two fields cannot both be `undefined`, model that in the type.

### no-dead-code

Aggressively remove unused code: no commented-out blocks and no "just in case" leftovers.

### no-silent-error-swallowing

Never silently swallow errors. Empty `catch {}` blocks, bare `catch: pass`, and `|| true` hide failures; at minimum, log the error. An intentional best-effort catch must comment why ignoring the error is safe.

### no-unbounded-growth

Collections, buffers, and listeners that grow with usage need a bound or cleanup path: cap or evict arrays pushed from handlers; debounce or throttle high-frequency handlers (`fs.watch`, `resize`, `scroll`, `mousemove`, WebSocket `onmessage`) unless their work is O(1) and allocation-free; stream instead of buffering a whole growing source; and share watchers instead of installing one per caller. LLM-generated code defaults to the simplest correct implementation, often O(n) in session lifetime; fix this at write time with cap, debounce, stream, or share rather than relying on review to catch a functionally correct leak.

### comment-the-non-obvious

At every non-trivial declaration or block, ask whether a reader who did not write it can tell **what it does** and **why it has this shape**. Comment whichever is missing: design intent, control-flow semantics, or a hidden constraint the type system does not carry. "Obvious to me because I just wrote it" is the failure mode.

## Running the passes

Spawn Pass 1 and Pass 2 as two parallel, read-only `task` sub-agents with `agent: "scout"`; emit both calls in one response so they run concurrently. Pass 3 runs only after both return because it applies fixes and would race their reads. Skip it under `--no-elegance`. Then stitch all outputs into the summary.

Each scout starts without the implementer's context and must use this file as the rules of record.

### Pass 1: Rule checklist

The Pass 1 scout must read the Reviewing principles and Rules here plus `.agency/code-police.md` if present; scope the current diff with `vcs_read {args: ["diff-range"]}`; and return one table covering **every** built-in and project rule:

| Rule ID | Violation found? | What was identified | Action taken |
| ------- | ---------------- | ------------------- | ------------ |

Every "No" requires a **`Checked by:`** field: use a grep-for-absence for purely negative rules (such as `no-dead-code` and `no-silent-error-swallowing`), or enumerate positive candidates and why each was ruled out for bidirectional rules (such as `comment-the-non-obvious` and `prefer-focused-library`). A "No" without `Checked by:` is malformed. Do not skip rows or apply fixes; the orchestrator routes findings.

### Pass 2: Fact-check

The Pass 2 scout must read and apply the Reviewing principles, scope the current diff with `vcs_read {args: ["diff-range"]}`, and perform a logic review rather than a style review. Find where the code lies to itself:

- silent error swallowing and inaccurate fallbacks that mask misconfiguration;
- unvalidated boundary inputs, code that can fail despite "can't fail" assumptions, and races papered over with comments;
- always-true or false conditions, off-by-one errors, wrong operators, and shadowing;
- slow leaks: unbounded collections, undebounced hot handlers, per-caller watchers, and whole-input buffers where streaming would work.

Fail loud over fail silent; every fallback needs a reason for its failure case; prefer precision over coverage. For each finding return the file, line, one-line risk, and concrete fix. Do not apply fixes.

### Pass 3: Elegance

Skip under `--no-elegance` and report `Elegance | – | Skipped (--no-elegance)`. Otherwise obtain the shortstat with `vcs_read {args: ["diff-stat"]}`. If the diff is under 10 lines, report `Elegance | 0 | Skipped (tiny diff)`; Passes 1–2 still run.

For a larger diff, run the `elegance` skill loop for three iterations. Each iteration: understand the changed files and their unnecessary complexity; research simple, elegant, readable patterns with `web_search`; apply a refactor favoring fewer lines, clearer intent, and idiomatic style without adding abstractions; and verify with tests/CI. Simple beats clever, readable beats terse, idiomatic beats generic, and each iteration builds on the last. The Reviewing principles bind here too.

## Output

Stitch the pass outputs into one combined summary:

| Pass       | Issues found | Details                  |
| ---------- | ------------ | ------------------------ |
| Rules      | N            | Brief summary or "Clean" |
| Fact-check | N            | Brief summary or "Clean" |
| Elegance   | N            | Brief summary or "Clean" |

Below the table, reproduce each pass's full findings verbatim — the Pass 1 rule table, Pass 2 findings, and Pass 3 elegance-loop log — so `/do` can commit each violation individually. If any pass found issues, state **"Violations or issues found"**. If all passes are clean, state **"All clear"**.

## Additional principles

### Simple, not easy (Rich Hickey)

Simple means not interleaved: each module does one thing, and data flows through arguments and return values rather than shared mutable state or indirection. Avoid unnecessary abstractions and "for future use" code; prefer plain data over objects with behavior.

### Completeness

Implement the full spec. Read the plan or requirements and check every deliverable. Run CI locally and run tests before declaring done.

### Justfile

Every recipe must have a doc comment (a line starting with `#` above the recipe name).

### Module structure — volatility-based decomposition

Group code by rate of change, not technical layer: things that change together belong together, while independently changing things belong in separate modules. Each module owns one volatility zone; shared constants used by multiple modules get their own file.

### Readability

Every exported type and every component needs a doc comment. Avoid deeply nested callbacks; extract named functions.