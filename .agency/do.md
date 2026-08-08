# /do config

## Check command
just lint

## Test command
just test

## Test coverage-gap resolution
This repo's tests run as subprocess-style black-box tests (bats) without coverage
instrumentation. Resolve the coverage-gap check from the `/do` test node by **path
intersection**: compare `bash .../skills/do/scripts/vcs-op diff-names <defaultBranch>`
(changed source files) against the test files' mirrored paths.

Test files live under `tests/` mirroring the repo-root `skills/` structure — a test at
`tests/unit/skills/do/scripts/do-results.bats` covers `skills/do/scripts/do-results`.
If at least one test file maps to a changed source file, the check is satisfied.

## CI command
just ci

## Documentation
README.md — keep the Development section in sync with the available just recipes.
