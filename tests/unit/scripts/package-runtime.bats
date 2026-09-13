#!/usr/bin/env bats
# Unit tests for scripts/package-runtime.mjs — the runtime packager.
#
# Tests the observable contract: staging the runtime closure from the real
# build tree, catalog generation (typed GitHub source pinned to the
# distribution tag + commit, per-plugin version, Pages URL install command),
# and verification failure paths (missing staged import, catalog mismatch).

setup() {
  load "$REPO_ROOT/tests/helpers/setup.bash"
  setup_test_dir
  PACKAGE="$(repo_script scripts/package-runtime.mjs)"
  OUT="$TEST_DIR/package"
}

teardown() {
  teardown_test_dir
}

@test "stages the runtime closure and verifies it" {
  run node "$PACKAGE" --out "$OUT/package" --verify
  [ "$status" -eq 0 ]
  [[ "$output" == *"import-bearing files verified"* ]]
  [ -f "$OUT/package/package.json" ]
  [ -f "$OUT/package/src/agency-tools.ts" ]
  [ -f "$OUT/package/pure/dist/agency-api.js" ]
  [ -f "$OUT/package/nickel-vm/dist/nickel_vm.js" ]
  [ -f "$OUT/package/nickel-vm/dist/nickel_vm_bg.wasm" ]
  [ -f "$OUT/package/nickel-vm/scripts/workflow-runtime.mjs" ]
  [ -f "$OUT/package/skills/do/SKILL.md" ]
  [ -f "$OUT/package/agents/hickey.md" ]
}

@test "staged manifest declares the extension entry point that exists" {
  run node "$PACKAGE" --out "$OUT/package" --verify
  [ "$status" -eq 0 ]
  run node -e '
    const fs = require("fs");
    const pkg = JSON.parse(fs.readFileSync(process.argv[1] + "/package.json", "utf8"));
    const ext = pkg.omp?.extensions?.[0];
    process.exit(fs.existsSync(process.argv[1] + "/" + ext) ? 0 : 1);
  ' "$OUT/package"
  [ "$status" -eq 0 ]
}

@test "staged tree omits non-runtime payload" {
  run node "$PACKAGE" --out "$OUT/package"
  [ "$status" -eq 0 ]
  [ ! -f "$OUT/package/pure/dist/agency-do.js" ]
  [ ! -d "$OUT/package/pure/src" ]
  [ ! -d "$OUT/package/nickel-vm/src" ]
  [ ! -f "$OUT/package/justfile" ]
  [ ! -f "$OUT/package/flake.nix" ]
  [ ! -d "$OUT/package/tests" ]
}

@test "catalog generation pins typed github source to tag + sha with version" {
  run node "$PACKAGE" --out "$OUT/package" \
    --catalog develop7/omp-agency dist-test 1234567890abcdef1234567890abcdef12345678 v9.9.9-test --verify
  [ "$status" -eq 0 ]
  run node -e '
    const fs = require("fs");
    const catalog = JSON.parse(fs.readFileSync(process.argv[1] + "/.omp-plugin/marketplace.json", "utf8"));
    const entry = catalog.plugins[0];
    const src = entry.source;
    const bad =
      typeof src === "string" ||
      src.source !== "github" ||
      src.repo !== "develop7/omp-agency" ||
      src.ref !== "dist-test" ||
      src.sha !== "1234567890abcdef1234567890abcdef12345678" ||
      entry.version !== "v9.9.9-test";
    process.exit(bad ? 1 : 0);
  ' "$OUT/package"
  [ "$status" -eq 0 ]
}

@test "pages site contains catalog link, URL-based add command, and tag ref" {
  run node "$PACKAGE" --out "$OUT/package" \
    --catalog develop7/omp-agency dist-test 1234567890abcdef1234567890abcdef12345678 v9.9.9-test
  [ "$status" -eq 0 ]
  run node -e '
    const fs = require("fs");
    const html = fs.readFileSync(process.argv[1] + "/marketplace/index.html", "utf8");
    const ok =
      html.includes("\"./marketplace.json\"") &&
      html.includes("omp plugin marketplace add https://develop7.github.io/omp-agency/marketplace.json") &&
      html.includes("omp plugin install agency@omp-agency") &&
      html.includes("dist-test");
    process.exit(ok ? 0 : 1);
  ' "$OUT/package"
  [ "$status" -eq 0 ]
  # Pages catalog is byte-identical to the distribution catalog
  cmp -s "$OUT/package/.omp-plugin/marketplace.json" "$OUT/package/marketplace/marketplace.json"
}

@test "catalog rejects a sha that is not a git object id" {
  run node "$PACKAGE" --out "$OUT/package" \
    --catalog develop7/omp-agency dist-test nothex v9.9.9-test
  [ "$status" -eq 1 ]
  [[ "$output" == *"invalid catalog sha"* ]]
}

@test "staged tree excludes tests, test sources, and build-only payload" {
  run node "$PACKAGE" --out "$OUT/package"
  [ "$status" -eq 0 ]
  [ ! -d "$OUT/package/tests" ]
  [ ! -f "$OUT/package/tests/unit/scripts/package-runtime.bats" ]
  [ ! -d "$OUT/package/pure/test" ]
  [ ! -f "$OUT/package/pure/test/Main.purs" ]
  [ ! -f "$OUT/package/nickel-vm/scripts/smoke.mjs" ]
  [ ! -f "$OUT/package/nickel-vm/scripts/cli-bridge.mjs" ]
  [ ! -d "$OUT/package/nickel-vm/src" ]
  [ ! -f "$OUT/package/nickel-vm/Cargo.toml" ]
  [ ! -f "$OUT/package/nickel-vm/Cargo.lock" ]
  [ ! -f "$OUT/package/package.json.bak" ]
  [ ! -d "$OUT/package/.github" ]
  [ ! -d "$OUT/package/scripts" ]
  [ ! -f "$OUT/package/.gitignore" ]
  [ ! -f "$OUT/package/.omp-plugin/marketplace.json" ]
}

@test "catalog rejects a version with path-traversal dots" {
  run node "$PACKAGE" --out "$OUT/package" \
    --catalog develop7/omp-agency dist-test 1234567890abcdef1234567890abcdef12345678 "v1..2"
  [ "$status" -eq 1 ]
  [[ "$output" == *"invalid catalog version"* ]]
}

@test "verify fails when a staged relative import cannot resolve" {
  run node "$PACKAGE" --out "$OUT/package" --verify
  [ "$status" -eq 0 ]
  # Break a staged import, then verify the existing tree without re-staging.
  rm "$OUT/package/src/workflow-vocabulary.ts"
  run node "$PACKAGE" --out "$OUT/package" --verify --no-stage
  [ "$status" -eq 1 ]
  [[ "$output" == *"imports missing"* ]]
}

@test "verify fails when the manifest declares a missing extension" {
  run node "$PACKAGE" --out "$OUT/package" --verify
  [ "$status" -eq 0 ]
  run node -e '
    const fs = require("fs");
    const path = process.argv[1] + "/package.json";
    const pkg = JSON.parse(fs.readFileSync(path, "utf8"));
    pkg.omp.extensions = ["./src/does-not-exist.ts"];
    fs.writeFileSync(path, JSON.stringify(pkg));
  ' "$OUT/package"
  run node "$PACKAGE" --out "$OUT/package" --verify --no-stage
  [ "$status" -eq 1 ]
  [[ "$output" == *"declares missing extension"* ]]
}