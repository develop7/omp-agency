#!/usr/bin/env bats
# Integration tests for vcs-op — the semantic VCS dispatcher.
# Uses real git repos (temp) as fixtures. jj arms are skipped when jj isn't
# available or can't be set up in the temp dir.

setup() {
  load "$REPO_ROOT/tests/helpers/setup.bash"
  load "$REPO_ROOT/tests/helpers/git-fixtures.bash"
  setup_test_dir

  VCS_OP="$(repo_script skills/do/scripts/vcs-op)"

  # Create a real git fixture repo
  git init -q
  git config user.email "test@test.com"
  git config user.name "Test"
  git remote add origin https://github.com/example/repo.git
}

teardown() {
  teardown_test_dir
}

# ─── detect ───────────────────────────────────────────────────────────

@test "detect returns git in a git repo" {
  run bash "$VCS_OP" detect
  [ "$status" -eq 0 ]
  [ "$output" = "git" ]
}

@test "detect honors VCS_OVERRIDE" {
  VCS_OVERRIDE=jj run bash "$VCS_OP" detect
  [ "$status" -eq 0 ]
  [ "$output" = "jj" ]
}

@test "detect returns unknown outside any repo" {
  cd /tmp
  VCS_OVERRIDE= run bash "$VCS_OP" detect
  [ "$status" -eq 0 ]
  [ "$output" = "unknown" ]
}

# ─── dirty ────────────────────────────────────────────────────────────

@test "dirty: exit 1 on clean tree" {
  mk_initial_commit

  run bash "$VCS_OP" dirty
  [ "$status" -eq 1 ]
}

@test "dirty: exit 0 on uncommitted changes" {
  mk_initial_commit
  echo "changed" > file.txt

  run bash "$VCS_OP" dirty
  [ "$status" -eq 0 ]
}

# ─── head-revision ────────────────────────────────────────────────────

@test "head-revision returns current branch name" {
  mk_initial_commit
  git checkout -q -b feature-x

  run bash "$VCS_OP" head-revision
  [ "$status" -eq 0 ]
  [ "$output" = "feature-x" ]
}

# ─── head-commit-sha ──────────────────────────────────────────────────

@test "head-commit-sha returns a SHA" {
  mk_initial_commit
  sha=$(git rev-parse HEAD)

  run bash "$VCS_OP" head-commit-sha
  [ "$status" -eq 0 ]
  [ "$output" = "$sha" ]
}

# ─── default-branch ───────────────────────────────────────────────────

@test "default-branch returns master when origin/HEAD is unset" {
  mk_initial_commit

  run bash "$VCS_OP" default-branch
  [ "$status" -eq 0 ]
  [ "$output" = "master" ]
}

@test "default-branch returns main when origin/HEAD points to main" {
  mk_initial_commit
  git branch -m master main
  git symbolic-ref refs/remotes/origin/HEAD refs/remotes/origin/main

  run bash "$VCS_OP" default-branch
  [ "$status" -eq 0 ]
  [ "$output" = "main" ]
}

# ─── branch ───────────────────────────────────────────────────────────

@test "branch creates a new branch from origin/base" {
  mk_initial_commit
  mk_remote_fixture

  # base is read from .do-results.json (set by sync); branch takes only <name>.
  echo '{"base":"master"}' > .do-results.json
  run bash "$VCS_OP" branch feat-test
  [ "$status" -eq 0 ]

  git rev-parse --verify feat-test
}

# ─── commit ───────────────────────────────────────────────────────────

@test "commit stages and commits the given files" {
  mk_initial_commit
  echo "world" > file2.txt

  run bash "$VCS_OP" commit "feat: add file2" file2.txt
  [ "$status" -eq 0 ]

  run git log -1 --oneline
  [[ "$output" == *"feat: add file2"* ]]

  # file2.txt should be committed
  git cat-file -e HEAD:file2.txt
}

@test "commit errors when no files are given" {
  mk_initial_commit
  echo "world" > file2.txt

  run bash "$VCS_OP" commit "feat: add file2"
  [ "$status" -eq 1 ]
  [[ "$output" == *"at least one file required"* ]]
}

@test "commit errors when a given file is not dirty" {
  mk_initial_commit
  echo "world" > file2.txt

  run bash "$VCS_OP" commit "feat: add file2" file2.txt nonexistent.txt
  [ "$status" -eq 1 ]
  [[ "$output" == *"not dirty"* ]]
  [[ "$output" == *"nonexistent.txt"* ]]
}

@test "commit stages only listed files, leaving others dirty" {
  mk_initial_commit
  echo "related" > feature.txt
  echo "unrelated" > notes.md

  run bash "$VCS_OP" commit "feat: add feature" feature.txt
  [ "$status" -eq 0 ]

  # feature.txt is committed
  git cat-file -e HEAD:feature.txt
  # notes.md is NOT committed — still dirty
  run git status --porcelain -- notes.md
  [ "$status" -eq 0 ]
  [ -n "$output" ]
}

