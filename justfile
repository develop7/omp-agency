repo := justfile_directory()

# Route every recipe through the pinned Nix toolchain. No-op inside the
# dev shell (`nix develop`), so recipes stay recursion-safe there.
nix_shell := if env('IN_NIX_SHELL', '') != '' { '' } else { 'nix develop ' + repo + ' --accept-flake-config -c' }

# Run all bats tests (unit + integration) and the typed tool boundary suite.
test: test-tools
    {{ nix_shell }} env REPO_ROOT={{ repo }} bats -r tests/

# Build the extension with the pinned esbuild and run real-Zod/real-API
# boundary tests. npm ci is deterministic from the committed lockfile.
test-tools: build nickel-build
    {{ nix_shell }} npm ci
    {{ nix_shell }} esbuild src/agency-tools.ts --bundle --format=esm --platform=node --packages=external --external:../pure/dist/agency-api.js --external:../nickel-vm/scripts/workflow-runtime.mjs --outfile=dist/agency-tools.mjs
    {{ nix_shell }} npm run test:tools

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

# Full CI: bats + typed tool boundary + PureScript tests + all quality gates.
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

# Build the Nickel WASM VM with the pinned toolchain and install it into
# nickel-vm/dist/ (the generated runtime artifact; no longer checked in).
nickel-build:
    @out=$(nix build {{ repo }}#nickelVmWasm --print-out-paths --no-link); \
      rm -rf nickel-vm/dist; \
      mkdir -p nickel-vm/dist; \
      cp -fr "$out/dist/." nickel-vm/dist/
