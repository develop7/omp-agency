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
lint:
    find scripts tests/helpers \
        -type f ! -name '*.ncl' \
        -exec shellcheck --shell=bash --exclude=SC2148,SC1113,SC2096 {} +

# Build the PureScript core and bundle the CLI and tool API entrypoints
# (requires purs 0.15.x and spago — dev-only toolchain)
build:
    cd pure && spago build
    cd pure && spago bundle --module Agency.Scripts.Do.Cli \
        --outfile dist/agency-do.js --force --platform node
    cd pure && spago bundle --module Agency.Scripts.Do.Api \
        --outfile dist/agency-api.js --force --platform node --bundle-type=module

# Verify the checked-in bundle matches the sources (drift guard for the
# distributed artifact — the bundle IS the distributable, so it must
# never go stale silently)
bundle-check: nickel-build build
    @cd pure && spago bundle --module Agency.Scripts.Do.Cli \
        --outfile dist/agency-do.check.js --force --platform node
    @cd pure && spago bundle --module Agency.Scripts.Do.Api \
        --outfile dist/agency-api.check.js --force --platform node --bundle-type=module
    @cmp pure/dist/agency-do.check.js pure/dist/agency-do.js \
        || { echo "bundle drift: pure/dist/agency-do.js is stale — run 'just build' and commit it"; exit 1; }
    @cmp pure/dist/agency-api.check.js pure/dist/agency-api.js \
        || { echo "bundle drift: pure/dist/agency-api.js is stale — run 'just build' and commit it"; exit 1; }
    @rm pure/dist/agency-do.check.js pure/dist/agency-api.check.js
    @node nickel-vm/scripts/smoke.mjs

# Full CI: tests + lint + bundle freshness
ci: test lint bundle-check

# Build the Nickel WASM VM from the nix derivation (wasm + glue are both
# produced inside nix by the pinned toolchain and wasm-bindgen-cli — the
# checked-in dist/ is a copy of the derivation output, never host-built).
nickel-build:
    nix build {{ repo }}#nickelVmWasm --print-out-paths --no-link \
        | xargs -I{} cp -fr {}/dist/. nickel-vm/dist/