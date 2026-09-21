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

# Tool-reference consistency check (reviewer skills).
# Fixture runs have no agents/ tree, so the reviewer-agent branch is skipped;
# code-police files are checked against the bundled scout allowlist plus the
# extension-registered tools regardless.

@test "tool-allowlist check passes when reviewer skills reference allowed tools" {
  mkdir -p "$FIXTURE_SKILLS/lowy" "$FIXTURE_SKILLS/code-police"
  printf 'Use the `vcs_read` tool with `{ args: ["diff-range"] }`.\n' > "$FIXTURE_SKILLS/lowy/SKILL.md"
  printf 'Do not use the `ask` tool. Orchestration may use `web_search`.\n' > "$FIXTURE_SKILLS/code-police/SKILL.md"
  run_lint
  [ "$status" -eq 0 ]
  [[ "$output" == *"tool references are consistent"* ]]
}

@test "tool-allowlist check fails on disallowed reviewer tool reference" {
  mkdir -p "$FIXTURE_SKILLS/lowy"
  printf 'Invoke the `bash` tool with a shell command.\n' > "$FIXTURE_SKILLS/lowy/SKILL.md"
  run_lint
  [ "$status" -eq 1 ]
  [[ "$output" == *"Tool reference 'bash' is not on the reviewer-agent effective allowlist."* ]]
}

@test "tool-allowlist check fails on disallowed scout tool reference in code-police" {
  mkdir -p "$FIXTURE_SKILLS/code-police"
  printf 'Invoke the `bash` tool with a shell command.\n' > "$FIXTURE_SKILLS/code-police/SKILL.md"
  run_lint
  [ "$status" -eq 1 ]
  [[ "$output" == *"Tool reference 'bash' is not on the scout effective allowlist."* ]]
}

@test "tool-allowlist check accepts extension tool references in reviewer skills" {
  mkdir -p "$FIXTURE_SKILLS/hickey"
  printf 'Fetch with `forge { args: ["pr-view"] }` when the harness exposes it.\n' > "$FIXTURE_SKILLS/hickey/SKILL.md"
  run_lint
  # Without an agents/ tree the reviewer branch is skipped, so this only
  # proves the scanner itself does not crash on hickey files.
  [ "$status" -eq 0 ]
}

# Reviewer-agent branch coverage: fixture agents/ tree with controlled
# frontmatter, exercised through the AGENTS_DIR override.

setup_agents_fixture() {
  FIXTURE_AGENTS="$TEST_DIR/fixtures/agents"
  mkdir -p "$FIXTURE_AGENTS"
  printf -- '---\nname: hickey\ntools: read, grep, glob, vcs_read\n---\nbody\n' > "$FIXTURE_AGENTS/hickey.md"
  printf -- '---\nname: lowy\ntools: read, grep, glob, vcs_read\n---\nbody\n' > "$FIXTURE_AGENTS/lowy.md"
}

run_lint_agents() {
  SKILLS_DIR="$FIXTURE_SKILLS" AGENTS_DIR="$FIXTURE_AGENTS" run bash "$LINT" "$@"
}

@test "tool-allowlist check runs reviewer branch and passes equal frontmatters" {
  setup_agents_fixture
  mkdir -p "$FIXTURE_SKILLS/lowy"
  printf 'Use the `vcs_read` tool with `{ args: ["new-files"] }`.\n' > "$FIXTURE_SKILLS/lowy/SKILL.md"
  run_lint_agents
  [ "$status" -eq 0 ]
  [[ "$output" == *"tool references are consistent"* ]]
}

@test "tool-allowlist check fails on reviewer frontmatter mismatch" {
  setup_agents_fixture
  printf -- '---\nname: lowy\ntools: read, grep\n---\nbody\n' > "$FIXTURE_AGENTS/lowy.md"
  run_lint_agents
  [ "$status" -eq 1 ]
  [[ "$output" == *"frontmatter tools differ"* ]]
}

@test "tool-allowlist check fails on disallowed reviewer reference with agents present" {
  setup_agents_fixture
  mkdir -p "$FIXTURE_SKILLS/lowy"
  printf 'Invoke the `bash` tool with a shell command.\n' > "$FIXTURE_SKILLS/lowy/SKILL.md"
  run_lint_agents
  [ "$status" -eq 1 ]
  [[ "$output" == *"Tool reference 'bash' is not on the reviewer-agent effective allowlist."* ]]
}

@test "negation guard: 'Note' does not suppress the check" {
  setup_agents_fixture
  mkdir -p "$FIXTURE_SKILLS/lowy"
  printf 'Note: invoke the `bash` tool when needed.\n' > "$FIXTURE_SKILLS/lowy/SKILL.md"
  run_lint_agents
  [ "$status" -eq 1 ]
  [[ "$output" == *"Tool reference 'bash'"* ]]
}

@test "negation guard: 'Do not use' still suppresses the check" {
  setup_agents_fixture
  mkdir -p "$FIXTURE_SKILLS/lowy"
  printf 'Do not use the `ask` tool.\n' > "$FIXTURE_SKILLS/lowy/SKILL.md"
  run_lint_agents
  [ "$status" -eq 0 ]
}

@test "negation guard: bolded 'Do **not** use' suppresses the check" {
  setup_agents_fixture
  mkdir -p "$FIXTURE_SKILLS/lowy"
  printf 'Do **not** use the `ask` tool.\n' > "$FIXTURE_SKILLS/lowy/SKILL.md"
  run_lint_agents
  [ "$status" -eq 0 ]
}
