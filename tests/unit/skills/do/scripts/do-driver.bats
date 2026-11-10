#!/usr/bin/env bats
# Unit tests for do-driver — the state-machine command surface.
# Tests delegation: init flags, start/end/skip/set pass through, summary calls done.
# State is read back through `do-driver state`, never from a worktree file.

setup() {
  load "$REPO_ROOT/tests/helpers/setup.bash"
  load "$REPO_ROOT/tests/helpers/git-fixtures.bash"
  setup_test_dir
}

teardown() {
  teardown_test_dir
}

run_driver() {
  run node "${AGENCY_DO_BIN:-$REPO_ROOT/pure/dist/agency-do.js}" do-driver "$@"
}

run_api_driver() {
  run env AGENCY_API_BUNDLE="${AGENCY_API_BUNDLE:-$REPO_ROOT/pure/dist/agency-api.js}" \
    node --input-type=module --eval \
    'const { runTool } = await import(process.env.AGENCY_API_BUNDLE); const result = await runTool({ tool: "agency_driver", args: JSON.parse(process.env.AGENCY_DRIVER_ARGS), captureOutput: true, stateRoot: null, workspaceDir: null })(); process.stdout.write(JSON.stringify(result)); process.exitCode = result.exit'
}

@test "init creates a worktree snapshot with default flags" {
  run_driver init "my task"
  [ "$status" -eq 0 ]
  [[ $output == *"review=false"* ]]
  [[ $output == *"noVcs=false"* ]]
  [[ $output == *"minimal=false"* ]]
  [[ $output == *"from=default"* ]]

  run state_jq -r '.task'
  [ "$status" -eq 0 ]
  [ "$output" = "my task" ]
}

@test "init refuses corrupt state without replacing it" {
  run_driver init "first task"
  [ "$status" -eq 0 ]
  corrupt_state_store 'not json'

  run_driver init "recovered task"

  [ "$status" -eq 1 ]
  [[ $output == *"corrupt or unreadable"* ]]
  # The stored payload is untouched: it still fails to parse.
  run driver_state
  [ "$status" -ne 0 ]
}

@test "init --restart replaces corrupt state with clean initialization" {
  run_driver init "first task"
  [ "$status" -eq 0 ]
  corrupt_state_store 'not json'

  run_driver init --restart "recovered task"

  [ "$status" -eq 0 ]
  run state_jq -e '.task == "recovered task" and .active == "working" and .status == "running" and .steps == []'
  [ "$status" -eq 0 ]
}

@test "API init --restart replaces corrupt state but summary remains strict" {
  run_driver init "first task"
  [ "$status" -eq 0 ]
  corrupt_state_store 'not json'

  AGENCY_DRIVER_ARGS='["init","--restart","recovered task"]' run_api_driver
  [ "$status" -eq 0 ]
  run state_jq -e '.task == "recovered task" and .active == "working" and .status == "running" and .steps == []'
  [ "$status" -eq 0 ]

  corrupt_state_store 'not json'
  AGENCY_DRIVER_ARGS='["summary"]' run_api_driver
  [ "$status" -eq 1 ]
  run driver_state
  [ "$status" -ne 0 ]
}

@test "init --review sets review=true" {
  run_driver init --review "my task"
  [ "$status" -eq 0 ]
  [[ $output == *"review=true"* ]]
  run state_jq -r '.review'
  [ "$output" = "true" ]
}

@test "init --no-vcs sets noVcs=true" {
  run_driver init --no-vcs "my task"
  [ "$status" -eq 0 ]
  [[ $output == *"noVcs=true"* ]]
  run state_jq -r '.noVcs'
  [ "$output" = "true" ]
}

@test "init --minimal sets minimal=true" {
  run_driver init --minimal "my task"
  [ "$status" -eq 0 ]
  [[ $output == *"minimal=true"* ]]
  run state_jq -r '.minimal'
  [ "$output" = "true" ]
}

@test "init --from sets from field" {
  run_driver init --from=ci-only "my task"
  [ "$status" -eq 0 ]
  [[ $output == *"from=ci-only"* ]]
  run state_jq -r '.from'
  [ "$output" = "ci-only" ]
}

@test "init --from=followup carries base forward from the finished run" {
  # Regression (#87): entry points that skip sync never resolve base, so the
  # first commit failed with the raw jj guard. Init carries the finished run's
  # base forward. The git fixture declares the run VCS-backed so the carry
  # path is reached.
  mk_git_base
  run_driver init "first task"
  [ "$status" -eq 0 ]
  run_driver set base main
  [ "$status" -eq 0 ]
  run_driver start done
  run_driver end passed "verified"

  run_driver init --from=followup "follow-up task"
  [ "$status" -eq 0 ]
  run state_jq -r '.base'
  [ "$output" = "main" ]
  run state_jq -r '.from'
  [ "$output" = "followup" ]
}

