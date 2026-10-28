---
name: do
description: Do a task end-to-end — implement, PR, CI loop, ship. ONLY invoke when the user explicitly types `/do` or `$do`; never auto-select from a natural-language request, even one that sounds like an end-to-end task.
argument-hint: "<issue-url | prompt> [--review] [--no-vcs] [--minimal] [--from <step-id>] [--base <branch> | --stack]"
---

# Do Workflow

Take a task and do it top-to-bottom: research, branch, implement, pass CI, open a PR, and ship. Under `--no-vcs`,
extend the working tree in place — no branch, commit, or PR.

> All paths in this skill are relative to the skill's base directory.

**This is a workflow graph.** The ordered step and entry-point vocabulary lives in [`workflow-manifest.json`](workflow-manifest.json); skip predicates and pattern configs live in [`workflow.ncl`](workflow.ncl); each step's activity is a node file under [`nodes/`](nodes/). The agent is the runtime — there is no separate engine.

**Mostly autonomous.** Do NOT use the `ask` tool at any point (except during the `--review` planning pause). Make
sensible default choices and keep moving.

## How to walk the graph

**Convention: workflow operations are tool invocations, not shell commands.** Use the
`vcs_read`, `vcs_write`, `forge`, `workflow`, and `agency_driver` tools with the argument objects documented by their schemas. Supply operation-specific named fields; `vcs_read` uses `op` and, where supported, `paths`.

1. Parse arguments: `[--review] [--no-vcs] [--minimal] [--from <step-id>] [--base <branch> | --stack] <task>`.
   `--review`/`--no-vcs`/`--minimal`/`--from` go to `agency_driver` `init`; `--base`/`--stack` go to `agency_driver`
   `sync` (they select the stacked-PR base, which sync resolves and persists — `agency_driver` `init` rejects them).
2. Call `agency_driver` with `{ op: "init", task?: <task>, review?: <bool>, noVcs?: <bool>, minimal?: <bool>, restart?: <bool>, from?: <entry> }` to initialize state.
3. Seed the task checklist by calling the `workflow` tool with `{ field: "cli_seed", from: "<from>" }` — it returns
   a JSON array `[{ name, initial_status }]`; mark `completed` steps and seed the todo UI.
