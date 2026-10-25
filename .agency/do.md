# /do config

All commands below self-route through the pinned Nix toolchain (PureScript,
Spago, esbuild, bats, shellcheck, actionlint, git, jj, Node.js, just — see
the root `flake.nix`); run them as-is from a bare host. Enter `nix develop`
only to get the tools on PATH directly. The flake's `pureScripts` output
supplies the CLI/API bundles, with compiled dependencies cached separately by `pureDependencies`;
`just build` installs them into `pure/dist/`. The Nickel WASM evaluator artifact
is produced by `nickelVmWasm`; `just nickel-build` installs it into `nickel-vm/dist/` (see `nickel-vm/README.md` for the
resolver-order patch).


## Format command

just fmt

## Check command

just lint

## Test command

just test

This repo's PureScript core tests are module-level unit tests under
`pure/test/Agency/Scripts/Do/`, mirroring the implementation modules under
`pure/src/Agency/Scripts/Do/` (for example, `Ops.purs` is covered by
`OpsTest.purs`). Resolve a coverage gap by comparing the `vcs_read` tool with
`{ op: "diff-names" }` (changed source files) against those mirrored test
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
