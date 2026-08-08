#!/usr/bin/env bats
# Integration tests for steps/sync — the /do sync step.
# Uses a real git repo with a local bare remote as a fixture.

setup() {
  load "$REPO_ROOT/tests/helpers/setup.bash"
  setup_test_dir

  SYNC="$(repo_script skills/do/scripts/steps/sync)"

  # Create a git fixture with a working local remote
  git init -q
  git config user.email "test@test.com"
  git config user.name "Test"

  # Create initial commit + set up remote
  echo "hello" > file.txt
  git add file.txt
  git commit -q -m "initial"
  git init -q --bare "$TEST_DIR/remote.git"
  git remote add origin "$TEST_DIR/remote.git"
  git push -q origin master 2>/dev/null
  git remote set-head origin -a 2>/dev/null
}

teardown() {
  teardown_test_dir
}

run_sync() {
  run bash "$SYNC" "$@"
}

@test "sync with noVcs=true: emits correct protocol lines" {
  run_sync true
  [ "$status" -eq 0 ]

  [[ "$output" == *"vcs=git"* ]]
  [[ "$output" == *"forge=unknown"* ]]
  [[ "$output" == *"branch=master"* ]]
  [[ "$output" == *"defaultBranch=master"* ]]
}

@test "sync with noVcs=false: emits correct protocol lines" {
  run_sync false
  [ "$status" -eq 0 ]

  [[ "$output" == *"vcs=git"* ]]
  [[ "$output" == *"forge=unknown"* ]]
}

@test "sync creates .do-results.json with vcs field" {
  run_sync true
  [ "$status" -eq 0 ]

  [ -f ".do-results.json" ]
  run jq -r '.vcs' .do-results.json
  [ "$output" = "git" ]
}

@test "sync creates .do-results.json with forge field" {
  run_sync true
  [ "$status" -eq 0 ]

  run jq -r '.forge' .do-results.json
  [ "$output" = "unknown" ]
}

@test "sync creates .do-results.json with noVcs field" {
  run_sync true
  [ "$status" -eq 0 ]

  run jq -r '.noVcs' .do-results.json
  [ "$output" = "true" ]
}

@test "sync records a sync step in .do-results.json" {
  run_sync true
  [ "$status" -eq 0 ]

  run jq -r '.steps[0].name' .do-results.json
  [ "$output" = "sync" ]

  run jq -r '.steps[0].status' .do-results.json
  [ "$output" = "passed" ]
}

@test "sync errors on invalid noVcs value" {
  run_sync maybe
  [ "$status" -eq 2 ]
  [[ "$output" == *"noVcs must be 'true' or 'false'"* ]]
}

@test "sync detects github forge from remote URL" {
  # Use a local bare repo whose path contains "github.com" so fetch works
  # AND forge detection matches the github pattern.
  git init -q --bare "$TEST_DIR/github.com-fake.git"
  git push -q "$TEST_DIR/github.com-fake.git" master 2>/dev/null
  git remote set-url origin "$TEST_DIR/github.com-fake.git"

  run_sync true
  [ "$status" -eq 0 ]
  [[ "$output" == *"forge=github"* ]]
}

@test "sync --base <branch> resolves base to that branch" {
  run_sync --base feat-parent false
  [ "$status" -eq 0 ]
  [[ "$output" == *"base=feat-parent"* ]]
  run jq -r '.base' .do-results.json
  [ "$output" = "feat-parent" ]
}

@test "sync --stack --base are mutually exclusive" {
  run_sync --base foo --stack true
  [ "$status" -eq 2 ]
  [[ "$output" == *"mutually exclusive"* ]]
}

@test "sync --base is incompatible with --no-vcs" {
  # --no-vcs means noVcs=true; base selection is meaningless without VCS.
  run_sync --base foo true
  [ "$status" -eq 2 ]
  [[ "$output" == *"incompatible with --no-vcs"* ]]
}
