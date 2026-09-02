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

# Build the PureScript core and bundle the CLI entrypoint
# (requires purs 0.15.x and spago — dev-only toolchain)
build:
    cd pure && spago build
    cd pure && spago bundle --module Agency.Scripts.Do.Cli \
        --outfile dist/agency-do.js --force --platform node

# Verify the checked-in bundle matches the sources (drift guard for the
# distributed artifact — the bundle IS the distributable, so it must
# never go stale silently)
bundle-check: build
    @cd pure && spago bundle --module Agency.Scripts.Do.Cli \
        --outfile dist/agency-do.check.js --force --platform node
    @cmp pure/dist/agency-do.check.js pure/dist/agency-do.js \
        || { echo "bundle drift: pure/dist/agency-do.js is stale — run 'just build' and commit it"; exit 1; }
    @rm pure/dist/agency-do.check.js

# Full CI: tests + lint + bundle freshness
ci: test lint bundle-check