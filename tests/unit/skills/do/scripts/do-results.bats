#!/usr/bin/env bats
# Unit tests for do-results — the workflow state-machine primitives.
# Black-box: drives the script as a subprocess, asserts on stdout plus the
# canonical state returned by `do-driver state`.

setup() {
  load "$REPO_ROOT/tests/helpers/setup.bash"
  setup_test_dir
}

teardown() {
  teardown_test_dir
}

# Helper: run do-results and capture stdout + exit code
run_dr() {
  run node "$REPO_ROOT/pure/dist/agency-do.js" do-results "$@"
}

@test "init creates a snapshot with correct fields" {
  run_dr init
  [ "$status" -eq 0 ]

  run state_jq -r '.workflow'
  [ "$output" = "do" ]

  run state_jq -r '.active'
  [ "$output" = "working" ]

  run state_jq -r '.status'
  [ "$output" = "running" ]

  run state_jq '.steps | length'
  [ "$output" = "0" ]

  run state_jq -r '.startedAt | type'
  [ "$output" = "string" ]
}

@test "init echoes confirmation with startedAt timestamp" {
  run_dr init
  [ "$status" -eq 0 ]
  [[ $output =~ ^init:\ startedAt=[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z$ ]]
}

# Helper: run do-driver — the command that creates live jobs, used here to
# build the ledger fixture the legacy init guard must refuse to destroy.
run_dd() {
  run node "$REPO_ROOT/pure/dist/agency-do.js" do-driver "$@"
}

@test "init refuses to reset the state while a job is unfinished" {
  run_dr init
  [ "$status" -eq 0 ]
  run_dd job-start j1 "Pass 1" police
  [ "$status" -eq 0 ]
  before="$(driver_state)"

  run_dr init
  [ "$status" -ne 0 ]
  [[ $output == *"unfinished job(s) block init"* ]]
  [[ $output == *"'j1'"* ]]
  [ "$(driver_state)" = "$before" ]
}

@test "step-start sets pendingStep" {
  run_dr init
  run_dr step-start research
  [ "$status" -eq 0 ]

  run state_jq -r '.pendingStep.name'
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
  [[ $output =~ "pendingStep 'research' already active" ]]
}

@test "step-end appends to steps and clears pendingStep" {
  run_dr init
  run_dr step-start research
  run_dr step-end passed "verified via reading"
  [ "$status" -eq 0 ]

  run state_jq '.steps | length'
  [ "$output" = "1" ]

  run state_jq -r '.steps[0].name'
  [ "$output" = "research" ]

  run state_jq -r '.steps[0].status'
  [ "$output" = "passed" ]

  run state_jq -r '.steps[0].verification'
  [ "$output" = "verified via reading" ]

  run state_jq -r '.pendingStep'
  [ "$output" = "null" ]
}

@test "step-end echoes recorded confirmation with step count" {
  run_dr init
  run_dr step-start research
  run_dr step-end passed "ok"
  [ "$status" -eq 0 ]
  [[ $output =~ ^recorded:\ research\ passed\ \(steps=1,\ pending=none\)$ ]]
}

@test "step-end with reason includes it in the record" {
  run_dr init
  run_dr step-start sync
  run_dr step-end skipped "" "--no-vcs"
  [ "$status" -eq 0 ]

  run state_jq -r '.steps[0].reason'
  [ "$output" = "--no-vcs" ]
}

@test "step-end skipped without reason is refused and does not mutate" {
  # Regression (#61): a skipped completion must carry a reason so the
  # summary's skippedSteps line never reports "unspecified".
  run_dr init
  run_dr step-start evidence
  before="$(driver_state)"

  run_dr step-end skipped ""
  [ "$status" -ne 0 ]
  [[ $output =~ "reason required for skipped" ]]

  [ "$(driver_state)" = "$before" ]
  run state_jq -e '.pendingStep.name == "evidence"'
  [ "$status" -eq 0 ]
}

@test "step-end skipped with reason records the skipped step" {
  # Regression (#61): the node-local skip completion — start, then end
  # skipped with a reason — is the documented transition for a step that
  # discovers it has nothing to do.
  run_dr init
  run_dr step-start evidence
  run_dr step-end skipped "" "no PR evidence section in .agency/do.md"
  [ "$status" -eq 0 ]

  run state_jq -r '.steps[0].status'
  [ "$output" = "skipped" ]
  run state_jq -r '.steps[0].reason'
  [ "$output" = "no PR evidence section in .agency/do.md" ]
  run state_jq -e '.pendingStep == null'
  [ "$status" -eq 0 ]
}

@test "step-end without reason omits the reason field" {
  run_dr init
  run_dr step-start research
  run_dr step-end passed "ok"
  [ "$status" -eq 0 ]

  run state_jq -r '.steps[0] | has("reason")'
  [ "$output" = "false" ]
}

@test "step-end errors if no pendingStep" {
  run_dr init
  run_dr step-end passed "ok"
  [ "$status" -ne 0 ]
  [[ $output =~ "no pendingStep" ]]
}

@test "step appends with explicit timestamps" {
  run_dr init
  run_dr step research passed "ok" "2024-01-01T00:00:00Z" "2024-01-01T00:01:00Z"
  [ "$status" -eq 0 ]

  run state_jq -r '.steps[0].startedAt'
  [ "$output" = "2024-01-01T00:00:00Z" ]

  run state_jq -r '.steps[0].completedAt'
  [ "$output" = "2024-01-01T00:01:00Z" ]
}

@test "step echoes recorded confirmation" {
  run_dr init
  run_dr step research passed "ok" "2024-01-01T00:00:00Z" "2024-01-01T00:01:00Z"
  [[ $output =~ ^recorded:\ research\ passed\ \(steps=1\)$ ]]
}

@test "step resolves 'now' sentinel to current UTC timestamp" {
  run_dr init
  run_dr step sync passed "ok" "now" "now"
  [ "$status" -eq 0 ]

  run state_jq -r '.steps[0].startedAt | type'
  [ "$output" = "string" ]

  # Should match ISO 8601 UTC format
  run state_jq -r '.steps[0].startedAt'
  [[ $output =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z$ ]]
}

@test "set with string value" {
  run_dr init
  run_dr set task "my task"
  [ "$status" -eq 0 ]

  run state_jq -r '.task'
  [ "$output" = "my task" ]
}

@test "set with boolean true" {
  run_dr init
  run_dr set review true
  [ "$status" -eq 0 ]

  run state_jq -r '.review'
  [ "$output" = "true" ]
}

@test "set with boolean false" {
  run_dr init
  run_dr set noVcs false
  [ "$status" -eq 0 ]

  run state_jq -r '.noVcs'
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
  [[ $output =~ "Unknown command: frobnicate" ]]
}

@test "multiple step lifecycle produces ordered steps array" {
  run_dr init
  run_dr step-start sync
  run_dr step-end passed "ok"
  run_dr step-start research
  run_dr step-end passed "ok"
  run_dr step-start implement
  run_dr step-end passed "ok"

  run state_jq -r '.steps | length'
  [ "$output" = "3" ]

  run state_jq -r '.steps[0].name'
  [ "$output" = "sync" ]

  run state_jq -r '.steps[2].name'
  [ "$output" = "implement" ]
}
