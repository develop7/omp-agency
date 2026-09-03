---
name: do
description: Do a task end-to-end — implement, PR, CI loop, ship. ONLY invoke when the user explicitly types `/do` or `$do`; never auto-select from a natural-language request, even one that sounds like an end-to-end task.
argument-hint: "<issue-url | prompt> [--review] [--no-vcs] [--minimal] [--from <step-id>] [--base <branch> | --stack]"
---

# Do Workflow

Take a task and do it top-to-bottom: research, branch, implement, pass CI, open a PR, and ship. (Under `--no-vcs`,
extend the working tree in place — no branch, commit, or PR.)

> All paths in this skill are relative to the skill's base directory.

**This is a workflow graph.** Step order, skip predicates, and pattern configs live in [`workflow.ncl`](workflow.ncl);
each step's activity is a node file under [`nodes/`](nodes/). The agent is the runtime — there is no separate engine.

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
2. Call the `agency_driver` tool with `{ op: "init", args: [<review/no-vcs/minimal/from flags>, <task>] }` to initialize state.
3. Seed the task checklist using Nickel:
   ```
   call the workflow tool with { field: "cli_seed", from: "<from>" }
   ```
   This returns `[{ name, initial_status }]` — mark `completed` steps and seed the todo UI.
4. For each step, ask Nickel what to do next:
   ```
   call the workflow tool with { field: "cli" }
   ```
   This returns `{ step, skip, pattern, instructions, requires, pattern_config }`.
    - If `skip` is true, call the `agency_driver` tool with `{ op: "skip", args: [<step>, <reason>] }` and continue.
    - Otherwise: call the `agency_driver` tool with `{ op: "start", args: [<step>] }`, read
      `nodes/<step>.md`, do the work, then call the `agency_driver` tool with
      `{ op: "end", args: [<status>, "<verification>", <reason>] }`.
5. When Nickel returns `{ done = true }`, call the `agency_driver` tool with `{ op: "summary", args: [] }`.

## Arguments