@test "fix-commit stages given files and pushes" {
  mk_initial_commit
  mk_remote_fixture
  git checkout -q -b feature
  git push -q -u origin feature 2>/dev/null
  echo "fix" > fix.txt

  run bash "$VCS_OP" fix-commit "fix: something" fix.txt
  [ "$status" -eq 0 ]

  run git log -1 --oneline
  [[ "$output" == *"fix: something"* ]]
  git cat-file -e HEAD:fix.txt
}

# ─── log-head ─────────────────────────────────────────────────────────

@test "log-head returns one-line log of HEAD" {
  mk_initial_commit

  run bash "$VCS_OP" log-head
  [ "$status" -eq 0 ]
  [[ "$output" == *"initial"* ]]
}

# ─── log-range ────────────────────────────────────────────────────────

@test "log-range shows commits between base and HEAD" {
  mk_initial_commit
  mk_remote_fixture

  git checkout -q -b feature
  echo "world" > file2.txt
  git add file2.txt
  git commit -q -m "add file2"

  # base (master) is read from .do-results.json, not a positional arg.
  echo '{"base":"master"}' > .do-results.json
  run bash "$VCS_OP" log-range
  [ "$status" -eq 0 ]
  [[ "$output" == *"add file2"* ]]
  [[ "$output" != *"initial"* ]]
}

# ─── diff-names ───────────────────────────────────────────────────────

@test "diff-names shows changed files" {
  mk_initial_commit
  mk_remote_fixture

  git checkout -q -b feature
  echo "world" > file2.txt
  git add file2.txt
  git commit -q -m "add file2"

  echo '{"base":"master"}' > .do-results.json
  run bash "$VCS_OP" diff-names
  [ "$status" -eq 0 ]
  [[ "$output" == *"file2.txt"* ]]
}

# ─── base / get_base_branch ───────────────────────────────────────────

@test "base op prints the resolved base from .do-results.json" {
  mk_initial_commit
  echo '{"base":"feat-x"}' > .do-results.json

  run bash "$VCS_OP" base
  [ "$status" -eq 0 ]
  [ "$output" = "feat-x" ]
}

@test "get_base_branch hard-errors when base is absent" {
  mk_initial_commit
  echo '{}' > .do-results.json

  run bash "$VCS_OP" base
  [ "$status" -eq 1 ]
  [[ "$output" == *"base is not set"* ]]
}

@test "get_base_branch hard-errors when .do-results.json is missing" {
  mk_initial_commit

  run bash "$VCS_OP" base
  [ "$status" -eq 1 ]
  [[ "$output" == *"base is not set"* ]]
}

# ─── current-branch ───────────────────────────────────────────────────

@test "current-branch returns the checked-out branch" {
  mk_initial_commit
  git checkout -q -b feature-y

  run bash "$VCS_OP" current-branch
  [ "$status" -eq 0 ]
  [ "$output" = "feature-y" ]
}

# ─── error paths ──────────────────────────────────────────────────────

@test "unknown operation errors with available ops list" {
  run bash "$VCS_OP" frobnicate
  [ "$status" -eq 1 ]
  [[ "$output" == *"unknown operation 'frobnicate'"* ]]
  [[ "$output" == *"Available:"* ]]
}

@test "no-VCS operations exit 1 with message" {
  cd /tmp
  VCS_OVERRIDE= run bash "$VCS_OP" fetch
  [ "$status" -eq 1 ]
  [[ "$output" == *"no VCS detected"* ]]
}

# ─── jj arms (skipped when jj isn't available) ────────────────────────

@test "jj: detect in jj colocated repo" {
  command -v jj >/dev/null || skip "jj not installed"
  jj git init --colocate 2>/dev/null || skip "jj git init failed"

  VCS_OVERRIDE= run bash "$VCS_OP" detect
  [ "$status" -eq 0 ]
  [[ "$output" == "jj" ]]
}

# ─── jj commit arms (skipped when jj isn't available) ─────────────────