@test "API init --from=followup carries base forward (typed tool path)" {
  # Regression (#87) on the exact consumer path from the report: the typed
  # agency_driver tool, not just the do-driver CLI bundle.
  mk_git_base
  AGENCY_DRIVER_ARGS='["init","first task"]' run_api_driver
  [ "$status" -eq 0 ]
  AGENCY_DRIVER_ARGS='["set","base","main"]' run_api_driver
  [ "$status" -eq 0 ]
  AGENCY_DRIVER_ARGS='["start","done"]' run_api_driver
  [ "$status" -eq 0 ]
  AGENCY_DRIVER_ARGS='["end","passed","verified"]' run_api_driver
  [ "$status" -eq 0 ]

  AGENCY_DRIVER_ARGS='["init","--from=followup","follow-up task"]' run_api_driver
  [ "$status" -eq 0 ]
  run state_jq -r '.base'
  [ "$output" = "main" ]
}

@test "init does not carry the no-vcs base sentinel into a vcs run" {
  # VCS-backed fixture so the sentinel guard, not the VCS gate, excludes.
  export VCS_OVERRIDE=jj
  run_driver init --no-vcs "first task"
  [ "$status" -eq 0 ]
  run_driver set base no-vcs
  [ "$status" -eq 0 ]
  run_driver start done
  run_driver end passed "verified"

  run_driver init --from=followup "vcs task"
  [ "$status" -eq 0 ]
  run state_jq -r 'has("base")'
  [ "$output" = "false" ]
}

@test "init on the default entry leaves base for sync to resolve" {
  # Regression (#87): carry is scoped to entries that skip sync. The default
  # entry runs sync, and a failed sync must fall back to the missing-base
  # diagnostics rather than a stale carried value. Both CLI spellings pinned.
  # Git fixture so the default-entry gate, not the VCS gate, excludes.
  mk_git_base
  run_driver init "first task"
  [ "$status" -eq 0 ]
  run_driver set base main
  [ "$status" -eq 0 ]
  run_driver start done
  run_driver end passed "verified"

  run_driver init "default entry"
  [ "$status" -eq 0 ]
  run state_jq -r 'has("base")'
  [ "$output" = "false" ]

  run_driver start done
  run_driver end passed "verified"
  run_driver init --from=default "explicit default entry"
  [ "$status" -eq 0 ]
  run state_jq -r 'has("base")'
  [ "$output" = "false" ]
}

@test "init --no-vcs leaves base unset even when the prior run had one" {
  # Git fixture so the --no-vcs gate, not the VCS gate, excludes.
  mk_git_base
  run_driver init "first task"
  [ "$status" -eq 0 ]
  run_driver set base main
  [ "$status" -eq 0 ]
  run_driver start done
  run_driver end passed "verified"

  run_driver init --no-vcs --from=followup "no-vcs follow-up"
  [ "$status" -eq 0 ]
  run state_jq -r 'has("base")'
  [ "$output" = "false" ]
}

@test "init --review incompatible with --from (non-default)" {
  run_driver init --review --from=followup "my task"
  [ "$status" -eq 2 ]
  [[ $output == *"incompatible with --from=followup"* ]]
}

@test "init --review compatible with --from=default" {
  run_driver init --review --from=default "my task"
  [ "$status" -eq 0 ]
}

@test "init unknown flag errors" {
  run_driver init --bogus "my task"
  [ "$status" -eq 2 ]
  [[ $output == *"unknown flag: --bogus"* ]]
}

@test "init --base is rejected (sync flag)" {
  run_driver init --base feat-x "my task"
  [ "$status" -eq 2 ]
  [[ $output == *"--base is a sync flag, not an init flag"* ]]
}

@test "init --stack is rejected (sync flag)" {
  run_driver init --stack "my task"
  [ "$status" -eq 2 ]
  [[ $output == *"--stack is a sync flag, not an init flag"* ]]
}

@test "init with no task: still works (task is optional)" {
  run_driver init
  [ "$status" -eq 0 ]
}

@test "start delegates to do-results step-start" {
  run_driver init "test"
  run_driver start research
  [ "$status" -eq 0 ]
  [ "$output" = "pending: research" ]
}

@test "end delegates to do-results step-end" {
  run_driver init "test"
  run_driver start research
  run_driver end passed "verified"
  [ "$status" -eq 0 ]
  [[ $output == *"recorded: research passed"* ]]
}

