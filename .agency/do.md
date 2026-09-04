# /do config

All commands below run under the pinned toolchain: enter `nix develop` first
(PureScript, Spago, esbuild, bats, Rust, wasm-bindgen, Node.js, just — see the
root `flake.nix`). The `/do` workflow's check/test/ci gates assume the dev
shell is active; on a bare host the `just` recipes fail with missing `purs`/
`spago`. The Nickel WASM evaluator artifact is produced by the flake's
`nickelVmWasm` derivation and checked by `just nickel-build`'s freshness gate
(see `nickel-vm/README.md` for the resolver-order patch it carries).

## Check command
just lint

## Test coverage-gap resolution
This repo's PureScript core tests are module-level unit tests under
`pure/test/Agency/Scripts/Do/`, mirroring the implementation modules under
`pure/src/Agency/Scripts/Do/` (for example, `Ops.purs` is covered by
`OpsTest.purs`). Resolve a coverage gap by comparing the `vcs_read` tool with
`{ args: ["diff-names"] }` (changed source files) against those mirrored test
paths. The `tests/` bats suites provide bundle-level black-box coverage for the
CLI and should also be considered when a source change affects a bundled
entrypoint.

Test files under `tests/` still mirror the repo-root `skills/` structure; use the
matching `tests/unit/skills/do/` or `tests/integration/skills/do/` suite for
workflow behavior.

## CI command
just ci

## Documentation
README.md — keep the Development section in sync with the available just recipes.