4. For each step, call the `workflow` tool with `{ field: "cli" }` — it returns a JSON object
   `{ step, skip, pattern, instructions, requires, pattern_config }`, or `{ "done": true }`.
   - **Otherwise**: call `agency_driver { op: "start", step: <step> }`, read `nodes/<step>.md`, do the work.
     When the step finishes, call `agency_driver` with
     `{ op: "end", status: "passed" | "failed" | "skipped", verification: <verification>, reason?: <reason> }`.
     `status: "skipped"` requires `reason` — it is the node-local skip spelling: the step is already
     active and discovered it has nothing to do (see [Results Tracking](#results-tracking)).
5. When the `workflow` tool reports done, call `agency_driver` with `{ op: "summary" }`.

## Arguments

The workflow is **forge-aware**: during **sync**, call the `forge` tool with `{ op: "detect" }` and query
`{ op: "supports", operation: <op> }` to persist `supportsX` capability booleans. Nodes and skip predicates branch on
these booleans — not on the forge string — so the forge → supported-ops map lives in one place (the `forge` tool's
capability table). Today only GitHub has an active code path; other forges skip PR-related steps gracefully. Tracking:
[srid/agency#10](https://github.com/srid/agency/issues/10).

- `--review`: Pause after **research** for user plan approval via the `ask` tool, then continue autonomously.
  **Incompatible with `--from=<non-default>`**: the plan-approval pause would be silently dropped. `agency_driver`
  `init` errors out on the conflict; drop one of the flags.
- `--no-vcs`: Extend the working tree **in place** — no branch, commit, push, or PR. VCS-mutating nodes skip with
  `reason="--no-vcs"`.
- `--minimal`: Omit **docs**, `hickey-lowy`, **police**, and **evidence** from both the CLI path and todo list.
- `--from <step-id>`: Start from a declared entry point. IDs and starting steps are defined solely by
  [`workflow-manifest.json`](workflow-manifest.json).
- `--base <branch>`: Branch from `<branch>` and target the PR at it — **stacked PRs**. The parent must be pushed (git
  requires `origin/<branch>`; jj requires the bookmark to exist). Mutually exclusive with `--stack`; incompatible
  with `--no-vcs`.
- `--stack`: Auto-detect the base as the current branch when it is a feature branch (≠ default), else the default
  branch. Mutually exclusive with `--base`; incompatible with `--no-vcs`.

**Base vs default branch.** The workflow branches from, diffs against, and targets the PR at a single resolved `base`.
Without `--base`/`--stack`, `base` is the default branch (origin HEAD). Every review/diff op reads `base` from state
(`vcs_read` with `{ op: "base" }`), so a stacked PR's review covers just that PR's changes, not the cumulative
stack. Deep stacks (>2) need a fresh `/do` per level; `/do` does not auto-restack when a parent merges.
Entry points that skip `sync` (`followup`, `post-implement`, `polish`, `ci-only`) inherit `base` from the prior run's
state at `init`; for a different PR target set it explicitly with `agency_driver({ op: "set", field: "base", value: "<target>" })`.

## Results Tracking

### Two skip spellings

There are two legal ways to record a skipped step, and which one you use depends on **when** the skip is decided:

- **Scheduler skip** — `workflow cli` reports `skip: true` for a step you have NOT yet started.
  Record it with `agency_driver { op: "skip", step: <step>, reason: <reason> }`. This refuses with
  `pendingStep '<step>' already active` if the step is already active — it is the wrong spelling
  for a node-local skip.
- **Node-local skip** — the step is already active (`start` was called) and the node discovers it
  has nothing to do (e.g. no `## PR evidence` section in `.agency/do.md`, no check command
  configured). Close it with `agency_driver { op: "end", status: "skipped", reason: <reason> }`.
  The reason is **required** for a skipped end — the driver refuses a reasonless skipped completion.

Rule of thumb: `skip` is for "don't start this." `end skipped` is for "started, but there's nothing to do."

Every node is bookended by calling `agency_driver` with `{ op: "start", step: <name> }` before work and
`{ op: "end", status: "passed" | "failed" | "skipped", verification: <verification>, reason?: <reason> }` after verification. The driver records step state in
`.do-results.json`.
**Trust the driver's result data.** Mutations return their resulting state, step, field, or job as JSON; sync retains its prose protocol.
The state schema, commands, and field list (`vcs`, `forge`, `noVcs`, `minimal`, `review`, `base`, `active`, `status`) live in `.do-results.json` —
use `agency_driver` and `vcs_read` rather than re-deriving here. The one field worth calling out is `base`: written
by sync, read by every diff/log/branch op — it is what makes stacked PRs work.

Data results are JSON in model-facing content and available as `details: { op, value }`.
Oversized values (more than 32 KiB of serialized UTF-8 JSON) remain complete in content
but have `details.value: null`; prose-only operations also have a null value.
File-list reads return JSON arrays: `[]` means no matching paths, not a nonempty listing.
The CLI still emits its human-readable confirmations.

**Discipline**: never call `end` without a prior `start`, and never use the `step` operation with `now` for both
timestamps. Don't run `date` yourself — `agency_driver` resolves UTC internally. Exceptions: sync is recorded by the
`agency_driver` `sync` operation itself, and skipped steps (duration 0) may use back-to-back `step-start`/`step-end skipped`.

## Progress tracking

Drive the harness's native todo UI so the user sees a live checklist (seed via `workflow cli_seed` as above).

- **Flip to `in_progress` when a step starts, `completed` when it verifies.** One step `in_progress` at a time.
- **Retries stay `in_progress`** until the step finally verifies or the workflow fails.
- **`--from` entry points**: seed the full list (minus `--minimal` omissions) and mark steps earlier than the entry
  point `completed` immediately after seeding.
- **Skipped steps that stay in the list** (scheduler skips under `--no-vcs`, unsupported forges) go straight to
  `completed`, recorded with `agency_driver { op: "skip", step, reason }`. **Node-local skips** (the step was
  active and discovered it has nothing to do) are also `completed`, recorded with
  `agency_driver { op: "end", status: "skipped", reason }` — always with a reason.
- `--minimal` omissions are in neither the CLI path nor the seeded list — never record a skip for them.
- **Failure**: leave the failing step `in_progress`, mark `done` `completed` after the failure summary is written, and
  call `agency_driver` with `{ op: "set", field: "status", value: "failed" }`.

## Entry Points

`workflow-manifest.json` is the sole declaration of accepted entry-point IDs and their starting steps. Both
`agency_driver init --from` and `workflow cli_seed` reject any unknown nonempty ID.

## Rules

- **Never scheduler-skip steps** unless the `workflow` tool reports `skip = true` — that is when
  `agency_driver { op: "skip" }` is legal. **Node-local skips are always legal**: when an active step
  discovers it has nothing to do, close it with
  `agency_driver { op: "end", status: "skipped", reason: <reason> }` (see
  [Two skip spellings](#two-skip-spellings)). Run steps in order from entry point to **done**.
- **Every commit is NEW.** Never amend, rebase, or force-push.
- **Always commit through `vcs_write`.** Never run raw `git`/`jj` mutating commands directly. The dispatcher stages
  only the files you pass (git) or splits unrelated working-copy changes into a separate revision above the feature
  commit (jj) and leaves `@` on a fresh empty change (jj) — raw commands sweep unrelated changes into the commit (git)
  or amend the existing change (jj). The canonical banned-primitive list lives in `scripts/lint-vcs-refs.sh`
  (`VCS_PATTERNS`).
- **Feature branches only.** Never commit to master/main.
- **Background for CI.** Run CI with `async: true` on the bash tool if the command takes more than a few seconds.
- **No questions.** Don't use the `ask` tool outside the `--review` plan pause (post-research).
- **Never stop between steps.** After completing a step, immediately proceed to the next one.
- **Complete the full workflow.** The task is not done until a PR URL (forge with PR support), a pushed branch name
  (forge without PR support), or a working-tree summary (`--no-vcs`) is reported.
- **Exhausted retries = halt.** If `ci` or `test` retries are exhausted, set status to `"failed"` and skip to **done**.
