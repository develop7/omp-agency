---
name: hickey-lowy
description: Parallel structural review with hickey and lowy sub-agents.
---

# Hickey + Lowy

## Requires

- `--minimal` flag
- `--no-vcs` flag
- Diff from the `vcs_read` tool with `{ args: ["diff-range"] }`
- Full task prompt + research context

## Ensures

- Reconciled review findings applied as individual commits (or working-tree fixes under --no-vcs) —
  application starts only after both reviewers are done and their findings are reconciled
- Findings ledger for PR comment

## Strategies

Invoke `hickey` and `lowy` as two **parallel sub-agents** via the `task` tool (`agent: "hickey"` and
`agent: "lowy"`), both `task` calls emitted in a single response.

**Fallback, never skip.** A failed attempt is one that ends without a terminal result — partial
streamed findings do not count as produced. On failure for harness/tooling reasons, retry that
reviewer invocation once (its fresh stream supersedes the partial one); if the retry still yields no
terminal result, run that review in the main model by loading the reviewer skill against the same
diff. Do not replace it with an informal review. Model selection lives in the agent definitions (`agents/*.md`, `model: "@task"`) — pass no
model override. The main-model fallback uses the reviewer's declared tool set (the frontmatter
`tools:` in `agents/{hickey,lowy}.md`) until findings are reported, under the named role **caller
(fallback)**: its findings enter the collected set directly — there is no stream because the channel
would be in-process self-delivery — and its terminal result keeps the standard shape (summary line
plus `undelivered` entries). It enters the same collect → reconcile pipeline before anything is
applied.

Each sub-agent prompt must be self-contained (sub-agents inherit no context). Brief each one with:

- The full task prompt plus anything relevant that **research** uncovered
- Scope: the actual diff from the `vcs_read` tool with `{ args: ["diff-range"] }`
- **Findings channel (the complete send contract)**: ONE `write` per finding as it forms —
  `path: "agent://<caller>"`, `content: <entry>` — carrying the skill's **Actions** entry verbatim
  (`agent://Main` unless this brief names another caller id). An amendment names the bolded label of
  the entry it replaces (the label is the entry's key); the latest word per key wins. On a failed
  `write`: retry once, then mark that entry `undelivered` in the result. The terminal result is ONE
  summary line plus those `undelivered` entries — the only finding-shaped content a result may carry;
  everything else is never a findings list.
- **Duplication-audit hint**, when the diff adds new files — check with the `vcs_read` tool using
  `{ args: ["new-files"] }` and only include the hint if the output is non-empty: survey the codebase
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
flip the disposition to **Fix in this PR** unconditionally and apply the fix here. Findings that
genuinely require coordination outside this repo shouldn't have surfaced as structural-review findings;
if one did, apply a local workaround or interface boundary in this PR and flag the upstream dependency
in the PR description as a strategic note, not a deferred finding.

**Collect, then reconcile — never apply on arrival.** The reviewers stream each finding the moment it
forms, and each result auto-delivers when its reviewer finishes ("resume your work" is not a license to
apply). Collect per lens: its streamed messages (latest word per entry key wins). The terminal result
adds exactly one kind of content to the set: its `undelivered` entries, merged with equal standing. A
result carrying any other finding-shaped content is a malformed result — treat the attempt as failed
(retry, then fallback) rather than letting it replace collected findings. A fallback or retried
attempt supersedes that lens's earlier partial stream wholesale (a retry supersedes by its fresh
stream). Edit nothing for any finding while
either reviewer is still running — call `wait` until BOTH reviewers' results have arrived, or spend
the gap only on non-application work (the same move when `wait` is unavailable). Once BOTH are done,
reconcile the collected findings into one disposition set:

- **Dedupe** — a finding both lenses report becomes one row carrying both lenses and one commit:
  `refactor(hickey+lowy): <short label>`.
- **Resolve disagreements** with the `/lowy` ↔ `/hickey` rule (`skill://lowy`, "Relationship to
  /hickey"): *unify the volatile axis without complecting the strategies*. If unification needs a mode
  flag, conditional branch, or type-switch, find the layer where it is mechanical.
- **Latest word wins** — a later message from a lens amends or retracts its earlier findings.

**Cross-validate the parallel findings.** Skip only when both reviewers returned zero findings.
Otherwise, for each reviewer that produced findings, spawn a **second invocation of that same skill**
in parallel, with a self-contained prompt containing:

- The actual diff (`vcs_read` with `{ args: ["diff-range"] }`)
- The reconciled disposition set — each row carrying its source entries verbatim (merged rows carry
  both lenses' raw text); the cross-validator must audit the recommendations that will be applied, not
  a summary
- The findings channel: the same complete send contract as the first pass (above) — stream each
  finding as it forms, ONE `write` to `agent://<caller>` per Actions entry
- The question, phrased neutrally: _"Apply your lens to the diff **and** to the other reviewer's
  recommendations. Does any recommendation, if applied, create a problem your lens would flag? If yes,
  surface it as a new finding with the same disposition rules (Fix in this PR / No-op, no Defer)."_

Treat any new finding identically to a first-pass finding, with commit prefix
`refactor(hickey): cross-validate — <short label>` (or `refactor(lowy): cross-validate — …`) so the log
distinguishes cross-validation findings. New cross-validation findings re-enter **collect → reconcile**
before any application.

**Apply each "Fix in this PR" finding as its own commit** — do not batch. A reviewer reading the PR's
commit history should follow the structural refinement one finding at a time:

1. Apply the fix narrowly — only the lines that address this specific finding.
2. Run the project's format command on the changed files, if one is configured.
3. Call the `vcs_write` tool with `{ op: "fix-commit", message: "refactor(hickey): <short finding label>", files: ["<file1>", "<file2>", ...] }` (or `refactor(lowy): …`; a merged row uses `refactor(hickey+lowy): …`). Body restates the finding in one line; the dispatcher stages only the passed files and pushes.

**Under `--no-vcs`**: skip commit/push. Apply fixes to the working tree and move on.

**Verify**: Both hickey and lowy are done and produced a terminal result (zero findings is a valid
result). The reconciled disposition set exists — dedupes merged, disagreements resolved, latest word
applied.
Cross-validation ran (or was correctly skipped because both reviewers returned zero findings). No
application — commit or working-tree edit — predates both reviewers' completion. Every finding has a
disposition — **Fix in this PR** or **No-op**, no defers. Every Fix has a corresponding commit, except
under `--no-vcs`.
