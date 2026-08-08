repo := justfile_directory()

mod website "website/mod.just"

# Run all bats tests (unit + integration)
test:
    REPO_ROOT={{ repo }} bats -r tests/

# Run unit tests only (black-box, no VCS fixtures)
test-unit:
    REPO_ROOT={{ repo }} bats -r tests/unit/

# Run integration tests (real git fixtures)
test-integration:
    REPO_ROOT={{ repo }} bats -r tests/integration/

# Run shellcheck on all bash scripts
# SC2148/SC1113/SC2096: scripts are intentionally shebang-less (run via `bash script`)
# SC1091: scripts source lib/state.sh via a runtime $SCRIPT_DIR path shellcheck can't follow statically
lint:
    find scripts skills/do/scripts tests/helpers \
        -type f ! -name '*.ncl' \
        -exec shellcheck --shell=bash --exclude=SC2148,SC1113,SC2096,SC1091 {} +

# Full CI: tests + lint
ci: test lint