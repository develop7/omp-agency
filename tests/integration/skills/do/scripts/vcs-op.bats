#!/usr/bin/env bats
# Integration tests for vcs-op — the semantic VCS dispatcher.
# Uses real git repos (temp) as fixtures. jj arms are skipped when jj isn't
# available or can't be set up in the temp dir.

setup() {
  load "$REPO_ROOT/tests/helpers/setup.bash"
  load "$REPO_ROOT/tests/helpers/git-fixtures.bash"
  setup_test_dir


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
  run node "$REPO_ROOT/pure/dist/agency-do.js" vcs-op detect
  [ "$status" -eq 0 ]
  [ "$output" = "git" ]
}

@test "detect honors VCS_OVERRIDE" {
  VCS_OVERRIDE=jj run node "$REPO_ROOT/pure/dist/agency-do.js" vcs-op detect
  [ "$status" -eq 0 ]
  [ "$output" = "jj" ]
}

@test "detect returns unknown outside any repo" {
  cd /tmp
  VCS_OVERRIDE= run node "$REPO_ROOT/pure/dist/agency-do.js" vcs-op detect
  [ "$status" -eq 0 ]
  [ "$output" = "unknown" ]
}

# ─── dirty ────────────────────────────────────────────────────────────

@test "dirty: exit 1 on clean tree" {
  mk_initial_commit

  run node "$REPO_ROOT/pure/dist/agency-do.js" vcs-op dirty
  [ "$status" -eq 1 ]
}

@test "dirty: exit 0 on uncommitted changes" {
  mk_initial_commit
  echo "changed" > file.txt

  run node "$REPO_ROOT/pure/dist/agency-do.js" vcs-op dirty
  [ "$status" -eq 0 ]
}

@test "fast-forward-if-safe propagates a rev-list probe failure" {
  mk_initial_commit
  mk_remote_fixture
  git checkout -q -b feature
  git push -q -u origin feature
  real_git="$(command -v git)"
  mkdir -p "$TEST_DIR/bin"
  cat > "$TEST_DIR/bin/git" <<'SH'
#!/bin/sh
if [ "$1" = "rev-list" ]; then
  echo "forced rev-list failure" >&2
  exit 72
fi
exec "$REAL_GIT" "$@"
SH
  chmod +x "$TEST_DIR/bin/git"

  run env REAL_GIT="$real_git" PATH="$TEST_DIR/bin:$PATH" node "$REPO_ROOT/pure/dist/agency-do.js" vcs-op fast-forward-if-safe
  [ "$status" -eq 72 ]
  [[ "$output" == *"forced rev-list failure"* ]]
}

@test "fast-forward-if-safe rejects nonnumeric rev-list counts" {
  mk_initial_commit
  mk_remote_fixture
  git checkout -q -b feature
  git push -q -u origin feature
  real_git="$(command -v git)"
  mkdir -p "$TEST_DIR/bin"
  cat > "$TEST_DIR/bin/git" <<'SH'
#!/bin/sh
if [ "$1" = "rev-list" ]; then
  echo "not-a-count"
  exit 0
fi
exec "$REAL_GIT" "$@"
SH
  chmod +x "$TEST_DIR/bin/git"

  run env REAL_GIT="$real_git" PATH="$TEST_DIR/bin:$PATH" node "$REPO_ROOT/pure/dist/agency-do.js" vcs-op fast-forward-if-safe
  [ "$status" -ne 0 ]
  [[ "$output" == *"unable to parse git rev-list counts"* ]]
  [[ "$output" == *"not-a-count"* ]]
}

@test "fast-forward-if-safe propagates an unknown upstream probe failure" {
  mk_initial_commit
  mk_remote_fixture
  git checkout -q -b feature
  git push -q -u origin feature
  real_git="$(command -v git)"
  mkdir -p "$TEST_DIR/bin"
  cat > "$TEST_DIR/bin/git" <<'SH'
#!/bin/sh
if [ "$1" = "rev-parse" ] && [ "$2" = "--abbrev-ref" ] && [ "$3" = "@{u}" ]; then
  echo "forced upstream failure" >&2
  exit 73
fi
exec "$REAL_GIT" "$@"
SH
  chmod +x "$TEST_DIR/bin/git"

  run env REAL_GIT="$real_git" PATH="$TEST_DIR/bin:$PATH" node "$REPO_ROOT/pure/dist/agency-do.js" vcs-op fast-forward-if-safe
  [ "$status" -eq 73 ]
  [[ "$output" == *"forced upstream failure"* ]]
}

