#!/usr/bin/env bats
# Integration tests for forge-op — the forge operation dispatcher.
# Uses a real git fixture repo (so vcs-op remote-url works for the
# detect_forge fallback) with a github.com origin URL.

setup() {
  load "$REPO_ROOT/tests/helpers/setup.bash"
  load "$REPO_ROOT/tests/helpers/git-fixtures.bash"
  setup_test_dir

  FORGE_OP="$(repo_script skills/do/scripts/forge-op)"

  # Real git fixture so vcs-op remote-url returns something forge-op can
  # classify when state is absent (the fallback path).
  git init -q
  git config user.email "test@test.com"
  git config user.name "Test"
  git remote add origin https://github.com/example/repo.git
}

teardown() {
  teardown_test_dir
}

# ─── detect ───────────────────────────────────────────────────────────

@test "detect returns github from origin URL when state is absent" {
  run node "$REPO_ROOT/pure/dist/agency-do.js" forge-op detect
  [ "$status" -eq 0 ]
  [ "$output" = "github" ]
}

@test "detect honors FORGE_OVERRIDE" {
  FORGE_OVERRIDE=bitbucket run node "$REPO_ROOT/pure/dist/agency-do.js" forge-op detect
  [ "$status" -eq 0 ]
  [ "$output" = "bitbucket" ]
}

@test "detect reads forge from .do-results.json when present" {
  mkdir -p .do-results.json.d 2>/dev/null || true
  printf '{"forge":"bitbucket"}' > .do-results.json
  run node "$REPO_ROOT/pure/dist/agency-do.js" forge-op detect
  [ "$status" -eq 0 ]
  [ "$output" = "bitbucket" ]
}

@test "detect classifies bitbucket origin URL" {
  git remote set-url origin https://bitbucket.org/example/repo.git
  run node "$REPO_ROOT/pure/dist/agency-do.js" forge-op detect
  [ "$status" -eq 0 ]
  [ "$output" = "bitbucket" ]
}

@test "detect classifies unknown origin URL" {
  git remote set-url origin https://gitlab.com/example/repo.git
  run node "$REPO_ROOT/pure/dist/agency-do.js" forge-op detect
  [ "$status" -eq 0 ]
  [ "$output" = "unknown" ]
}

# ─── supports ─────────────────────────────────────────────────────────

@test "supports returns 0 for all ops on github" {
  for op in pr-view pr-create pr-edit pr-comment issue-view pr-checks; do
    FORGE_OVERRIDE=github run node "$REPO_ROOT/pure/dist/agency-do.js" forge-op supports "$op"
    [ "$status" -eq 0 ] || { echo "expected $op supported on github"; false; }
  done
}

@test "supports returns 1 for all ops on bitbucket" {
  for op in pr-view pr-create pr-edit pr-comment issue-view pr-checks; do
    FORGE_OVERRIDE=bitbucket run node "$REPO_ROOT/pure/dist/agency-do.js" forge-op supports "$op"
    [ "$status" -eq 1 ] || { echo "expected $op unsupported on bitbucket"; false; }
  done
}

@test "supports returns 1 for all ops on unknown" {
  FORGE_OVERRIDE=unknown run node "$REPO_ROOT/pure/dist/agency-do.js" forge-op supports pr-create
  [ "$status" -eq 1 ]
}

@test "supports errors on unknown op name" {
  FORGE_OVERRIDE=github run node "$REPO_ROOT/pure/dist/agency-do.js" forge-op supports nonsense-op
  [ "$status" -eq 1 ]
}

# ─── dispatch ─────────────────────────────────────────────────────────

@test "dispatch errors on unsupported forge" {
  FORGE_OVERRIDE=bitbucket run node "$REPO_ROOT/pure/dist/agency-do.js" forge-op pr-create --help
  [ "$status" -eq 1 ]
  [[ "$output" == *"does not support"* ]]
  [[ "$output" == *"#10"* ]]
}

@test "unknown operation errors" {
  run node "$REPO_ROOT/pure/dist/agency-do.js" forge-op nonsense-op
  [ "$status" -eq 1 ]
  [[ "$output" == *"unknown operation"* ]]
}

@test "no operation errors with usage" {
  run node "$REPO_ROOT/pure/dist/agency-do.js" forge-op
  [ "$status" -eq 1 ]
  [[ "$output" == *"Usage"* ]]
}