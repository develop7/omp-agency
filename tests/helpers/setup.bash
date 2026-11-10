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
  cat >"$jj_home/jjconfig.toml" <<'TOML'
[user]
name = "Bats Fixture"
email = "bats-fixture@example.com"
TOML
  export JJ_CONFIG="$jj_home/jjconfig.toml"
  # Each fixture owns an external workflow-state root, outside the worktree.
  export AGENCY_STATE_DIR="$TEST_DIR/agency-state"
}

# ── Workflow-state helpers ───────────────────────────────────────────
# Workflow state lives in a per-worktree SQLite snapshot under
# AGENCY_STATE_DIR; nothing in the worktree is authoritative. These helpers
# read the store only through the public `do-driver state` operation, and
# touch the SQLite file directly only to inject a corrupt payload.

# The PureScript CLI bundle under test (AGENCY_DO_BIN overrides the build).
agency_do() {
  node "${AGENCY_DO_BIN:-$REPO_ROOT/pure/dist/agency-do.js}" "$@"
}

# Canonical workflow state JSON. Fails when no snapshot exists yet.
driver_state() {
  agency_do do-driver state
}

# jq projection of the canonical state, e.g. `state_jq -r '.task'`.
state_jq() {
  local json
  json="$(driver_state)" || return $?
  jq "$@" <<<"$json"
}

# Create a fresh run and persist `base`, validated against the fixture's refs.
seed_base() {
  local base="$1"
  agency_do do-driver init "fixture run" >/dev/null || return 1
  agency_do do-driver set base "$base" >/dev/null || return 1
}

# Seed a fixed-timestamp run for the done-summary suites.
seed_done_state() {
  local started="$1" status="$2" steps="$3"
  agency_do do-driver init "done fixture" >/dev/null || return 1
  agency_do do-driver set startedAt "$started" >/dev/null || return 1
  agency_do do-driver set active idle >/dev/null || return 1
  agency_do do-driver set status "$status" >/dev/null || return 1
  agency_do do-driver set steps "$steps" >/dev/null
}

# Path of this worktree's SQLite snapshot.
state_db_path() {
  node --input-type=module -e '
    import { createHash } from "node:crypto";
    import { realpathSync } from "node:fs";
    import { join } from "node:path";
    const workspace = realpathSync.native(process.argv[1]);
    const digest = createHash("sha256").update(workspace).digest("hex");
    process.stdout.write(join(process.env.AGENCY_STATE_DIR, digest + ".db"));
  ' "$PWD"
}

# Replace the stored payload with arbitrary text: the corrupt-store fixture.
# Fails loudly when the snapshot is missing, so a silently-created empty
# database can never make a corruption test pass vacuously.
corrupt_state_store() {
  local db
  db="$(state_db_path)" || return 1
  node --input-type=module -e '
    import { DatabaseSync } from "node:sqlite";
    const db = new DatabaseSync(process.argv[1]);
    const result = db.prepare("UPDATE run SET state_json = ?").run(process.argv[2]);
    db.close();
    if (Number(result.changes) !== 1) {
      throw new Error("corrupt_state_store: updated " + result.changes + " rows, expected 1");
    }
  ' "$db" "$1"
}

teardown_test_dir() {
  if [ -n "${TEST_DIR:-}" ]; then
    rm -rf "$TEST_DIR"
  fi
  if [ -n "${JJ_CONFIG:-}" ]; then
    rm -rf "$(dirname "$JJ_CONFIG")"
    unset JJ_CONFIG
  fi
  unset AGENCY_STATE_DIR

}
