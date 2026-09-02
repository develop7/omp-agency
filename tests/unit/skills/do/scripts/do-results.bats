#!/usr/bin/env bats
# Unit tests for do-results — the .do-results.json state machine.
# Black-box: drives the script as a subprocess, asserts on stdout + the JSON file.

setup() {
  load "$REPO_ROOT/tests/helpers/setup.bash"
  setup_test_dir
  DO_RESULTS="$(repo_script skills/do/scripts/do-results)"
}

teardown() {
  teardown_test_dir
}

# Helper: run do-results and capture stdout + exit code
run_dr() {
  run node "$REPO_ROOT/pure/dist/agency-do.js" do-results "$@"
}

@test "init creates skeleton JSON with correct fields" {
  run_dr init
  [ "$status" -eq 0 ]
  [ -f ".do-results.json" ]

  run jq -r '.workflow' .do-results.json
  [ "$output" = "do" ]

  run jq -r '.active' .do-results.json
  [ "$output" = "working" ]

  run jq -r '.status' .do-results.json
  [ "$output" = "running" ]

  run jq '.steps | length' .do-results.json
  [ "$output" = "0" ]

  run jq -r '.startedAt | type' .do-results.json
  [ "$output" = "string" ]
}

@test "init echoes confirmation with startedAt timestamp" {
  run_dr init
  [ "$status" -eq 0 ]
  [[ "$output" =~ ^init:\ startedAt=[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z$ ]]
}

@test "step-start sets pendingStep" {
  run_dr init
  run_dr step-start research
  [ "$status" -eq 0 ]

  run jq -r '.pendingStep.name' .do-results.json
  [ "$output" = "research" ]
}

@test "step-start echoes pending confirmation" {
  run_dr init
  run_dr step-start research
  [ "$status" -eq 0 ]
  [ "$output" = "pending: research" ]
}

@test "step-start errors if pendingStep already active (no double-start)" {
  run_dr init
  run_dr step-start research
  run_dr step-start implement
  [ "$status" -ne 0 ]
  [[ "$output" =~ "pendingStep 'research' already active" ]]
}

@test "step-end appends to steps and clears pendingStep" {
  run_dr init
  run_dr step-start research
  run_dr step-end passed "verified via reading"
  [ "$status" -eq 0 ]

  run jq '.steps | length' .do-results.json
  [ "$output" = "1" ]

  run jq -r '.steps[0].name' .do-results.json
  [ "$output" = "research" ]

  run jq -r '.steps[0].status' .do-results.json
  [ "$output" = "passed" ]

  run jq -r '.steps[0].verification' .do-results.json
  [ "$output" = "verified via reading" ]

  run jq -r '.pendingStep' .do-results.json
  [ "$output" = "null" ]
}

@test "step-end echoes recorded confirmation with step count" {
  run_dr init
  run_dr step-start research
  run_dr step-end passed "ok"
  [ "$status" -eq 0 ]
  [[ "$output" =~ ^recorded:\ research\ passed\ \(steps=1,\ pending=none\)$ ]]
}

@test "step-end with reason includes it in the record" {
  run_dr init
  run_dr step-start sync
  run_dr step-end skipped "" "--no-vcs"
  [ "$status" -eq 0 ]

  run jq -r '.steps[0].reason' .do-results.json
  [ "$output" = "--no-vcs" ]
}

@test "step-end without reason omits the reason field" {
  run_dr init
  run_dr step-start research
  run_dr step-end passed "ok"
  [ "$status" -eq 0 ]

  run jq -r '.steps[0] | has("reason")' .do-results.json
  [ "$output" = "false" ]
}

@test "step-end errors if no pendingStep" {
  run_dr init
  run_dr step-end passed "ok"
  [ "$status" -ne 0 ]
  [[ "$output" =~ "no pendingStep" ]]
}

@test "step appends with explicit timestamps" {
  run_dr init
  run_dr step research passed "ok" "2024-01-01T00:00:00Z" "2024-01-01T00:01:00Z"
  [ "$status" -eq 0 ]

  run jq -r '.steps[0].startedAt' .do-results.json
  [ "$output" = "2024-01-01T00:00:00Z" ]

  run jq -r '.steps[0].completedAt' .do-results.json
  [ "$output" = "2024-01-01T00:01:00Z" ]
}

@test "step echoes recorded confirmation" {
  run_dr init
  run_dr step research passed "ok" "2024-01-01T00:00:00Z" "2024-01-01T00:01:00Z"
  [[ "$output" =~ ^recorded:\ research\ passed\ \(steps=1\)$ ]]
}

@test "step resolves 'now' sentinel to current UTC timestamp" {
  run_dr init
  run_dr step sync passed "ok" "now" "now"
  [ "$status" -eq 0 ]

  run jq -r '.steps[0].startedAt | type' .do-results.json
  [ "$output" = "string" ]

  # Should match ISO 8601 UTC format
  run jq -r '.steps[0].startedAt' .do-results.json
  [[ "$output" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z$ ]]
}

@test "set with string value" {
  run_dr init
  run_dr set task "my task"
  [ "$status" -eq 0 ]

  run jq -r '.task' .do-results.json
  [ "$output" = "my task" ]
}

@test "set with boolean true" {
  run_dr init
  run_dr set review true
  [ "$status" -eq 0 ]

  run jq -r '.review' .do-results.json
  [ "$output" = "true" ]
}

@test "set with boolean false" {
  run_dr init
  run_dr set noVcs false
  [ "$status" -eq 0 ]

  run jq -r '.noVcs' .do-results.json
  [ "$output" = "false" ]
}

@test "set echoes confirmation" {
  run_dr init
  run_dr set forge github
  [ "$status" -eq 0 ]
  [ "$output" = "set: forge=github" ]
}

@test "unknown command errors with usage" {
  run_dr frobnicate
  [ "$status" -ne 0 ]
  [[ "$output" =~ "Unknown command: frobnicate" ]]
}

@test "multiple step lifecycle produces ordered steps array" {
  run_dr init
  run_dr step-start sync
  run_dr step-end passed "ok"
  run_dr step-start research
  run_dr step-end passed "ok"
  run_dr step-start implement
  run_dr step-end passed "ok"

  run jq -r '.steps | length' .do-results.json
  [ "$output" = "3" ]

  run jq -r '.steps[0].name' .do-results.json
  [ "$output" = "sync" ]

  run jq -r '.steps[2].name' .do-results.json
  [ "$output" = "implement" ]
}
