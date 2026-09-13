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
  # CI runners have no jj user identity, so jj fails with "Won't push
  # commit ... no author and/or committer" in every test that commits.
  # JJ_CONFIG replaces the user-level config entirely (repo configs still
  # load), keeping the identity hermetic per test run with no pollution of
  # the runner's real config. Harmless in the jj-absent skip arms.
  # The config file lives OUTSIDE TEST_DIR: some suites assert on a clean
  # git worktree, where an untracked file inside the fixture would read
  # as dirty.
  local jj_home
  jj_home="$(mktemp -d)"
  cat > "$jj_home/jjconfig.toml" <<'TOML'
[user]
name = "Bats Fixture"
email = "bats-fixture@example.com"
TOML
  export JJ_CONFIG="$jj_home/jjconfig.toml"
}

teardown_test_dir() {
  if [ -n "${TEST_DIR:-}" ]; then
    rm -rf "$TEST_DIR"
  fi
  if [ -n "${JJ_CONFIG:-}" ]; then
    rm -rf "$(dirname "$JJ_CONFIG")"
    unset JJ_CONFIG
  fi

}