# ─── head-revision ────────────────────────────────────────────────────

@test "head-revision returns current branch name" {
  mk_initial_commit
  git checkout -q -b feature-x

  run node "$REPO_ROOT/pure/dist/agency-do.js" vcs-op head-revision
  [ "$status" -eq 0 ]
  [ "$output" = "feature-x" ]
}

# ─── head-commit-sha ──────────────────────────────────────────────────

@test "head-commit-sha returns a SHA" {
  mk_initial_commit
  sha=$(git rev-parse HEAD)

  run node "$REPO_ROOT/pure/dist/agency-do.js" vcs-op head-commit-sha
  [ "$status" -eq 0 ]
  [ "$output" = "$sha" ]
}

@test "jj: head-commit-sha identifies the current working revision" {
  command -v jj >/dev/null || skip "jj not installed"
  jj git init 2>/dev/null || skip "jj git init failed"
  expected="$(jj log --revision @ --no-graph --template commit_id)"

  run node "$REPO_ROOT/pure/dist/agency-do.js" vcs-op head-commit-sha
  [ "$status" -eq 0 ]
  [ "$output" = "$expected" ]
}

@test "jj: branch reads are empty rather than opaque IDs without a bookmark" {
  command -v jj >/dev/null || skip "jj not installed"
  jj git init 2>/dev/null || skip "jj git init failed"

  run node "$REPO_ROOT/pure/dist/agency-do.js" vcs-op head-revision
  [ "$status" -eq 0 ]
  [ "$output" = "" ]
  run node "$REPO_ROOT/pure/dist/agency-do.js" vcs-op current-branch
  [ "$status" -eq 0 ]
  [ "$output" = "" ]
}

# ─── default-branch ───────────────────────────────────────────────────

@test "default-branch returns master when origin/HEAD is unset" {
  mk_initial_commit

  run node "$REPO_ROOT/pure/dist/agency-do.js" vcs-op default-branch
  [ "$status" -eq 0 ]
  [ "$output" = "master" ]
}

@test "default-branch verifies the remote default ref before returning it" {
  mk_initial_commit
  git branch -m master main
  git update-ref refs/remotes/origin/main HEAD
  git symbolic-ref refs/remotes/origin/HEAD refs/remotes/origin/main

  run node "$REPO_ROOT/pure/dist/agency-do.js" vcs-op default-branch
  [ "$status" -eq 0 ]
  [ "$output" = "main" ]
}

@test "default-branch uses a verified remote main ref when remote HEAD is unset" {
  mk_initial_commit
  git update-ref refs/remotes/origin/main HEAD

  run node "$REPO_ROOT/pure/dist/agency-do.js" vcs-op default-branch
  [ "$status" -eq 0 ]
  [ "$output" = "main" ]
}

@test "jj: default-branch falls back from absent main to master" {
  command -v jj >/dev/null || skip "jj not installed"
  jj git init 2>/dev/null || skip "jj git init failed"
  jj bookmark create master -r @

  VCS_OVERRIDE=jj run node "$REPO_ROOT/pure/dist/agency-do.js" vcs-op default-branch
  [ "$status" -eq 0 ]
  [ "$output" = "master" ]
}

@test "jj: default-branch propagates fatal revision probe errors" {
  command -v jj >/dev/null || skip "jj not installed"
  jj git init 2>/dev/null || skip "jj git init failed"
  real_jj="$(command -v jj)"
  mkdir -p "$TEST_DIR/bin"
  cat > "$TEST_DIR/bin/jj" <<'SH'
#!/bin/sh
if [ "$1" = "log" ] && [ "$2" = "--revision" ] && [ "$3" = "main" ]; then
  echo "forced jj revision failure" >&2
  exit 75
fi
exec "$REAL_JJ" "$@"
SH
  chmod +x "$TEST_DIR/bin/jj"

  run env REAL_JJ="$real_jj" PATH="$TEST_DIR/bin:$PATH" VCS_OVERRIDE=jj node "$REPO_ROOT/pure/dist/agency-do.js" vcs-op default-branch
  [ "$status" -ne 0 ]
  [[ "$output" == *"forced jj revision failure"* ]]
}