@test "jj: commit with explicit files splits unrelated changes out" {
  command -v jj >/dev/null || skip "jj not installed"
  jj git init 2>/dev/null || skip "jj git init failed"

  # Create a base change with a bookmark
  echo base > README.md
  jj describe -m "base"
  jj bookmark create main -r @
  echo '{"base":"main"}' > .do-results.json

  # Working copy has feature files + an unrelated file
  jj new main
  echo feature > feature.txt
  echo feature-test > feature_test.txt
  echo junk > notes.md

  run bash "$VCS_OP" commit "feat: add feature" feature.txt feature_test.txt
  [ "$status" -eq 0 ]

  # @- (the committed feature change) should have only feature files.
  # Diff from @-- (base) to @- (feature commit) — main bookmark moved to @-
  # so we can't diff from main anymore.
  run jj diff --from @-- --to @- --name-only
  [[ "$output" == *"feature.txt"* ]]
  [[ "$output" == *"feature_test.txt"* ]]
  [[ "$output" != *"notes.md"* ]]

  # notes.md should be in a separate revision, not in the feature commit
  run jj file show notes.md -r @- 2>&1
  [ "$status" -ne 0 ]
}

@test "jj: commit with all changed files makes a single commit (no split)" {
  command -v jj >/dev/null || skip "jj not installed"
  jj git init 2>/dev/null || skip "jj git init failed"

  echo base > README.md
  jj describe -m "base"
  jj bookmark create main -r @
  echo '{"base":"main"}' > .do-results.json

  jj new main
  echo feature > feature.txt
  echo feature-test > feature_test.txt

  # All changed files passed — no split needed
  run bash "$VCS_OP" commit "feat: add feature" feature.txt feature_test.txt
  [ "$status" -eq 0 ]

  # @- should have both files. Diff from @-- (base) to @- (feature commit).
  run jj diff --from @-- --to @- --name-only
  [[ "$output" == *"feature.txt"* ]]
  [[ "$output" == *"feature_test.txt"* ]]
}

@test "jj: commit with no files errors" {
  command -v jj >/dev/null || skip "jj not installed"
  jj git init 2>/dev/null || skip "jj git init failed"

  echo base > README.md
  jj describe -m "base"

  jj new
  echo feature > feature.txt

  run bash "$VCS_OP" commit "feat: add feature"
  [ "$status" -eq 1 ]
  [[ "$output" == *"at least one file required"* ]]
}

@test "jj: commit with a non-dirty file errors" {
  command -v jj >/dev/null || skip "jj not installed"
  jj git init 2>/dev/null || skip "jj git init failed"

  echo base > README.md
  jj describe -m "base"

  jj new
  echo feature > feature.txt

  run bash "$VCS_OP" commit "feat: add feature" feature.txt nonexistent.txt
  [ "$status" -eq 1 ]
  [[ "$output" == *"not dirty"* ]]
  [[ "$output" == *"nonexistent.txt"* ]]
}

@test "jj: commit accepts ./-prefixed paths (no false negative)" {
  command -v jj >/dev/null || skip "jj not installed"
  jj git init 2>/dev/null || skip "jj git init failed"

  echo base > README.md
  jj describe -m "base"
  jj bookmark create main -r @
  echo '{"base":"main"}' > .do-results.json

  jj new main
  echo feature > feature.txt
  echo more >> README.md

  # ./ prefix must not cause "not dirty" false negative (#13)
  run bash "$VCS_OP" commit "feat: add feature" ./feature.txt ./README.md
  [ "$status" -eq 0 ]

  run jj diff --from @-- --to @- --name-only
  [[ "$output" == *"feature.txt"* ]]
  [[ "$output" == *"README.md"* ]]
}

@test "jj: commit accepts absolute paths (no false negative)" {
  command -v jj >/dev/null || skip "jj not installed"
  jj git init 2>/dev/null || skip "jj git init failed"

  echo base > README.md
  jj describe -m "base"
  jj bookmark create main -r @
  echo '{"base":"main"}' > .do-results.json

  jj new main
  echo feature > feature.txt

  local abs
  abs="$(pwd)/feature.txt"
  run bash "$VCS_OP" commit "feat: add feature" "$abs"
  [ "$status" -eq 0 ]
}

@test "jj: commit with ./-prefixed path is not misclassified as unrelated" {
  # Regression: before the fix, ./README.md != README.md in the set
  # subtraction, so the caller's own file was split into a chore commit (#13).
  command -v jj >/dev/null || skip "jj not installed"
  jj git init 2>/dev/null || skip "jj git init failed"

  echo base > README.md
  jj describe -m "base"
  jj bookmark create main -r @
  echo '{"base":"main"}' > .do-results.json

  jj new main
  echo feature > feature.txt
  echo junk > notes.md

  # Commit feature.txt with ./ prefix while notes.md is also dirty.
  # feature.txt must land in the feature commit, NOT be split as "unrelated".
  run bash "$VCS_OP" commit "feat: add feature" ./feature.txt
  [ "$status" -eq 0 ]

  # @- is the feature commit; @-- is base. Only feature.txt should be there.
  run jj diff --from @-- --to @- --name-only
  [[ "$output" == *"feature.txt"* ]]
  [[ "$output" != *"notes.md"* ]]
  [[ "$output" != *"README.md"* ]]
}
