repo := justfile_directory()

# Route every recipe through the pinned Nix toolchain. No-op inside the
# dev shell (`nix develop`), so recipes stay recursion-safe there.
nix_shell := if env('IN_NIX_SHELL', '') != '' { '' } else { 'nix develop ' + repo + ' --accept-flake-config -c' }

# Run all bats tests (unit + integration). Bundle-level suites invoke the
# generated CLI/API artifacts, so build them first — source checkouts ship no
# dist files.
test: build nickel-build
    {{ nix_shell }} env REPO_ROOT={{ repo }} bats -r tests/

# Run unit tests only (black-box, no VCS fixtures). Builds first: some suites
# invoke the generated CLI artifact a clean checkout does not ship.
test-unit: build nickel-build
    {{ nix_shell }} env REPO_ROOT={{ repo }} bats -r tests/unit/

# Run integration tests (real git fixtures). Builds first for the same reason.
test-integration: build nickel-build
    {{ nix_shell }} env REPO_ROOT={{ repo }} bats -r tests/integration/

# Run the PureScript core unit tests
test-pure:
    {{ nix_shell }} bash -c 'cd pure && spago test -m Test.Main'

# Bundle the OMP extension adapter and the real omptype zod shim directly
# from their TypeScript sources into .test-build/ (never committed). The
# external specifiers ../pure/dist/agency-api.js and
# ../nickel-vm/scripts/workflow-runtime.mjs resolve relative to the output,
# so it must stay exactly one directory below the repo root; the post-build
# greps fail loudly if a flag change ever inlines them.
build-plugin-test:
    {{ nix_shell }} bash -c 'set -euo pipefail; \
      omptype="$(nix build --accept-flake-config --print-out-paths --no-link {{ repo }}#omptype)"; \
      mkdir -p .test-build; \
      esbuild "$omptype"/src/zod.ts --bundle --platform=node --format=esm \
        --outfile=.test-build/omptype-zod.mjs; \
      esbuild src/agency-tools.ts --bundle --platform=node --format=esm \
        --external:../pure/dist/agency-api.js --external:../nickel-vm/scripts/workflow-runtime.mjs \
        --outfile=.test-build/adapter.mjs; \
      grep -qF "../pure/dist/agency-api.js" .test-build/adapter.mjs; \
      grep -qF "../nickel-vm/scripts/workflow-runtime.mjs" .test-build/adapter.mjs'

# Run the adapter-level plugin tests (src/agency-tools.ts against the real
# agency-api.js backend and the real omptype zod shim).
test-plugin: build-plugin-test
    {{ nix_shell }} node tests/plugin/plugin-surface.mjs

# Run shellcheck on all bash scripts
# SC2148/SC1113/SC2096: scripts are intentionally shebang-less (run via `bash script`)
lint:
    {{ nix_shell }} bash -c 'find scripts tests/helpers \
        -type f \( -name "*.sh" -o -name "*.bash" \) \
        -exec shellcheck --shell=bash --exclude=SC2148,SC1113,SC2096 {} +'

# Lint skill markdown: no raw VCS/forge commands where the vcs_* / forge tools
# should be used. Scans the real skills/ tree, not test fixtures.
lint-skills:
    {{ nix_shell }} bash scripts/lint-vcs-refs.sh

# Generate vocabulary consumers from the sole workflow manifest.
workflow-vocabulary:
    {{ nix_shell }} node scripts/generate-workflow-vocabulary.mjs

# Build the PureScript core and bundle the CLI and tool API entrypoints.
# The pinned spago/purs/esbuild come from the dev shell.
build: workflow-vocabulary
    {{ nix_shell }} bash -c 'cd pure && spago build \
        && spago bundle --module Agency.Scripts.Do.Cli \
            --outfile dist/agency-do.js --force --platform node \
        && spago bundle --module Agency.Scripts.Do.Api \
            --outfile dist/agency-api.js --force --platform node --bundle-type=module'

# Full CI: bats + PureScript tests + lint + skill prose lint + runtime package
# proof (the proof includes the Nickel workflow-contract smoke goldens)
ci: test test-pure lint lint-skills runtime-check

# Stage the minimal runtime package and verify it end-to-end: manifest paths,
# staged imports, catalog consistency (when --catalog is passed), and the
# Nickel workflow-contract smoke goldens run against the staged runtime.
# Builds the generated artifacts first — a clean checkout ships none.
runtime-check out='dist-package': build nickel-build
    {{ nix_shell }} bash -c 'set -euo pipefail; \
      trap "rm -rf {{ out }}" EXIT; \
      node scripts/package-runtime.mjs --out {{ out }} --verify \
      && node nickel-vm/scripts/smoke.mjs'

# Full CI: bats + PureScript tests + lint + skill prose lint + bundle
# freshness, then the plugin surface tests (they consume the committed
# agency-api.js bundle, so they run after the drift guard).
ci: test test-pure lint lint-skills bundle-check test-plugin

# Build the Nickel WASM VM in a temporary directory and compare the fresh
# derivation output with the checked-in runtime artifact. Regeneration remains
# explicit: run nix build and copy the desired output into nickel-vm/dist/.
nickel-build:
    @out=$(nix build {{ repo }}#nickelVmWasm --print-out-paths --no-link); \
      rm -rf nickel-vm/dist; \
      mkdir -p nickel-vm/dist; \
      cp -fr "$out/dist/." nickel-vm/dist/