@test "default-branch propagates fatal git ref probe errors" {
  mk_initial_commit
  real_git="$(command -v git)"
  mkdir -p "$TEST_DIR/bin"
  cat > "$TEST_DIR/bin/git" <<'SH'
#!/bin/sh
if [ "$1" = "show-ref" ]; then
  echo "forced show-ref failure" >&2
  exit 74
fi
exec "$REAL_GIT" "$@"
SH
  chmod +x "$TEST_DIR/bin/git"

  run env REAL_GIT="$real_git" PATH="$TEST_DIR/bin:$PATH" node "$REPO_ROOT/pure/dist/agency-do.js" vcs-op default-branch
  [ "$status" -ne 0 ]
  [[ "$output" == *"forced show-ref failure"* ]]
}

@test "branch propagates fatal git ref probe errors" {
  mk_initial_commit
  echo '{"base":"master"}' > .do-results.json
  real_git="$(command -v git)"
  mkdir -p "$TEST_DIR/bin"
  cat > "$TEST_DIR/bin/git" <<'SH'
#!/bin/sh
if [ "$1" = "show-ref" ]; then
  echo "forced show-ref failure" >&2
  exit 74
fi
exec "$REAL_GIT" "$@"
SH
  chmod +x "$TEST_DIR/bin/git"

  run env REAL_GIT="$real_git" PATH="$TEST_DIR/bin:$PATH" node "$REPO_ROOT/pure/dist/agency-do.js" vcs-op branch feature
  [ "$status" -ne 0 ]
  [[ "$output" == *"forced show-ref failure"* ]]
}

# ─── branch ───────────────────────────────────────────────────────────

@test "branch creates and checks out a new branch from the resolved base" {
  mk_initial_commit
  mk_remote_fixture

  # base is read from .do-results.json (set by sync); branch takes only <name>.
  echo '{"base":"master"}' > .do-results.json
  run node "$REPO_ROOT/pure/dist/agency-do.js" vcs-op branch feat-test
  [ "$status" -eq 0 ]

  git rev-parse --verify feat-test
  run git rev-parse --abbrev-ref HEAD
  [ "$output" = "feat-test" ]
}

@test "branch can start from a verified local base without a remote-tracking ref" {
  mk_initial_commit
  echo '{"base":"master"}' > .do-results.json

  run node "$REPO_ROOT/pure/dist/agency-do.js" vcs-op branch local-base-feature
  [ "$status" -eq 0 ]
  run git rev-parse --abbrev-ref HEAD
  [ "$output" = "local-base-feature" ]
}

# ─── commit ───────────────────────────────────────────────────────────

@test "commit stages and commits the given files" {
  mk_initial_commit
  echo "world" > file2.txt

  run node "$REPO_ROOT/pure/dist/agency-do.js" vcs-op commit "feat: add file2" file2.txt
  [ "$status" -eq 0 ]

  run git log -1 --oneline
  [[ "$output" == *"feat: add file2"* ]]

  # file2.txt should be committed
  git cat-file -e HEAD:file2.txt
}

@test "commit errors when no files are given" {
  mk_initial_commit
  echo "world" > file2.txt

  run node "$REPO_ROOT/pure/dist/agency-do.js" vcs-op commit "feat: add file2"
  [ "$status" -eq 1 ]
  [[ "$output" == *"at least one file required"* ]]
}

@test "commit errors when a given file is not dirty" {
  mk_initial_commit
  echo "world" > file2.txt

  run node "$REPO_ROOT/pure/dist/agency-do.js" vcs-op commit "feat: add file2" file2.txt nonexistent.txt
  [ "$status" -eq 1 ]
  [[ "$output" == *"not dirty"* ]]
  [[ "$output" == *"nonexistent.txt"* ]]
}

@test "commit stages only listed files, leaving others dirty" {
  mk_initial_commit
  echo "related" > feature.txt
  echo "unrelated" > notes.md

  run node "$REPO_ROOT/pure/dist/agency-do.js" vcs-op commit "feat: add feature" feature.txt
  [ "$status" -eq 0 ]

  # feature.txt is committed
  git cat-file -e HEAD:feature.txt
  # notes.md is NOT committed — still dirty
  run git status --porcelain -- notes.md
  [ "$status" -eq 0 ]
  [ -n "$output" ]
}

