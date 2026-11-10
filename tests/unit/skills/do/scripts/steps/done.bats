#!/usr/bin/env bats
# Unit tests for steps/done — the timing summary emitter.
# Black-box: seeds a run with fixed timestamps through do-driver, asserts on
# stdout output.

setup() {
  load "$REPO_ROOT/tests/helpers/setup.bash"
  setup_test_dir
}

teardown() {
  teardown_test_dir
}

run_done() {
  run node "$REPO_ROOT/pure/dist/agency-do.js" done
}

# Seed one fixed-timestamp run: `seed "$startedAt" "$status" <<'EOF' [steps] EOF`.
seed_run() {
  seed_done_state "$1" "$2" "$(cat)"
}

@test "missing workflow state: errors" {
  run_done
  [ "$status" -ne 0 ]
  [[ $output == *"workflow state not found"* ]]
}

@test "empty steps: table with Total 0s, no slowest step" {
  seed_run "2024-01-01T00:00:00Z" completed <<'EOF'
[]
EOF
  run_done
  [ "$status" -eq 0 ]
  [[ $output == *"| Step | Status | Duration | Verification |"* ]]
  [[ $output == *"| **Total** | | **0s** | |"* ]]
  [[ $output != *"Slowest step"* ]]
}

@test "single passed step: correct table row" {
  seed_run "2024-01-01T00:00:00Z" completed <<'EOF'
[{"name":"sync","status":"passed","verification":"ok","startedAt":"2024-01-01T00:00:00Z","completedAt":"2024-01-01T00:00:30Z"}]
EOF
  run_done
  [ "$status" -eq 0 ]
  [[ $output == *"sync | ✓ | **30s** | ok"* ]]
  [[ $output == *"**Total** | | **30s**"* ]]
  [[ $output == *"**Slowest step**: \`sync\` (30s)"* ]]
}

@test "skipped step: dash icon, not counted in slowest" {
  seed_run "2024-01-01T00:00:00Z" completed <<'EOF'
[{"name":"docs","status":"skipped","verification":"","startedAt":"2024-01-01T00:00:00Z","completedAt":"2024-01-01T00:00:00Z","reason":"--minimal"}]
EOF
  run_done
  [ "$status" -eq 0 ]
  [[ $output == *"| docs | — | 0s |"* ]]
}

@test "failed step: X icon, listed in failedSteps" {
  seed_run "2024-01-01T00:00:00Z" failed <<'EOF'
[{"name":"ci","status":"failed","verification":"exit 1","startedAt":"2024-01-01T00:00:00Z","completedAt":"2024-01-01T00:00:10Z"}]
EOF
  run_done
  [ "$status" -eq 0 ]
  [[ $output == *"ci | ✗ | **10s**"* ]]
  [[ $output == *"failedSteps=ci"* ]]
}

@test "dominant step (>=30% of total): bolded duration" {
  seed_run "2024-01-01T00:00:00Z" completed <<'EOF'
[{"name":"sync","status":"passed","verification":"ok","startedAt":"2024-01-01T00:00:00Z","completedAt":"2024-01-01T00:00:10Z"},
 {"name":"ci","status":"passed","verification":"ok","startedAt":"2024-01-01T00:00:10Z","completedAt":"2024-01-01T00:01:10Z"}]
EOF
  run_done
  [ "$status" -eq 0 ]
  # CI took 60s out of 70s total → dominant, bolded. fmt_dur converts 60s → "1m 0s"
  [[ $output == *"**1m 0s**"* ]]
  [[ $output == *"dominantSteps=ci"* ]]
  [[ $output == *"slowestStep=ci"* ]]
}

@test "FACTS block present with all fields" {
  seed_run "2024-01-01T00:00:00Z" completed <<'EOF'
[{"name":"sync","status":"passed","verification":"ok","startedAt":"2024-01-01T00:00:00Z","completedAt":"2024-01-01T00:00:30Z"}]
EOF
  run_done
  [ "$status" -eq 0 ]
  [[ $output == *"<<<FACTS"* ]]
  [[ $output == *"totalSeconds=30"* ]]
  [[ $output == *"slowestStep=sync"* ]]
  [[ $output == *"slowestSeconds=30"* ]]
  [[ $output == *"dominantSteps=sync"* ]]
  [[ $output == *"skippedSteps="* ]]
  [[ $output == *"failedSteps="* ]]
  [[ $output == *"FACTS"* ]]
}

@test "duration formatting: minutes and seconds" {
  seed_run "2024-01-01T00:00:00Z" completed <<'EOF'
[{"name":"ci","status":"passed","verification":"ok","startedAt":"2024-01-01T00:00:00Z","completedAt":"2024-01-01T00:02:30Z"}]
EOF
  run_done
  [ "$status" -eq 0 ]
  [[ $output == *"2m 30s"* ]]
}

@test "multiple steps: correct ordering in table" {
  seed_run "2024-01-01T00:00:00Z" completed <<'EOF'
[{"name":"sync","status":"passed","verification":"ok","startedAt":"2024-01-01T00:00:00Z","completedAt":"2024-01-01T00:00:05Z"},
 {"name":"research","status":"passed","verification":"ok","startedAt":"2024-01-01T00:00:05Z","completedAt":"2024-01-01T00:00:20Z"},
 {"name":"implement","status":"passed","verification":"ok","startedAt":"2024-01-01T00:00:20Z","completedAt":"2024-01-01T00:00:50Z"}]
EOF
  run_done
  [ "$status" -eq 0 ]
  # Total should be 50s (00:00:00 → 00:00:50)
  [[ $output == *"**50s**"* ]]
  [[ $output == *"slowestStep=implement"* ]]
  [[ $output == *"slowestSeconds=30"* ]]
}

@test "unfinished job blocks the summary" {
  node "$REPO_ROOT/pure/dist/agency-do.js" do-driver init "job fixture" >/dev/null
  node "$REPO_ROOT/pure/dist/agency-do.js" do-driver job-start j1 "Pass 1" police >/dev/null

  run_done
  [ "$status" -ne 0 ]
  [[ $output == *"unfinished job(s): 'j1'"* ]]
}
