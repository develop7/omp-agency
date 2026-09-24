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
`vcs_read`, `vcs_write`, `forge`, `workflow`, and `agency_driver` tools with the argument
objects documented by their schemas. Keep operation arguments in the `args` array where
the tool exposes one; use the hoisted fields on `vcs_write` for mutating VCS operations.

1. Parse arguments: `[--review] [--no-vcs] [--minimal] [--from <step-id>] [--base <branch> | --stack] <task>`.
   `--review`/`--no-vcs`/`--minimal`/`--from` go to `agency_driver` `init`; `--base`/`--stack` go to `agency_driver`
   `sync` (they select the stacked-PR base, which sync resolves and persists — `agency_driver` `init` rejects them).
2. Call the `agency_driver` tool with `{ op: "init", args: [<flags>, <task>] }` to initialize state.
3. Seed the task checklist by calling the `workflow` tool with `{ field: "cli_seed", from: "<from>" }` — it returns
   `[{ name, initial_status }]`; mark `completed` steps and seed the todo UI.
4. For each step, call the `workflow` tool with `{ field: "cli" }` — it returns
   `{ step, skip, pattern, instructions, requires, pattern_config }`.
    - If `skip` is true, call the `agency_driver` tool with `{ op: "skip", args: [<step>, <reason>] }` and continue.
    - Otherwise: call `agency_driver` with `{ op: "start", args: [<step>] }`, read `nodes/<step>.md`, do the work,
      then call `agency_driver` with `{ op: "end", args: [<status>, "<verification>", <reason>] }`.
5. When the `workflow` tool reports done, call `agency_driver` with `{ op: "summary", args: [] }`.

## Arguments

The workflow is **forge-aware**: during **sync**, call the `forge` tool with `{ op: "detect", args: [] }` and query
`{ op: "supports", args: [<op>] }` to persist `supportsX` capability booleans. Nodes and skip predicates branch on
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
(`vcs_read` with `{ args: ["base"] }`), so a stacked PR's review covers just that PR's changes, not the cumulative
stack. Deep stacks (>2) need a fresh `/do` per level; `/do` does not auto-restack when a parent merges.

## Results Tracking

Every node is bookended by calling `agency_driver` with `{ op: "start", args: [<name>] }` before work and
`{ op: "end", args: [<status>, "<verification>", <reason>] }` after verification. The driver records step state in
`.do-results.json`.

**Trust the driver's stdout.** Every mutation echoes a one-line confirmation. State schema, commands, and the full
field list (`vcs`, `forge`, `noVcs`, `minimal`, `review`, `base`, `active`, `status`) live in `.do-results.json` —
use `agency_driver` and `vcs_read` rather than re-deriving here. The one field worth calling out is `base`: written
by sync, read by every diff/log/branch op — it is what makes stacked PRs work.

**Discipline**: never call `end` without a prior `start`, and never use the `step` operation with `now` for both
timestamps. Don't run `date` yourself — `agency_driver` resolves UTC internally. Exceptions: sync is recorded by the
`agency_driver` `sync` operation itself, and skipped steps (duration 0) may use back-to-back `step-start`/`step-end skipped`.

## Progress tracking

Drive the harness's native todo UI so the user sees a live checklist (seed via `workflow cli_seed` as above).

- **Flip to `in_progress` when a step starts, `completed` when it verifies.** One step `in_progress` at a time.
- **Retries stay `in_progress`** until the step finally verifies or the workflow fails.
- **`--from` entry points**: seed the full list (minus `--minimal` omissions) and mark steps earlier than the entry
  point `completed` immediately after seeding.
- **Skipped steps that stay in the list** (VCS steps under `--no-vcs`, PR steps on unsupported forges) go straight to
  `completed`, recorded with back-to-back `step-start`/`step-end skipped`.
- `--minimal` omissions are in neither the CLI path nor the seeded list — never record a skip for them.
- **Failure**: leave the failing step `in_progress`, mark `done` `completed` after the failure summary is written, and
  call `agency_driver` with `{ op: "set", args: ["status", "failed"] }`.

## Entry Points

`workflow-manifest.json` is the sole declaration of accepted entry-point IDs and their starting steps. Both
`agency_driver init --from` and `workflow cli_seed` reject any unknown nonempty ID.

## Rules

- **Never skip steps** unless the `workflow` tool reports `skip = true`. The **evidence** node performs its own
  `.agency/do.md` configuration detection before deciding whether to record a skip. Run steps in order from entry
  point to **done**.
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