@test "commit leaves pre-staged unrelated files out of the commit" {
  mk_initial_commit
  echo "feature" > feature.txt
  echo "already staged" > staged.md
  git add staged.md

  run node "$REPO_ROOT/pure/dist/agency-do.js" vcs-op commit "feat: isolated index" feature.txt
  [ "$status" -eq 0 ]
  git cat-file -e HEAD:feature.txt
  ! git cat-file -e HEAD:staged.md
  run git diff --cached --quiet -- staged.md
  [ "$status" -eq 1 ]
}

@test "fix-commit stages given files and pushes" {
  mk_initial_commit
  mk_remote_fixture
  git checkout -q -b feature
  git push -q -u origin feature 2>/dev/null
  echo "fix" > fix.txt

  run node "$REPO_ROOT/pure/dist/agency-do.js" vcs-op fix-commit "fix: something" fix.txt
  [ "$status" -eq 0 ]

  run git log -1 --oneline
  [[ "$output" == *"fix: something"* ]]
  git cat-file -e HEAD:fix.txt
  run git --git-dir="$TEST_DIR/remote.git" log -1 --format=%s feature
  [ "$output" = "fix: something" ]
}

# ─── log-head ─────────────────────────────────────────────────────────

@test "log-head returns one-line log of HEAD" {
  mk_initial_commit

  run node "$REPO_ROOT/pure/dist/agency-do.js" vcs-op log-head
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
  run node "$REPO_ROOT/pure/dist/agency-do.js" vcs-op log-range
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
  run node "$REPO_ROOT/pure/dist/agency-do.js" vcs-op diff-names
  [ "$status" -eq 0 ]
  [[ "$output" == *"file2.txt"* ]]
}

# ─── base / get_base_branch ───────────────────────────────────────────

@test "base op prints the resolved base from .do-results.json" {
  mk_initial_commit
  echo '{"base":"feat-x"}' > .do-results.json

  run node "$REPO_ROOT/pure/dist/agency-do.js" vcs-op base
  [ "$status" -eq 0 ]
  [ "$output" = "feat-x" ]
}

@test "get_base_branch hard-errors when base is absent" {
  mk_initial_commit
  echo '{}' > .do-results.json

  run node "$REPO_ROOT/pure/dist/agency-do.js" vcs-op base
  [ "$status" -eq 1 ]
  [[ "$output" == *"base is not set"* ]]
}

@test "get_base_branch hard-errors when .do-results.json is missing" {
  mk_initial_commit

  run node "$REPO_ROOT/pure/dist/agency-do.js" vcs-op base
  [ "$status" -eq 1 ]
  [[ "$output" == *"base is not set"* ]]
}

# ─── current-branch ───────────────────────────────────────────────────

@test "current-branch returns the checked-out branch" {
  mk_initial_commit
  git checkout -q -b feature-y

  run node "$REPO_ROOT/pure/dist/agency-do.js" vcs-op current-branch
  [ "$status" -eq 0 ]
  [ "$output" = "feature-y" ]
}

# ─── error paths ──────────────────────────────────────────────────────

@test "unknown operation errors with available ops list" {
  run node "$REPO_ROOT/pure/dist/agency-do.js" vcs-op frobnicate
  [ "$status" -eq 1 ]
  [[ "$output" == *"unknown operation 'frobnicate'"* ]]
  [[ "$output" == *"Available:"* ]]
}

@test "no-VCS operations exit 1 with message" {
  cd /tmp
  VCS_OVERRIDE= run node "$REPO_ROOT/pure/dist/agency-do.js" vcs-op fetch
  [ "$status" -eq 1 ]
  [[ "$output" == *"no VCS detected"* ]]
}

# ─── jj arms (skipped when jj isn't available) ────────────────────────

