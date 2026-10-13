#!/usr/bin/env bats
# Unit tests for do-driver — the thin state wrapper around do-results.
# Tests delegation: init flags, start/end/skip/set pass through, summary calls done.

setup() {
  load "$REPO_ROOT/tests/helpers/setup.bash"
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
      'const { runTool } = await import(process.env.AGENCY_API_BUNDLE); const result = await runTool({ tool: "agency_driver", args: JSON.parse(process.env.AGENCY_DRIVER_ARGS), captureOutput: true })(); process.stdout.write(JSON.stringify(result)); process.exitCode = result.exit'
}

@test "init creates .do-results.json with default flags" {
  run_driver init "my task"
  [ "$status" -eq 0 ]
  [[ "$output" == *"review=false"* ]]
  [[ "$output" == *"noVcs=false"* ]]
  [[ "$output" == *"minimal=false"* ]]
  [[ "$output" == *"from=default"* ]]

  [ -f ".do-results.json" ]
  run jq -r '.task' .do-results.json
  [ "$output" = "my task" ]
}

@test "init refuses corrupt state without replacing it" {
  printf 'not json' > .do-results.json
  cp .do-results.json corrupt-before.json

  run_driver init "recovered task"

  [ "$status" -eq 1 ]
  cmp .do-results.json corrupt-before.json
}

@test "init --restart replaces corrupt state with clean initialization" {
  printf 'not json' > .do-results.json

  run_driver init --restart "recovered task"

  [ "$status" -eq 0 ]
  run jq -e '.task == "recovered task" and .active == "working" and .status == "running" and .steps == []' .do-results.json
  [ "$status" -eq 0 ]
}

@test "API init --restart replaces corrupt state but summary remains strict" {
  printf 'not json' > .do-results.json

  AGENCY_DRIVER_ARGS='["init","--restart","recovered task"]' run_api_driver
  [ "$status" -eq 0 ]
  run jq -e '.task == "recovered task" and .active == "working" and .status == "running" and .steps == []' .do-results.json
  [ "$status" -eq 0 ]

  printf 'not json' > .do-results.json
  cp .do-results.json corrupt-before.json
  AGENCY_DRIVER_ARGS='["summary"]' run_api_driver
  [ "$status" -eq 1 ]
  cmp .do-results.json corrupt-before.json
}

@test "init --review sets review=true" {
  run_driver init --review "my task"
  [ "$status" -eq 0 ]
  [[ "$output" == *"review=true"* ]]
  run jq -r '.review' .do-results.json
  [ "$output" = "true" ]
}

@test "init --no-vcs sets noVcs=true" {
  run_driver init --no-vcs "my task"
  [ "$status" -eq 0 ]
  [[ "$output" == *"noVcs=true"* ]]
  run jq -r '.noVcs' .do-results.json
  [ "$output" = "true" ]
}

@test "init --minimal sets minimal=true" {
  run_driver init --minimal "my task"
  [ "$status" -eq 0 ]
  [[ "$output" == *"minimal=true"* ]]
  run jq -r '.minimal' .do-results.json
  [ "$output" = "true" ]
}

@test "init --from sets from field" {
  run_driver init --from=ci-only "my task"
  [ "$status" -eq 0 ]
  [[ "$output" == *"from=ci-only"* ]]
  run jq -r '.from' .do-results.json
  [ "$output" = "ci-only" ]
}

@test "init --from=followup carries base forward from the finished run" {
  # Regression (#87): entry points that skip sync never resolve base, so the
  # first commit failed with the raw jj guard. Init carries the finished run's
  # base forward.
  run_driver init "first task"
  [ "$status" -eq 0 ]
  run_driver set base main
  [ "$status" -eq 0 ]
  run_driver start done
  run_driver end passed "verified"

  run_driver init --from=followup "follow-up task"
  [ "$status" -eq 0 ]
  run jq -r '.base' .do-results.json
  [ "$output" = "main" ]
  run jq -r '.from' .do-results.json
  [ "$output" = "followup" ]
}

@test "API init --from=followup carries base forward (typed tool path)" {
  # Regression (#87) on the exact consumer path from the report: the typed
  # agency_driver tool, not just the do-driver CLI bundle.
  AGENCY_DRIVER_ARGS='["init","first task"]' run_api_driver
  [ "$status" -eq 0 ]
  AGENCY_DRIVER_ARGS='["set","base","main"]' run_api_driver
  [ "$status" -eq 0 ]
  AGENCY_DRIVER_ARGS='["start","done"]' run_api_driver
  AGENCY_DRIVER_ARGS='["end","passed","verified"]' run_api_driver

  AGENCY_DRIVER_ARGS='["init","--from=followup","follow-up task"]' run_api_driver
  [ "$status" -eq 0 ]
  run jq -r '.base' .do-results.json
  [ "$output" = "main" ]
}