The workflow is **forge-aware**: it auto-detects whether the repo lives on GitHub or elsewhere during the **sync** step,
which delegates classification to the `forge` tool with `{ op: "detect", args: [] }` and pre-computes `supportsX` capability
booleans by querying the `forge` tool with `{ op: "supports", args: [<op>] }`. Nodes and skip predicates branch on these
booleans — they don't branch on the forge string, so the forge → supported-ops map lives in one place (the `forge` tool's
capability table). The `forge` string itself stays in state as the table's input but is no longer a node-facing dependency.
Today only GitHub has an active code path; Bitbucket/other forges gracefully skip PR-related steps. Tracking: [srid/agency#10](https://github.com/srid/agency/issues/10).

- `--review`: Pause after **research** for user plan approval via the `ask` tool (present the plan, let the user approve or modify), then continue
  autonomously. **Incompatible with `--from=<non-default>`** (any entry that skips research — `followup`,
  `post-implement`, `polish`, `ci-only`): the plan-approval pause would be silently dropped. `agency_driver` `init`
  errors out on the conflict; drop one of the flags.
- `--no-vcs`: Extend the working tree **in place** — do not create a branch, commit, push, or touch any PR. VCS-mutating
  nodes skip with `reason="--no-vcs"`.
- `--minimal`: Skip **docs**, `hickey-lowy`, **police**, and **evidence** (omitted from todo list entirely).
- `--from <step-id>`: Start from a specific node. Entry points: `default`→sync, `followup`→implement, `post-implement`
  →fmt, `polish`→hickey-lowy, `ci-only`→ci.
- `--base <branch>`: Branch from `<branch>` and target the PR at it — **stacked PRs**. The parent must be pushed (git
  requires `origin/<branch>`; jj requires the bookmark to exist). Mutually exclusive with `--stack`; incompatible with
  `--no-vcs`.
- `--stack`: Auto-detect the base as the current branch when it is a feature branch (≠ default), else the default
  branch. Invoked while on a feature bookmark, this stacks the new PR on top of it. Mutually exclusive with `--base`;
  incompatible with `--no-vcs`.

**Base vs default branch.** The workflow branches from, diffs against, and targets the PR at a single resolved `base`.
With neither `--base` nor `--stack`, `base` is the default branch (origin HEAD) — today's behavior. `--base`/`--stack`
make `base` a feature branch so a PR can stack onto its parent. Every review/diff op reads `base` from state
(`vcs_read` with `{ args: ["base"] }`), so a stacked PR's review covers just that PR's changes, not the cumulative stack. Deep stacks (>2) need
a fresh `/do` per level (each run re-resolves its own `base`); `/do` does not auto-restack when a parent merges.

## Results Tracking

Every node is bookended by calling the `agency_driver` tool with `{ op: "start", args: [<name>] }` before work and
`{ op: "end", args: [<status>, "<verification>", <reason>] }` after verification. The driver records step state in
`.do-results.json`.

**Trust the driver's stdout.** Every mutation echoes a one-line confirmation.

State schema, commands, and the full field list (`vcs`, `forge`, `noVcs`, `minimal`, `review`, `base`, `active`,
`status`) live in `.do-results.json` — use the `agency_driver` and `vcs_read` tools when you need them rather than
re-deriving here. The one field worth calling out in the workflow contract is `base`: written by `sync`, read by
`vcs_read` for every diff/log/branch op — it is what makes stacked PRs work.

**Discipline**:

- Bookend every step with `agency_driver` `start` at the top and `end` at the bottom. Calling `end` without a prior
  `start` is an error; calling the `step` operation with `now` for both timestamps collapses duration to 0 — neither pattern is
  allowed. Exceptions: `sync` is recorded by `agency_driver` `sync` itself, and skipped steps (duration always 0) may use
  back-to-back `step-start` / `step-end skipped`.
- Don't run `date` yourself or guess timestamps — `agency_driver` resolves UTC internally.

## Progress tracking

Drive the harness's native todo UI so the user sees a live checklist. Call the `workflow` tool with
`{ field: "cli_seed", from: "<from>" }` to get the initial step list with correct statuses.

Rules:

- **Flip to `in_progress` when a step starts, `completed` when it verifies.** One step `in_progress` at a time.
- **Retries stay `in_progress`.** If `check`, `test`, or `ci` loop through their retry budget, do **not** bounce the
  task state back to `pending` or flicker it — leave it `in_progress` until the step finally verifies (or the retries
  exhaust and the workflow fails).
- **`--from <step>` entry points**: still seed the full list (minus any `--minimal` omissions). Mark steps earlier than
  the entry point as `completed` immediately after seeding, so the checklist shows a consistent view regardless of entry
  point.
- **Skipped steps that stay in the list** (e.g. `branch`/`commit`/`create-pr` under `--no-vcs`, or PR steps on
  forges that don't support them) go straight to `completed`. Record the skip with a back-to-back
  `agency_driver` call `{ op: "step-start", args: [<name>] }` / `{ op: "step-end", args: ["skipped", ... , "<reason>"] }`; the task list just
  shows the step as done. `--minimal` skips are **not** in this category — they're omitted from the seeded list
  entirely (see above), so there''s no task entry to flip.
- **Failure**: if retries exhaust and the workflow halts, leave the failing step `in_progress`, mark `done` `completed`
  after the failure summary is written, and call `agency_driver` with `{ op: "set", args: ["status", "failed"] }`.

## Entry Points

| ID               | Starts at             | Use case                                |
| ---------------- | --------------------- | --------------------------------------- |
| `default`        | **sync**              | Full workflow from scratch              |
| `followup`       | **implement**         | Additional changes on existing PR       |
| `post-implement` | **fmt**               | Skip research/impl, start at formatting |
| `polish`         | **hickey+lowy**       | Structural review + quality gate        |
| `ci-only`        | **ci**                | Just run CI                             |

## Rules

- **Never skip steps** (unless Nickel reports `skip = true`, or — for **evidence** — the project hasn't filled in a
  `## PR evidence` section in `.agency/do.md`). Run them in order from entry point to **done**.
- **Every commit is NEW.** Never amend, rebase, or force-push.
- **Always commit through `vcs_write`.** Never run raw `git`/`jj` mutating commands directly. The dispatcher stages only the files you pass (git) or splits unrelated working-copy changes into a separate revision above the feature commit (jj) and leaves `@` on a fresh empty change (jj) — raw commands sweep unrelated changes into the commit (git) or amend the existing change (jj). The canonical banned-primitive list lives in `scripts/lint-vcs-refs.sh` (`VCS_PATTERNS`).
- **Feature branches only.** Never commit to master/main.
- **Background for CI.** Run CI with `async: true` on the bash tool if the command takes more than a few seconds.
- **No questions.** Don't use the `ask` tool outside the `--review` plan pause (post-research).
- **Never stop between steps.** After completing a step, immediately proceed to the next one.
- **Complete the full workflow.** The task is not done until a PR URL (forge with PR support), a pushed branch name
  (forge without PR support), or a working-tree summary (`--no-vcs`) is reported.
- **Exhausted retries = halt.** If `ci` or `test` retries are exhausted, set status to `"failed"` and skip to **done**.