@test "jj: detect in jj colocated repo" {
  command -v jj >/dev/null || skip "jj not installed"
  jj git init --colocate 2>/dev/null || skip "jj git init failed"

  VCS_OVERRIDE= run node "$REPO_ROOT/pure/dist/agency-do.js" vcs-op detect
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
  jj bookmark create feature -r @
  echo feature > feature.txt
  echo feature-test > feature_test.txt
  echo junk > notes.md

  run node "$REPO_ROOT/pure/dist/agency-do.js" vcs-op commit "feat: add feature" feature.txt feature_test.txt
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
  jj bookmark create feature -r @
  echo feature > feature.txt
  echo feature-test > feature_test.txt

  # All changed files passed — no split needed
  run node "$REPO_ROOT/pure/dist/agency-do.js" vcs-op commit "feat: add feature" feature.txt feature_test.txt
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

  run node "$REPO_ROOT/pure/dist/agency-do.js" vcs-op commit "feat: add feature"
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

  run node "$REPO_ROOT/pure/dist/agency-do.js" vcs-op commit "feat: add feature" feature.txt nonexistent.txt
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
  jj bookmark create feature -r @
  echo feature > feature.txt
  echo more >> README.md

  # ./ prefix must not cause "not dirty" false negative (#13)
  run node "$REPO_ROOT/pure/dist/agency-do.js" vcs-op commit "feat: add feature" ./feature.txt ./README.md
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
  jj bookmark create feature -r @
  echo feature > feature.txt

  local abs
  abs="$(pwd)/feature.txt"
  run node "$REPO_ROOT/pure/dist/agency-do.js" vcs-op commit "feat: add feature" "$abs"
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
  jj bookmark create feature -r @
  echo feature > feature.txt
  echo junk > notes.md

  # Commit feature.txt with ./ prefix while notes.md is also dirty.
  # feature.txt must land in the feature commit, NOT be split as "unrelated".
  run node "$REPO_ROOT/pure/dist/agency-do.js" vcs-op commit "feat: add feature" ./feature.txt
  [ "$status" -eq 0 ]

  # @- is the feature commit; @-- is base. Only feature.txt should be there.
  run jj diff --from @-- --to @- --name-only
  [[ "$output" == *"feature.txt"* ]]
  [[ "$output" != *"notes.md"* ]]
  [[ "$output" != *"README.md"* ]]
}

# ─── jj diff-range: target @ (issue #4) ──────────────────────────────

@test "jj: diff-range shows work in @ (--no-vcs state, no commit)" {
  # Regression (#4): the jj arms targeted @-, but under --no-vcs the
  # commit node is skipped and all work lives in @ — so the diff was
  # empty. The fix targets @ (the working copy), which is correct in
  # both the committed and working-copy-only states.
  command -v jj >/dev/null || skip "jj not installed"
  jj git init 2>/dev/null || skip "jj git init failed"

  echo base > README.md
  jj describe -m "base"
  jj bookmark create main -r @
  echo '{"base":"main"}' > .do-results.json

  jj new main
  echo feature > feature.txt

  # Work is in @ (uncommitted); @- is main (the base).
  run node "$REPO_ROOT/pure/dist/agency-do.js" vcs-op diff-range
  [ "$status" -eq 0 ]
  [[ "$output" == *"feature.txt"* ]]

  run node "$REPO_ROOT/pure/dist/agency-do.js" vcs-op diff-names
  [ "$status" -eq 0 ]
  [[ "$output" == *"feature.txt"* ]]

  run node "$REPO_ROOT/pure/dist/agency-do.js" vcs-op new-files
  [ "$status" -eq 0 ]
  [[ "$output" == *"feature.txt"* ]]
}

@test "jj: diff-range shows committed work in @- (post-commit state, @ empty)" {
  # Post-commit: vcs-op commit does `jj describe && jj new`, so @ is a
  # fresh empty change and the feature is @-. Targeting @ still works
  # because @'s tree matches @- (snapshot diff), so base→@ == base→@-.
  #
  # The base bookmark must be separate from the working bookmark: the
  # commit op moves the working bookmark to the described change, so if
  # base == working bookmark it would end up on the feature commit and
  # the diff would be empty. In the real /do flow the feature branch
  # (created by the branch step) is distinct from main.
  command -v jj >/dev/null || skip "jj not installed"
  jj git init 2>/dev/null || skip "jj git init failed"

  echo base > README.md
  jj describe -m "base"
  jj bookmark create main -r @
  echo '{"base":"main"}' > .do-results.json

  # Create a feature bookmark (as the branch step would) so commit moves
  # the feature bookmark, not main.
  jj new main
  jj bookmark create feature -r @
  echo feature > feature.txt
  run node "$REPO_ROOT/pure/dist/agency-do.js" vcs-op commit "feat: add feature" feature.txt
  [ "$status" -eq 0 ]

  # main stays on the base commit; @ is now empty; feature is @-.
  # diff-range must still show feature.txt via the @ target.
  run node "$REPO_ROOT/pure/dist/agency-do.js" vcs-op diff-range
  [ "$status" -eq 0 ]
  [[ "$output" == *"feature.txt"* ]]

  run node "$REPO_ROOT/pure/dist/agency-do.js" vcs-op log-range
  [ "$status" -eq 0 ]
  [[ "$output" == *"feat: add feature"* ]]
}

