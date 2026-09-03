#!/usr/bin/env bats
# Unit tests for lint-vcs-refs.sh — the raw VCS command linter.
# Tests the skip-list logic (--strict vs default) and pattern detection.
# Uses SKILLS_DIR env override to point at fixture skill files.

setup() {
  load "$REPO_ROOT/tests/helpers/setup.bash"
  setup_test_dir
  LINT="$(repo_script scripts/lint-vcs-refs.sh)"

  # Build a fixture skills tree mirroring the real layout
  FIXTURE_SKILLS="$TEST_DIR/fixtures/skills"
  mkdir -p "$FIXTURE_SKILLS/feature-a" "$FIXTURE_SKILLS/do" "$FIXTURE_SKILLS/talk"
}

teardown() {
  teardown_test_dir
}

run_lint() {
  SKILLS_DIR="$FIXTURE_SKILLS" run bash "$LINT" "$@"
}

@test "clean skill files: exit 0" {
  echo "No raw git commands here." > "$FIXTURE_SKILLS/feature-a/SKILL.md"
  run_lint
  [ "$status" -eq 0 ]
  [[ "$output" == *"No raw VCS or forge commands found"* ]]
}

@test "gh pr create detected (forge pattern)" {
  printf 'Run `gh pr create --draft`\n' > "$FIXTURE_SKILLS/feature-a/SKILL.md"
  run_lint
  [ "$status" -eq 1 ]
  [[ "$output" == *"gh pr create"* ]]
  [[ "$output" == *"forge tool"* ]]
}

@test "gh issue view detected (forge pattern)" {
  printf 'Fetch with `gh issue view <url>`\n' > "$FIXTURE_SKILLS/feature-a/SKILL.md"
  run_lint
  [ "$status" -eq 1 ]
  [[ "$output" == *"gh issue view"* ]]
}

@test "do/nodes/*.md scanned (expanded file scope)" {
  mkdir -p "$FIXTURE_SKILLS/do/nodes"
  printf 'Create a PR: `gh pr create --draft`\n' > "$FIXTURE_SKILLS/do/nodes/create-pr.md"
  run_lint
  [ "$status" -eq 1 ]
  [[ "$output" == *"create-pr.md"* ]]
}

@test "raw git diff detected in non-exempt skill file" {
  printf 'Run this:\n`git diff HEAD`\n' > "$FIXTURE_SKILLS/feature-a/SKILL.md"
  run_lint
  [ "$status" -eq 1 ]
  [[ "$output" == *"git diff "* ]]
}

@test "git push detected" {
  printf 'Push with `git push origin main`\n' > "$FIXTURE_SKILLS/feature-a/SKILL.md"
  run_lint
  [ "$status" -eq 1 ]
  [[ "$output" == *"git push "* ]]
}

@test "jj diff detected" {
  printf 'Use `jj diff -r @`\n' > "$FIXTURE_SKILLS/feature-a/SKILL.md"
  run_lint
  [ "$status" -eq 1 ]
  [[ "$output" == *"jj diff "* ]]
}

@test "do/SKILL.md exempt in default mode" {
  printf 'Internally calls `git diff HEAD`\n' > "$FIXTURE_SKILLS/do/SKILL.md"
  run_lint
  [ "$status" -eq 0 ]
  [[ "$output" != *"::error"* ]]
}

@test "do/SKILL.md caught in --strict mode" {
  printf 'Internally calls `git diff HEAD`\n' > "$FIXTURE_SKILLS/do/SKILL.md"
  run_lint --strict
  [ "$status" -eq 1 ]
}

@test "talk/SKILL.md exempt in default mode" {
  printf 'Agent may run `git log --oneline`\n' > "$FIXTURE_SKILLS/talk/SKILL.md"
  run_lint
  [ "$status" -eq 0 ]
  [[ "$output" != *"::error"* ]]
}

@test "talk/SKILL.md caught in --strict mode" {
  printf 'Agent may run `git log --oneline`\n' > "$FIXTURE_SKILLS/talk/SKILL.md"
  run_lint --strict
  [ "$status" -eq 1 ]
}

@test "jj new detected" {
  printf 'Then `jj new @-`\n' > "$FIXTURE_SKILLS/feature-a/SKILL.md"
  run_lint
  [ "$status" -eq 1 ]
  [[ "$output" == *"jj new "* ]]
}

@test "git status --porcelain detected" {
  printf 'Check `git status --porcelain`\n' > "$FIXTURE_SKILLS/feature-a/SKILL.md"
  run_lint
  [ "$status" -eq 1 ]
}

@test "no false positive on prose mentioning git without executable pattern" {
  printf 'The agent uses VCS operations via vcs-op.\n' > "$FIXTURE_SKILLS/feature-a/SKILL.md"
  run_lint
  [ "$status" -eq 0 ]
}
