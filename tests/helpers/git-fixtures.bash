# Shared git-fixture helpers for integration tests.
# Loaded via:  load "$REPO_ROOT/tests/helpers/git-fixtures.bash"
# Requires setup_test_dir to have run first (uses $TEST_DIR).

# Create an initial commit with a tracked file in the current git repo.
# Assumes git config (user.email, user.name) is already set.
mk_initial_commit() {
  echo "hello" > file.txt
  git add file.txt
  git commit -q -m "initial"
}

# Create a bare remote at $TEST_DIR/remote.git, point origin at it,
# push the current branch, and pin origin/HEAD.
mk_remote_fixture() {
  git init -q --bare "$TEST_DIR/remote.git"
  git remote set-url origin "$TEST_DIR/remote.git"
  git push -q origin master 2>/dev/null
  git remote set-head origin -a 2>/dev/null
}