@test "jj: diff-range with unresolvable base exits non-zero" {
  command -v jj >/dev/null || skip "jj not installed"
  jj git init 2>/dev/null || skip "jj git init failed"

  echo base > README.md
  jj describe -m "base"
  jj bookmark create main -r @
  echo '{"base":"nonexistent-ref"}' > .do-results.json

  jj new main
  echo feature > feature.txt

  run node "$REPO_ROOT/pure/dist/agency-do.js" vcs-op diff-range
  [ "$status" -ne 0 ]
}

# ─── VCS safety regressions ───────────────────────────────────────────

@test "branch rejects unsafe names before invoking git" {
  mk_initial_commit
  mk_remote_fixture
  echo '{"base":"master"}' > .do-results.json

  run node "$REPO_ROOT/pure/dist/agency-do.js" vcs-op branch '-lead-dash'
  [ "$status" -eq 1 ]
  [[ "$output" == *"invalid branch name '-lead-dash'"* ]]

  run node "$REPO_ROOT/pure/dist/agency-do.js" vcs-op branch 'foo;touch-pwned'
  [ "$status" -eq 1 ]
  [[ "$output" == *"invalid branch name 'foo;touch-pwned'"* ]]
  ! git show-ref --verify --quiet 'refs/heads/foo;touch-pwned'
}

@test "default-branch refuses to guess when no verified branch exists" {
  run node "$REPO_ROOT/pure/dist/agency-do.js" vcs-op default-branch
  [ "$status" -eq 1 ]
  [[ "$output" == *"unable to resolve default branch"* ]]
}

@test "jj: branch and read ops use a remote-only base bookmark" {
  command -v jj >/dev/null || skip "jj not installed"
  jj git init 2>/dev/null || skip "jj git init failed"
  git init -q --bare "$TEST_DIR/remote.git"
  git remote set-url origin "$TEST_DIR/remote.git"

  echo base > README.md
  jj describe -m "base"
  jj bookmark create main -r @
  jj git push --remote origin --bookmark main
  jj bookmark delete main
  jj git fetch --remote origin
  echo '{"base":"main"}' > .do-results.json

  run node "$REPO_ROOT/pure/dist/agency-do.js" vcs-op branch feature-remote-base
  [ "$status" -eq 0 ]
  echo feature > feature.txt
  run node "$REPO_ROOT/pure/dist/agency-do.js" vcs-op commit "feat: remote base" feature.txt
  [ "$status" -eq 0 ]
  run node "$REPO_ROOT/pure/dist/agency-do.js" vcs-op diff-names
  [ "$status" -eq 0 ]
  [[ "$output" == *"feature.txt"* ]]
  run node "$REPO_ROOT/pure/dist/agency-do.js" vcs-op log-range
  [ "$status" -eq 0 ]
  [[ "$output" == *"feat: remote base"* ]]
}

@test "jj: commit preserves workflow state and never retargets trunk" {
  command -v jj >/dev/null || skip "jj not installed"
  jj git init 2>/dev/null || skip "jj git init failed"

  echo base > README.md
  jj describe -m "base"
  jj bookmark create main -r @
  echo '{"base":"main","workflow":"state"}' > .do-results.json
  run node "$REPO_ROOT/pure/dist/agency-do.js" vcs-op branch feature-safe-bookmark
  [ "$status" -eq 0 ]
  main_before="$(jj log --revision main --no-graph --template commit_id)"

  echo feature > feature.txt
  echo unrelated > unrelated.txt
  run node "$REPO_ROOT/pure/dist/agency-do.js" vcs-op commit "feat: keep trunk" feature.txt
  [ "$status" -eq 0 ]
  [ -f .do-results.json ]
  [ "$(cat .do-results.json)" = '{"base":"main","workflow":"state"}' ]
  [ "$(jj log --revision main --no-graph --template commit_id)" = "$main_before" ]
  run jj bookmark list --revision @- --template 'name ++ "\n"'
  [ "$output" = "feature-safe-bookmark" ]
}

