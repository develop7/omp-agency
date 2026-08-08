#!/usr/bin/env bats
# Unit tests for do-driver — the thin state wrapper around do-results.
# Tests delegation: init flags, start/end/skip/set pass through, summary calls done.

setup() {
  load "$REPO_ROOT/tests/helpers/setup.bash"
  setup_test_dir
  DO_DRIVER="$(repo_script skills/do/scripts/do-driver)"
}

teardown() {
  teardown_test_dir
}

run_driver() {
  run bash "$DO_DRIVER" "$@"
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
