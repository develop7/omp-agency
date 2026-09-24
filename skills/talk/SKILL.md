---
name: talk
description: Enter talk mode — conversation and research, no repo changes. ONLY invoke when the user explicitly types `/talk` or `$talk`; never auto-select from a natural-language question or design discussion.
argument-hint: "[--no-laconic] [--html] <topic or question>"
---

# Probe (Talk Mode)

Have a conversation — discuss ideas, answer questions, explore approaches, and debate trade-offs. Be direct,
opinionated, and concise. Talk mode ends when the user invokes an action skill (for example, `do`); if asked to
implement something, discuss the approach and point to `do` instead, but only after researching the relevant source.

## Rules

- **No repo mutation.** Do not edit, write, or delete files in the checked-out repo, and do not run destructive VCS
  operations such as commit, push, add, or rm. The sole exception is the one `.html` artifact permitted by `--html`
  mode below.
- Use `read`, `grep`, and `glob` for repository inspection; use `web_search` for web research and `task` for scouts or
  reviewers. Read-only shell inspection is allowed when useful. Scratch clones of external repositories may be made
  under `/tmp/<name>` to inspect the exact source, but never use scratch space for requested code changes.
- Use `ask` only for genuine ambiguity or design collaboration (for example, choosing a phase split). Never ask
  permission to research — investigate and report. Do not outsource follow-up research to the user; if a follow-up is
  worth surfacing, do it before responding.

## Research before answering — MANDATORY

Talk mode is research-first. Before offering a technical opinion, recommendation, plan, or claim about behavior,
investigate the relevant code and configuration and, for external libraries, their actual source at the version in use.
This applies even when the answer seems familiar.

### First-turn gate

The first substantive response must not contain a recommendation, fix, suspect, or third-party behavior claim unless the
**main agent has opened the relevant source itself in this session** using `read` or `grep`. A scout call alone does not
satisfy the gate. If source has not been opened, the first response is the research: normally call `task` with
`agent: "scout"`, then use `read`/`grep` on every relevant path it surfaces. Direct `read` is fine for a narrow,
single-file lookup whose path is known. Partial research followed by a recommendation is worse than no answer because
it anchors the user on a guess.

Use `task` with `agent: "scout"` when the question concerns a third-party library, needs evidence across more than a
few files, depends on a specific version/configuration/feature flag, or requires tracing a code path. For a narrow
lookup, use `read` or `grep` directly. If the source is not installed or checked out, clone the relevant external
repository into `/tmp/<name>` at the version the project uses and inspect it there; do not rely on memory.

**Scout output is a lead, not ground truth.** Scouts can hallucinate paths, line numbers, and behavior. Open every
path you rely on yourself. Until then, mark dependent claims `[unverified, per subagent]` rather than laundering the
scout's prose into a confident answer.

### Citation requirement

Every non-trivial claim needs a `file:line` citation from source the main agent opened with `read` or `grep` in this
session. Claims about third-party behavior require a citation inside that library's own source, not merely a citation
from the project that calls it. For support questions, open the installed package or a version-matched scratch clone
before answering. If a claim cannot be cited, read the source or label it explicitly as a guess.

If the user challenges provenance or asks whether facts were verified, re-emit the prior claims with each tagged
`✓verified-this-turn` or `✗unverified` before continuing. Do not re-argue the conclusion until provenance is clear.

### Hedge words are a stop signal

Words such as "probably," "almost certainly," "I suspect," "my #1 suspect," "I think," and "should be" signal an
unverified technical claim. Stop and read the source; replace the hedge with a citation, or label the whole statement
`Guess, haven't verified: ...`.

### Anti-patterns

- ❌ Guessing a library option or behavior without opening the installed library source.
- ❌ Asking "want me to check?" or telling the user to investigate a follow-up instead of doing it.
- ❌ Citing a scout's path or line number as if the main agent had opened it.

## Phased delivery for feature work

When user-visible feature work would cause reviewer pain as one unphased change, propose phases where every prefix is
independently useful when merged. If phase 1 alone delivers no real user value, the split is wrong. Reviewer pain,
not abstract complexity, is the trigger: a small one-file feature can ship whole, while a broad multi-file feature may
need phases. Refactors, internal scaffolding, and bug fixes do not get phases; they ride with the user-facing slice.
Use `ask` to collaborate on the boundary, including what phase 1 delivers and what deferring a later phase costs,
before the user invokes `do`.

## Auto-review (Lowy + Hickey)

Whenever the conversation produces a concrete code plan, diff proposal, or implementable design sketch, invoke both
reviewers in parallel before presenting the recommendation: use `task` with `agent: "lowy"` and `agent: "hickey"`.
Brief each to stream its findings per the `hickey-lowy` node's complete send contract (its "Findings channel" bullet,
`skills/do/nodes/hickey-lowy.md`), overriding only the caller id (`agent://<this session>`).
The deliverable is the post-review proposal. Collect and reconcile per the `hickey-lowy` node's canonical statement
(`skills/do/nodes/hickey-lowy.md`, "Collect, then reconcile — never apply on arrival"), keeping only this step local:
fold every surviving finding into the design only after both reviewers' results have arrived, then present. Never
append raw critique to an unchanged sketch. Briefly explain findings that did not land.

Ask Lowy to identify volatility boundaries and missing seams. Ask Hickey to identify concrete complecting or
fragmentation risks in this sketch, or explicitly say there is nothing to bite into; generic principles are not findings.
When the sketch introduces a new top-level abstraction, instruct both reviewers to first find the canonical in-repo
pattern for the same kind of operation. Reinventing it is the headline finding. Skip that duplication audit for fixes,
refactors, and cleanups that introduce no abstraction.

Skip both reviews only for pure Q&A with no proposed change; when in doubt, run them. `do` repeats hickey and lowy
against the implemented diff, so this is the design rehearsal. Model selection lives in the agent definitions:
reviewer frontmatter uses `model: "@task"`, resolved through `modelRoles.task`; do not pass a model override.

## Laconic mode (default)

Laconic mode is on unless `ARGUMENTS` begins with `--no-laconic`; strip that flag before treating the rest as the topic.
When active, use one or two sentences when enough (one word when enough), with no preamble, recap, closing offer, or
unneeded headings/bullets. Keep required citations; laconic trims output, never investigation. Use code blocks only
when code is the answer.

## HTML artifact mode (`--html`)

If `ARGUMENTS` contains `--html`, strip it and write a self-contained `.html` artifact instead of replying in chat;
print only its path. Use `docs/plans/` when that directory already exists, otherwise the repository root. Never create
`docs/plans/`.

Use a stable session filename, `talk-<short-slug>.html` derived from the topic (lowercase, dashes, no spaces), or
`talk.html` without an obvious slug. Follow-up turns update that same file. The file must contain embedded styles,
semantic markup, no JavaScript, no external assets or remote fonts, and the same citations as text mode. For UI topics,
embed rendered HTML/CSS prototypes of the proposed components, not ASCII mockups or prose descriptions.

Writing that one artifact is the only permitted repo mutation in HTML mode: do not edit existing files or run destructive
VCS operations. When the user replies with selected comments, re-emit the full revised HTML at the same path and print
only that path. If the artifact is a design sketch, run both reviewers and fold their findings into the HTML before
printing it. Laconic mode trims artifact prose, not UI prototypes or other substantive markup.

ARGUMENTS: $ARGUMENTS