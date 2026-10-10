---
name: hickey-lowy
description: Parallel structural review, reconciled across both lenses before applying fixes.
---

# Hickey + Lowy

## Requires

- `--minimal` flag
- `--no-vcs` flag
- Diff from the `vcs_read` tool with `{ op: "diff-range" }`
- Full task prompt + research context

## Ensures

- Both lenses reconciled before any review-driven edit
- Reconciled fixes applied as individual commits (or working-tree fixes under --no-vcs)
- Reconciled findings ledger for PR comment

## Strategies

Invoke `hickey` and `lowy` as two **parallel sub-agents** via the `task` tool (`agent: "hickey"` and
`agent: "lowy"`), in a single `tasks[]` batch. Reviewers report findings only; they must not edit files.
Keep the reviewed diff unchanged through both first-pass reviews, cross-validation, and reconciliation.
Do not apply even an uncontested finding while another review or reconciliation is pending. This gate
also applies to main-model fallback reviews and `--no-vcs` working-tree fixes.

**Fallback, never skip.** If a sub-agent invocation fails for harness/tooling reasons before producing
a review, retry that reviewer once; if it still cannot produce a sub-agent review, run that review in
the main model by loading the reviewer skill against the same diff **and the same brief** — the full
task prompt, research notes, and the baseline contract from the brief list below, verbatim. Do not
replace it with an informal review. Model selection lives in the agent definitions (`agents/*.md`, `model: "@task"`) — pass no
model override. The main-model fallback uses the reviewer's declared tool set (the frontmatter
`tools:` in `agents/{hickey,lowy}.md`) until findings are reported; apply fixes only after the
reconciliation gate below.

Each sub-agent prompt must be self-contained (sub-agents inherit no context). Brief each one with:

- The full task prompt plus anything relevant that **research** uncovered
- Scope: the actual diff from the `vcs_read` tool with `{ op: "diff-range" }`
- **Baseline contract**: "The diff's deleted side is the behavioral baseline: preserve deleted
  behavior unless the task explicitly requests a change. Every finding whose fix would make behavior
  stricter or semantically different must cite a deleted-side hunk demonstrating that exact behavior
  (restoring what the baseline had) or an explicit task requirement; otherwise do not raise it as a
  finding. Restoring a guard the deleted implementation demonstrably had is in scope."
- **Duplication-audit hint**, when the diff adds new files — check with the `vcs_read` tool using
  `{ op: "new-files" }` and only include the hint if the output is non-empty: survey the codebase
  for the canonical in-repo pattern for the same *kind* of operation and flag it as the headline finding
  if the diff reinvents rather than extends it

**Do not seed structural questions** beyond that hint — pre-formed questions ("is module X the right
home for Y?") produce circular reasoning at the reviewer. If a concern feels worth flagging, fix it in
the diff instead. (`RATIONALE.md`)

**Why post-implement, not pre-implement.** Both lenses bite harder on a concrete diff than on a plan
sketch: reviewing a plan surfaces generic concerns; reviewing a real diff surfaces the specific
interleavings and boundary misalignments that matter.

**No deferrals.** There is no "Defer" disposition — `/do` optimizes for the simpler artifact landing in
`master`, not for minimal diff. Findings have two dispositions: **Fix in this PR** and **No-op** (narrow:
the diff already deletes the offending code, or the finding is subsumed verbatim by another). If a
sub-agent emits anything resembling a defer — "out of scope", "follow-up", "pre-existing, separate PR" —
flip the disposition to **Fix in this PR** unconditionally and include it in reconciliation. Findings that
genuinely require coordination outside this repo shouldn't have surfaced as structural-review findings;
if one did, apply a local workaround or interface boundary in this PR and flag the upstream dependency
in the PR description as a strategic note, not a deferred finding.

**Cross-validate through both lenses.** Wait for both first-pass outputs. Skip only when both reviewers
returned zero findings. Otherwise, invoke **both skills again in parallel**, in a single `tasks[]`
batch, even if one lens returned zero findings: that lens must still audit the other lens's proposals.
Each self-contained prompt contains:

- The same unchanged diff used by the first-pass reviews
- The same baseline contract as the first-pass brief, verbatim — it governs the other reviewer's
  recommendations too: cross-validation must flag any recommendation whose fix would make behavior
  stricter or semantically different without citing a deleted-side hunk or an explicit task
  requirement, the same way it flags structural problems.
- Both reviewers' full findings outputs — paste verbatim; the cross-validator must see the
  recommendations being audited, not a summary
- The question, phrased neutrally: _"Apply your lens to the diff **and** to the other reviewer's
  recommendations. Does any recommendation, if applied, create a problem your lens would flag? If yes,
  surface it as a new finding with the same disposition rules (Fix in this PR / No-op, no Defer).
  Report findings only; do not edit files."_

**Reconcile before applying anything.** Wait for both cross-validation outputs, then reconcile every
first-pass and cross-validation finding into one ledger:

- Preserve each finding's source lens and pass, final disposition, rationale, and concrete fix.
- Combine duplicate or overlapping recommendations into one coherent fix; retain subsumed findings
  as **No-op** rows referencing the covering finding so no finding disappears.
- Resolve conflicting recommendations against the source and both lenses. Do not choose by arrival
  order, apply contradictory fixes sequentially, or treat a conflict as a deferral. If a conflict
  remains unresolved, send both lenses the unchanged diff, verbatim findings, and proposed resolution
  for targeted review before editing.
- Record the agreed fix and dependency order for every **Fix in this PR** row. The gate is complete
  only when every finding has a disposition and no conflicting fixes remain. When both first passes
  returned zero findings, record that outcome; there are no fixes to reconcile or apply.

Apply only the reconciled fixes, not the raw recommendations. For a cross-validation fix, use commit prefix
`refactor(hickey): cross-validate — <short label>` (or `refactor(lowy): cross-validate — …`) so the log
distinguishes cross-validation findings.

**Apply each reconciled "Fix in this PR" finding as its own commit**, in dependency order — do not batch.
A reviewer reading the PR's commit history should follow the structural refinement one finding at a time:

1. Apply the fix narrowly — only the lines that address this specific finding.
2. Run the project's format command on the changed files, if one is configured.
3. Call the `vcs_write` tool with `{ op: "fix-commit", message: "refactor(hickey): <short finding label>", files: ["<file1>", "<file2>", ...] }` (or `refactor(lowy): …`). Body restates the finding in one line; the dispatcher stages only the passed files and pushes.

**Under `--no-vcs`**: skip commit/push, not reconciliation. Apply only reconciled fixes to the working tree.

**Verify**: Both hickey and lowy produced review output. Cross-validation ran (or was correctly skipped
because both reviewers returned zero findings). The ledger reconciles all first-pass and
cross-validation findings, with no unresolved conflicts, before the first review-driven edit. Every
finding has a disposition — **Fix in this PR** or **No-op**, no defers; every No-op has its reason and
covering finding where applicable. Every reconciled Fix has a corresponding commit, except under
`--no-vcs`. Pass this ledger, including commit references, to **create-pr**.