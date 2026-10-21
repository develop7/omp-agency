# agency-do-scripts

This directory contains the PureScript implementation of the `/do` operation
surface. The CLI and OMP custom-tool adapters share the same parsers, runners,
and the `OpOutcome` output seam.

## Modules

- `Agency.Scripts.Do.Sys` / `Sys.js` is the only FFI boundary. It owns Node
  subprocesses, inherited subprocess I/O, filesystem operations, environment,
  time, paths, argv, and process exit.
- `Agency.Scripts.Do.Binaries` names the external executables used by the
  runners, leaving one indirection point for future path overrides,
  instrumentation, or test fakes.
- `State` is the Argonaut JSON codec for `.do-results.json`. Known workflow
  fields are typed; every unknown field is retained as JSON in `extras` and is
  emitted again on save.
- `Vcs` implements the git and jj semantic operation strategies and context
  fallback rules. `head-revision`/`current-branch` read the checked-out
  branch or bookmark (empty when none is checked out); `head-commit-sha` is
  the CI-target identity — under jj, the feature bookmark's commit, falling
  back to the parent commit when no bookmark exists, and failing loudly when
  no revision is resolvable.
- `Forge` classifies remotes and owns forge capability checks and `gh`
  dispatch.
- `Ops` defines the command algebras, parsers, runners, sync orchestration,
  and done-summary formatting without direct process or filesystem calls.
- `Cli` is the Node CLI adapter. It dispatches `argv[0]` to the legacy
  operation entrypoints used by the bundled CLI and test harness.
- `Api` is the Node-facing OMP tool adapter. `runTool` resolves
  `WorkflowContext`, requests captured output, and returns
  `{ exit, stdout, stderr, value }` to `src/agency-tools.ts`; it does not
  duplicate the operation runners. `value` is semantic JSON, or null for prose
  and failures. The workflow tool invokes the shared Node evaluator directly.
- `Outcome` keeps semantic values alongside CLI stream output. `withValue`
  attaches values only to successful outcomes; `append` combines streams and
  drops intermediate values, so composite operations declare their own result.
- `State` owns the canonical state, step, and job JSON encoders used both for
  persistence and result data; result producers do not serialize and reparse
  state to recover structure.

Sync policy is represented by two explicit VCS operations:

- `refresh-default-branch`: git runs `git remote set-head origin --auto`; jj
  is a no-op.
- `fast-forward-if-safe`: git pulls with `--ff-only` only when the current
  branch is behind and not ahead; jj is a no-op.

## Build, bundle, and test

From this directory, `just build` builds the `pureScripts` Nix output and
installs its CLI/API bundles into `pure/dist/` at the repository root.
`nix build .#pureScripts --no-link` from the root builds the same output without
installing it into the checkout. The `pureDependencies` Nix output compiles
dependencies separately, so application edits reuse that output through Cachix.
Both derivations use the pinned toolchain and committed `spago.lock`; commit
lockfile updates after changing dependencies. The bundle build regenerates
workflow vocabulary from its manifest inside the sandbox.

`just test-pure` still runs the interactive Spago test workflow through
`nix develop`. For direct workspace builds, enter the dev shell and run these
commands from `pure/` (the resulting `.spago/`, `output/`, and `dist/` remain
local workspace state, not Cachix outputs):

```sh
spago build
spago bundle --module Agency.Scripts.Do.Cli \
  --outfile dist/agency-do.js --force --platform node
spago bundle --module Agency.Scripts.Do.Api \
  --outfile dist/agency-api.js --force --platform node --bundle-type=module
spago test -m Test.Main
```

The CLI contract is one bundle: invoke it with Node and put the script name in
`argv[0]`, followed by that script's arguments. For example:

```sh
node pure/dist/agency-do.js vcs-op detect
node pure/dist/agency-do.js do-results init
```

The OMP custom-tool contract is the second ES module bundle. `src/agency-tools.ts`
lazily imports `pure/dist/agency-api.js`, sends `{ tool, args, captureOutput: true }`,
and turns the returned output into the model-visible tool result. `just build`
regenerates both bundles; they are build outputs and are not committed.

