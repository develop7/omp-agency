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

# Generate vocabulary consumers from the sole workflow manifest.
workflow-vocabulary:
    node scripts/generate-workflow-vocabulary.mjs

# Reject generated vocabulary consumers that no longer match the manifest.
workflow-vocabulary-check:
    node scripts/generate-workflow-vocabulary.mjs --check

# Build the PureScript core and bundle the CLI and tool API entrypoints
# (requires purs 0.15.x and spago — dev-only toolchain)
build: workflow-vocabulary
    cd pure && spago build
    cd pure && spago bundle --module Agency.Scripts.Do.Cli \
        --outfile dist/agency-do.js --force --platform node
    cd pure && spago bundle --module Agency.Scripts.Do.Api \
        --outfile dist/agency-api.js --force --platform node --bundle-type=module

# Verify the checked-in bundle matches the sources (drift guard for the
# distributed artifact — the bundle IS the distributable, so it must
# never go stale silently)
bundle-check: workflow-vocabulary-check nickel-build
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

# Build the Nickel WASM VM in a temporary directory and compare the fresh
# derivation output with the checked-in runtime artifact. Regeneration remains
# explicit: run nix build and copy the desired output into nickel-vm/dist/.
nickel-build:
    @tmp=$(mktemp --directory); trap 'rm -rf "$tmp"' EXIT; \
      out=$(nix build {{ repo }}#nickelVmWasm --print-out-paths --no-link); \
      cp -fr "$out/dist/." "$tmp/"; \
      just nickel-check "$tmp"

# Compare a fresh pinned Nickel WASM build with the checked-in runtime files.
nickel-check fresh:
    @for file in nickel_vm_bg.wasm nickel_vm_bg.wasm.d.ts nickel_vm.d.ts nickel_vm.js; do \
      if ! cmp -- "{{ fresh }}/$file" "nickel-vm/dist/$file"; then \
        echo "Nickel WASM drift: nickel-vm/dist/$file is stale — regenerate it explicitly and commit it"; \
        exit 1; \
      fi; \
    done