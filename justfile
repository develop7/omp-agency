repo := justfile_directory()

# Route every recipe through the pinned Nix toolchain. No-op inside the
# dev shell (`nix develop`), so recipes stay recursion-safe there.
nix_shell := if env('IN_NIX_SHELL', '') != '' { '' } else { 'nix develop ' + repo + ' --accept-flake-config -c' }

# Run all bats tests (unit + integration) and the typed tool boundary suite.
test: test-tools
    {{ nix_shell }} env REPO_ROOT={{ repo }} bats -r tests/

# Install the lockfile-pinned schema and renderer dependencies for all Node consumers.
node-deps:
    {{ nix_shell }} npm ci

# Build the extension with the pinned esbuild and run boundary tests against
# OMP's own zod builder (the @oh-my-pi/omptype facade, pinned to the OMP
# version) and the real API. npm ci is deterministic from the committed
# lockfile.
test-tools: build nickel-build node-deps
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

# Run the Nickel WASM VM unit tests in the artifact's build profile. Debug
# asserts stay out on purpose: nickel-lang-core 0.18.0's fixpoint debug_assert
# (value.is_constant() in eval/fixpoint.rs) misfires on open record-contract
# application in debug builds, while the shipped WASM is release and smoke
# verifies release semantics byte-for-byte.
test-vm:
    {{ nix_shell }} bash -c 'cd nickel-vm && cargo test --release'

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

# Build the CLI/API Nix output and install the Cachix-cacheable bundles.
# Keep the checkout's generated vocabulary current for TypeScript consumers too.
build: workflow-vocabulary
    @out=$(nix build {{ repo }}#pureScripts --print-out-paths --no-link) && \
      rm -rf pure/dist && \
      mkdir -p pure/dist && \
      cp -fr "$out/dist/." pure/dist/

# Full CI: bats + typed tool boundary + PureScript and VM unit tests + all quality gates.
ci: test test-pure test-vm lint lint-skills runtime-check

# Stage the minimal runtime package and verify it end-to-end: manifest paths,
# staged imports, catalog consistency (when --catalog is passed), and the
# Nickel workflow-contract smoke scenarios run against the staged runtime.
# Builds artifacts and installs renderer dependencies even in a clean checkout.
runtime-check out='dist-package': build nickel-build node-deps
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
