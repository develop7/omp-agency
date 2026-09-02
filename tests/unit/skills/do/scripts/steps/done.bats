#!/usr/bin/env bats
# Unit tests for steps/done — the timing summary emitter.
# Black-box: seeds .do-results.json with fixed timestamps, asserts on stdout output.

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

@test "missing .do-results.json: errors" {
  rm -f .do-results.json
  run_done
  [ "$status" -ne 0 ]
  [[ "$output" =~ "cannot produce summary" ]]
}

@test "empty steps: table with Total 0s, no slowest step" {
  cat > .do-results.json <<'EOF'
{
  "workflow": "do",
  "startedAt": "2024-01-01T00:00:00Z",
  "active": "completed",
  "status": "completed",
  "steps": []
}
EOF
  run_done
  [ "$status" -eq 0 ]
  [[ "$output" == *"| Step | Status | Duration | Verification |"* ]]
  [[ "$output" == *"| **Total** | | **0s** | |"* ]]
  [[ "$output" != *"Slowest step"* ]]
}

@test "single passed step: correct table row" {
  cat > .do-results.json <<'EOF'
{
  "workflow": "do",
  "startedAt": "2024-01-01T00:00:00Z",
  "active": "completed",
  "status": "completed",
  "steps": [
    {"name":"sync","status":"passed","verification":"ok","startedAt":"2024-01-01T00:00:00Z","completedAt":"2024-01-01T00:00:30Z"}
  ]
}
EOF
  run_done
  [ "$status" -eq 0 ]
  [[ "$output" == *"sync | ✓ | **30s** | ok"* ]]
  [[ "$output" == *"**Total** | | **30s**"* ]]
  [[ "$output" == *"**Slowest step**: \`sync\` (30s)"* ]]
}

@test "skipped step: dash icon, not counted in slowest" {
  cat > .do-results.json <<'EOF'
{
  "workflow": "do",
  "startedAt": "2024-01-01T00:00:00Z",
  "active": "completed",
  "status": "completed",
  "steps": [
    {"name":"docs","status":"skipped","verification":"","startedAt":"2024-01-01T00:00:00Z","completedAt":"2024-01-01T00:00:00Z","reason":"--minimal"}
  ]
}
EOF
  run_done
  [ "$status" -eq 0 ]
  [[ "$output" == *"| docs | — | 0s |"* ]]
}

@test "failed step: X icon, listed in failedSteps" {
  cat > .do-results.json <<'EOF'
{
  "workflow": "do",
  "startedAt": "2024-01-01T00:00:00Z",
  "active": "completed",
  "status": "failed",
  "steps": [
    {"name":"ci","status":"failed","verification":"exit 1","startedAt":"2024-01-01T00:00:00Z","completedAt":"2024-01-01T00:00:10Z"}
  ]
}
EOF
  run_done
  [ "$status" -eq 0 ]
  [[ "$output" == *"ci | ✗ | **10s**"* ]]
  [[ "$output" == *"failedSteps=ci"* ]]
}

@test "dominant step (>=30% of total): bolded duration" {
  cat > .do-results.json <<'EOF'
{
  "workflow": "do",
  "startedAt": "2024-01-01T00:00:00Z",
  "active": "completed",
  "status": "completed",
  "steps": [
    {"name":"sync","status":"passed","verification":"ok","startedAt":"2024-01-01T00:00:00Z","completedAt":"2024-01-01T00:00:10Z"},
    {"name":"ci","status":"passed","verification":"ok","startedAt":"2024-01-01T00:00:10Z","completedAt":"2024-01-01T00:01:10Z"}
  ]
}
EOF
  run_done
  [ "$status" -eq 0 ]
  # CI took 60s out of 70s total → dominant, bolded. fmt_dur converts 60s → "1m 0s"
  [[ "$output" == *"**1m 0s**"* ]]
  [[ "$output" == *"dominantSteps=ci"* ]]
  [[ "$output" == *"slowestStep=ci"* ]]
}

@test "FACTS block present with all fields" {
  cat > .do-results.json <<'EOF'
{
  "workflow": "do",
  "startedAt": "2024-01-01T00:00:00Z",
  "active": "completed",
  "status": "completed",
  "steps": [
    {"name":"sync","status":"passed","verification":"ok","startedAt":"2024-01-01T00:00:00Z","completedAt":"2024-01-01T00:00:30Z"}
  ]
}
EOF
  run_done
  [ "$status" -eq 0 ]
  [[ "$output" == *"<<<FACTS"* ]]
  [[ "$output" == *"totalSeconds=30"* ]]
  [[ "$output" == *"slowestStep=sync"* ]]
  [[ "$output" == *"slowestSeconds=30"* ]]
  [[ "$output" == *"dominantSteps=sync"* ]]
  [[ "$output" == *"skippedSteps="* ]]
  [[ "$output" == *"failedSteps="* ]]
  [[ "$output" == *"FACTS"* ]]
}

@test "duration formatting: minutes and seconds" {
  cat > .do-results.json <<'EOF'
{
  "workflow": "do",
  "startedAt": "2024-01-01T00:00:00Z",
  "active": "completed",
  "status": "completed",
  "steps": [
    {"name":"ci","status":"passed","verification":"ok","startedAt":"2024-01-01T00:00:00Z","completedAt":"2024-01-01T00:02:30Z"}
  ]
}
EOF
  run_done
  [ "$status" -eq 0 ]
  [[ "$output" == *"2m 30s"* ]]
}

@test "multiple steps: correct ordering in table" {
  cat > .do-results.json <<'EOF'
{
  "workflow": "do",
  "startedAt": "2024-01-01T00:00:00Z",
  "active": "completed",
  "status": "completed",
  "steps": [
    {"name":"sync","status":"passed","verification":"ok","startedAt":"2024-01-01T00:00:00Z","completedAt":"2024-01-01T00:00:05Z"},
    {"name":"research","status":"passed","verification":"ok","startedAt":"2024-01-01T00:00:05Z","completedAt":"2024-01-01T00:00:20Z"},
    {"name":"implement","status":"passed","verification":"ok","startedAt":"2024-01-01T00:00:20Z","completedAt":"2024-01-01T00:00:50Z"}
  ]
}
EOF
  run_done
  [ "$status" -eq 0 ]
  # Total should be 50s (00:00:00 → 00:00:50)
  [[ "$output" == *"**50s**"* ]]
  [[ "$output" == *"slowestStep=implement"* ]]
  [[ "$output" == *"slowestSeconds=30"* ]]
}
