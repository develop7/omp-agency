# Shared setup helpers for bats test suites.
#
# Loaded via:  load "$REPO_ROOT/tests/helpers/setup.bash"
# Requires REPO_ROOT to be set before loading (the just recipe sets it;
# if running bats by hand, set it manually:  REPO_ROOT=$(pwd) bats tests/).

# Resolve the absolute path of a script-under-test by its repo-root-relative path.
repo_script() {
  echo "${REPO_ROOT:?}/$1"
}

# Create a temp working directory and cd into it.
# Pair with teardown_test_dir in each file's teardown().
# Sets TEST_DIR to the absolute path of the temp dir.
setup_test_dir() {
  TEST_DIR="$(mktemp -d)"
  cd "$TEST_DIR" || return 1
}

teardown_test_dir() {
  if [ -n "${TEST_DIR:-}" ]; then
    rm -rf "$TEST_DIR"
  fi
}