@test "end done terminalizes the workflow" {
  run_driver init "test"
  run_driver start done
  run_driver end passed "verified"
  [ "$status" -eq 0 ]
  run state_jq -e '.active == "idle" and .status == "completed"'
  [ "$status" -eq 0 ]
}

@test "end with reason passes it through" {
  run_driver init "test"
  run_driver start sync
  run_driver end skipped "" "--no-vcs"
  [ "$status" -eq 0 ]
  run state_jq -r '.steps[0].reason'
  [ "$output" = "--no-vcs" ]
}

@test "skip records a skipped step with reason" {
  run_driver init "test"
  run_driver skip docs "--minimal"
  [ "$status" -eq 0 ]

  run state_jq -r '.steps[0].status'
  [ "$output" = "skipped" ]
  run state_jq -r '.steps[0].reason'
  [ "$output" = "--minimal" ]
}

@test "skip on an active step is refused — use end skipped instead" {
  # Regression (#61): `skip` is the scheduler-level spelling (step not yet
  # started). A node that discovers mid-step it has nothing to do must close
  # with `end skipped <reason>`, not retry `skip`.
  run_driver init "test"
  run_driver start evidence
  before="$(driver_state)"

  run_driver skip evidence "no PR evidence section"
  [ "$status" -ne 0 ]
  [[ $output =~ "already active" ]]

  [ "$(driver_state)" = "$before" ]
}

@test "end skipped with reason closes an active step (node-local skip)" {
  # Regression (#61): the documented node-local skip completion.
  run_driver init "test"
  run_driver start evidence
  run_driver end skipped "" "no PR evidence section in .agency/do.md"
  [ "$status" -eq 0 ]

  run state_jq -r '.steps[0].status'
  [ "$output" = "skipped" ]
  run state_jq -r '.steps[0].reason'
  [ "$output" = "no PR evidence section in .agency/do.md" ]
  run state_jq -e '.pendingStep == null'
  [ "$status" -eq 0 ]
}

@test "end skipped without reason is refused" {
  # Regression (#61): the driver refuses a reasonless skipped completion.
  run_driver init "test"
  run_driver start evidence
  before="$(driver_state)"

  run_driver end skipped
  [ "$status" -ne 0 ]
  [[ $output =~ "reason required for skipped" ]]

  [ "$(driver_state)" = "$before" ]
}

@test "set delegates to do-results set" {
  run_driver init "test"
  run_driver set forge github
  [ "$status" -eq 0 ]
  [ "$output" = "set: forge=github" ]
}

@test "summary calls steps/done and produces a table" {
  run_driver init "test"
  run_driver start sync
  run_driver end passed "ok"
  run_driver summary
  [ "$status" -eq 0 ]
  [[ $output == *"| Step | Status | Duration | Verification |"* ]]
}

@test "no command: errors with usage" {
  run_driver
  [ "$status" -ne 0 ]
  [[ $output == *"Usage:"* ]]
}

@test "unknown command: errors with usage" {
  run_driver frobnicate
  [ "$status" -ne 0 ]
  [[ $output == *"Unknown command: frobnicate"* ]]
}

@test "state reports no snapshot before init and creates none" {
  run driver_state
  [ "$status" -ne 0 ]
  [[ $output == *"workflow state not found"* ]]
  [ ! -d "$AGENCY_STATE_DIR" ]
}

@test "migrate imports legacy JSON once without touching the source" {
  legacy='{"workflow":"do","startedAt":"2024-01-01T00:00:00Z","active":"working","status":"running","steps":[],"task":"legacy run"}'
  printf '%s' "$legacy" >.do-results.json

  run_driver migrate
  [ "$status" -eq 0 ]
  [[ $output == *"migrated workflow state"* ]]

  run state_jq -r '.task'
  [ "$output" = "legacy run" ]
  [ "$(cat .do-results.json)" = "$legacy" ]

  run_driver migrate
  [ "$status" -ne 0 ]
  [[ $output == *"already has a SQLite state snapshot"* ]]
}

@test "migrate refuses corrupt legacy JSON without creating a snapshot" {
  printf 'not json' >.do-results.json

  run_driver migrate
  [ "$status" -ne 0 ]
  [[ $output == *"cannot read legacy workflow state"* ]]

  run driver_state
  [ "$status" -ne 0 ]
  [[ $output == *"workflow state not found"* ]]
}

@test "migrate without legacy JSON names the missing source" {
  run_driver migrate
  [ "$status" -ne 0 ]
  [[ $output == *"no legacy workflow state"* ]]
}