@test "init does not carry the no-vcs base sentinel into a vcs run" {
  run_driver init --no-vcs "first task"
  [ "$status" -eq 0 ]
  run_driver set base no-vcs
  [ "$status" -eq 0 ]
  run_driver start done
  run_driver end passed "verified"

  run_driver init --from=followup "vcs task"
  [ "$status" -eq 0 ]
  run jq -r 'has("base")' .do-results.json
  [ "$output" = "false" ]
}

@test "init on the default entry leaves base for sync to resolve" {
  # Regression (#87): carry is scoped to entries that skip sync. The default
  # entry runs sync, and a failed sync must fall back to the missing-base
  # diagnostics rather than a stale carried value. Both CLI spellings pinned.
  run_driver init "first task"
  [ "$status" -eq 0 ]
  run_driver set base main
  [ "$status" -eq 0 ]
  run_driver start done
  run_driver end passed "verified"

  run_driver init "default entry"
  [ "$status" -eq 0 ]
  run jq -r 'has("base")' .do-results.json
  [ "$output" = "false" ]

  run_driver start done
  run_driver end passed "verified"
  run_driver init --from=default "explicit default entry"
  [ "$status" -eq 0 ]
  run jq -r 'has("base")' .do-results.json
  [ "$output" = "false" ]
}

@test "init --no-vcs leaves base unset even when the prior run had one" {
  run_driver init "first task"
  [ "$status" -eq 0 ]
  run_driver set base main
  [ "$status" -eq 0 ]
  run_driver start done
  run_driver end passed "verified"

  run_driver init --no-vcs --from=followup "no-vcs follow-up"
  [ "$status" -eq 0 ]
  run jq -r 'has("base")' .do-results.json
  [ "$output" = "false" ]
}

@test "init --review incompatible with --from (non-default)" {
  run_driver init --review --from=followup "my task"
  [ "$status" -eq 2 ]
  [[ "$output" == *"incompatible with --from=followup"* ]]
}

@test "init --review compatible with --from=default" {
  run_driver init --review --from=default "my task"
  [ "$status" -eq 0 ]
}

@test "init unknown flag errors" {
  run_driver init --bogus "my task"
  [ "$status" -eq 2 ]
  [[ "$output" == *"unknown flag: --bogus"* ]]
}

@test "init --base is rejected (sync flag)" {
  run_driver init --base feat-x "my task"
  [ "$status" -eq 2 ]
  [[ "$output" == *"--base is a sync flag, not an init flag"* ]]
}

@test "init --stack is rejected (sync flag)" {
  run_driver init --stack "my task"
  [ "$status" -eq 2 ]
  [[ "$output" == *"--stack is a sync flag, not an init flag"* ]]
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
  [[ "$output" == *"recorded: research passed"* ]]
}

@test "end done terminalizes the workflow" {
  run_driver init "test"
  run_driver start done
  run_driver end passed "verified"
  [ "$status" -eq 0 ]
  run jq -e '.active == "idle" and .status == "completed"' .do-results.json
  [ "$status" -eq 0 ]
}

@test "end with reason passes it through" {
  run_driver init "test"
  run_driver start sync
  run_driver end skipped "" "--no-vcs"
  [ "$status" -eq 0 ]
  run jq -r '.steps[0].reason' .do-results.json
  [ "$output" = "--no-vcs" ]
}

@test "skip records a skipped step with reason" {
  run_driver init "test"
  run_driver skip docs "--minimal"
  [ "$status" -eq 0 ]

  run jq -r '.steps[0].status' .do-results.json
  [ "$output" = "skipped" ]
  run jq -r '.steps[0].reason' .do-results.json
  [ "$output" = "--minimal" ]
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
  [[ "$output" == *"| Step | Status | Duration | Verification |"* ]]
}

@test "no command: errors with usage" {
  run_driver
  [ "$status" -ne 0 ]
  [[ "$output" == *"Usage:"* ]]
}

@test "unknown command: errors with usage" {
  run_driver frobnicate
  [ "$status" -ne 0 ]
  [[ "$output" == *"Unknown command: frobnicate"* ]]
}