@test "jj: commit safely accepts dash-leading messages and unrelated paths" {
  command -v jj >/dev/null || skip "jj not installed"
  jj git init 2>/dev/null || skip "jj git init failed"

  echo base > README.md
  jj describe -m "base"
  jj bookmark create main -r @
  echo '{"base":"main"}' > .do-results.json
  run node "$REPO_ROOT/pure/dist/agency-do.js" vcs-op branch feature-dash-arguments
  [ "$status" -eq 0 ]

  echo feature > feature.txt
  echo unrelated > -dash-unrelated
  run node "$REPO_ROOT/pure/dist/agency-do.js" vcs-op commit "-fix: argument safety" feature.txt
  [ "$status" -eq 0 ]
  run jj log --revision @- --no-graph --template 'description.first_line()'
  [ "$output" = "-fix: argument safety" ]
  run jj diff --from @-- --to @- --name-only
  [[ "$output" == *"feature.txt"* ]]
  [[ "$output" != *"-dash-unrelated"* ]]
  run jj diff --name-only
  [ "$status" -eq 0 ]
  [[ "$output" == *"-dash-unrelated"* ]]
}

@test "jj: commit refuses an unbookmarked working copy instead of moving trunk" {
  command -v jj >/dev/null || skip "jj not installed"
  jj git init 2>/dev/null || skip "jj git init failed"

  echo base > README.md
  jj describe -m "base"
  jj bookmark create main -r @
  echo '{"base":"main"}' > .do-results.json
  main_before="$(jj log --revision main --no-graph --template commit_id)"
  jj new main
  echo feature > feature.txt

  run node "$REPO_ROOT/pure/dist/agency-do.js" vcs-op commit "feat: must have bookmark" feature.txt
  [ "$status" -eq 1 ]
  [[ "$output" == *"no feature bookmark"* ]]
  [ "$(jj log --revision main --no-graph --template commit_id)" = "$main_before" ]
}

@test "jj: push and fix-commit target only the current feature bookmark" {
  command -v jj >/dev/null || skip "jj not installed"
  jj git init 2>/dev/null || skip "jj git init failed"
  git init -q --bare "$TEST_DIR/remote.git"
  git remote remove origin
  git remote add origin "$TEST_DIR/remote.git"

  echo base > README.md
  jj describe -m "base"
  jj bookmark create main -r @
  jj git push --remote origin --bookmark main
  jj git fetch --remote origin
  echo '{"base":"main"}' > .do-results.json
  run node "$REPO_ROOT/pure/dist/agency-do.js" vcs-op push main
  [ "$status" -eq 1 ]
  [[ "$output" == *"refusing jj trunk push"* ]]
  main_before="$(git --git-dir="$TEST_DIR/remote.git" rev-parse refs/heads/main)"

  run node "$REPO_ROOT/pure/dist/agency-do.js" vcs-op branch feature-narrow-push
  [ "$status" -eq 0 ]
  echo feature > feature.txt
  run node "$REPO_ROOT/pure/dist/agency-do.js" vcs-op commit "feat: narrow push" feature.txt
  [ "$status" -eq 0 ]

  run node "$REPO_ROOT/pure/dist/agency-do.js" vcs-op push
  [ "$status" -eq 0 ]
  echo fix >> feature.txt
  feature_after_first="$(git --git-dir="$TEST_DIR/remote.git" rev-parse refs/heads/feature-narrow-push)"
  run node "$REPO_ROOT/pure/dist/agency-do.js" vcs-op fix-commit "fix: narrow push" feature.txt
  [ "$status" -eq 0 ]
  [ "$(git --git-dir="$TEST_DIR/remote.git" rev-parse refs/heads/main)" = "$main_before" ]
  git --git-dir="$TEST_DIR/remote.git" rev-parse --verify refs/heads/feature-narrow-push
  [ "$(git --git-dir="$TEST_DIR/remote.git" rev-parse refs/heads/feature-narrow-push)" != "$feature_after_first" ]
}

@test "jj: remote-url prefers origin over an alphabetically earlier fork" {
  command -v jj >/dev/null || skip "jj not installed"
  jj git init 2>/dev/null || skip "jj git init failed"
  git remote add fork https://gitlab.com/example/fork.git

  run node "$REPO_ROOT/pure/dist/agency-do.js" vcs-op remote-url
  [ "$status" -eq 0 ]
  [ "$output" = "https://github.com/example/repo.git" ]
}
