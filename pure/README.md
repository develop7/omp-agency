# agency-do-scripts

This directory contains the PureScript implementation of the `/do` script
surface. The shell scripts remain in `skills/do/scripts` during the migration,
but the test adapter uses one bundled Node entrypoint.

## Modules

- `Agency.Scripts.Do.Sys` / `Sys.js` is the only FFI boundary. It owns Node
  subprocesses, inherited subprocess I/O, filesystem operations, environment,
  time, paths, argv, and process exit.
- `State` is the Argonaut JSON codec for `.do-results.json`. Known workflow
  fields are typed; every unknown field is retained as JSON in `extras` and is
  emitted again on save.
- `Vcs` implements the git and jj semantic operation strategies and context
  fallback rules.
- `Forge` classifies remotes and owns forge capability checks and `gh`
  dispatch.
- `Ops` defines the command algebras, parsers, runners, sync orchestration,
  and done-summary formatting without direct process or filesystem calls.
- `Cli` is the Node CLI adapter. It dispatches `argv[0]` to `vcs-op`,
  `forge-op`, `do-results`, `do-driver`, `sync`, `done`, or `nickel-cli`.

Sync policy is represented by two explicit VCS operations:

- `refresh-default-branch`: git runs `git remote set-head origin --auto`; jj
  is a no-op.
- `fast-forward-if-safe`: git pulls with `--ff-only` only when the current
  branch is behind and not ahead; jj is a no-op.

## Build, bundle, and test

From this directory:

```sh
spago build
spago bundle --module Agency.Scripts.Do.Cli \
  --outfile dist/agency-do.js --force --platform node
spago test -m Test.Main
```

The CLI contract is one bundle: invoke it with Node and put the script name in
`argv[0]`, followed by that script's arguments. For example:

```sh
node pure/dist/agency-do.js vcs-op detect
node pure/dist/agency-do.js do-results init
```
