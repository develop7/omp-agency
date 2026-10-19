# nickel-vm

`nickel-vm` is the in-process Nickel evaluator used by Agency's `/do` workflow. It is compiled to WebAssembly and loaded by Node.js through the generated `wasm-bindgen` glue. Both the OMP workflow tool and the PureScript CLI use the same Node runtime adapter; neither starts a system `nickel` executable.

## Workflow runtime

`scripts/workflow-runtime.mjs` exports `evaluateWorkflow({ operation: "cli", cwd? } | { operation: "cli_seed", seed: string, cwd? })`, which returns `{ exit, stdout, stderr, value }`. On success, `value` is the validated parsed JSON object or array from Nickel; on failure it is `null`. `stdout` remains the existing human-readable Nickel rendering for CLI users. The runtime is the only Node implementation that loads the WASM glue, discovers workflow assets, reads `.do-results.json`, constructs the evaluator request, validates the JSON evaluator wire, preserves its semantic value, renders legacy Nickel text, and converts failures to that result protocol. It loads `skills/do` assets packaged beside the runtime first, then falls back to `<cwd>/skills/do`; state is always `<cwd>/.do-results.json`. The CLI bridge frames the complete result envelope over stdin/stdout, while the OMP extension invokes the runtime directly.

## Evaluation seam

The WASM-level `eval_workflow` function accepts the workflow source, workflow vocabulary manifest, `.do-results.json` source, and a discriminated operation (`cli` with no seed or `cli_seed` with a required string seed). The shared Node runtime supplies those sources after discovery. It registers one in-memory `main.ncl` invocation and injects `workflow.ncl`, `workflow-manifest.json`, and `.do-results.json` into Nickel's source cache, plus `seed.json` for `cli_seed`. The invocation imports them through Nickel's `%inmem_src%:` seam, so no temporary files or working-directory imports are needed. On success, the WASM evaluator returns the workflow result as JSON text; the runtime parses it once, validates its operation-specific shape, returns the parsed JSON in `value`, and renders the existing Nickel-text `stdout` for CLI consumers. Seed values are serialized as JSON strings rather than interpolated into Nickel source.

The evaluator intentionally uses the single-input path: merging multiple input documents would change the workflow/state contract by merging state fields into the workflow record.

The crate consumes nickel-lang-core 0.18.0 from crates.io with **one patch**
(`patches/nickel-lang-core-0.18.0-cache-resolver.patch`): the published crate
runs `normalize_path` before checking the `%inmem_src%:` in-memory source
cache, and `normalize_path` asks the OS for a current directory — unsupported
on wasm32-unknown-unknown. The patch moves the in-memory lookup ahead of the
normalize call. This is the patch's upstreaming candidate; until upstream
accepts it, the flake applies it at build time via a `patchedNickelCore`
derivation (fetchCrate + patch), which the wasm build consumes through
`[patch.crates-io]`. `Cargo.lock` pins the full dependency graph; bumping
the core version requires re-verifying semantic-value smoke assertions.

## Build and smoke test

`just nickel-build` self-routes through the pinned Nix toolchain, so it works from a bare
host. Enter `nix develop` before running the smoke test directly to use the exact Node.js
and wasm-bindgen the artifact was built with.

The generated files in `dist/` are build outputs, not source — `just
nickel-build` installs a fresh build there and the tree is gitignored.
`Cargo.lock` pins the dependency graph, including `wasm-bindgen = 0.2.127`,
which must match the `wasm-bindgen-cli` used by the Nix development shell.

```bash
just nickel-build
nix develop
node nickel-vm/scripts/smoke.mjs
```

For one-off invocations outside the dev shell, pin the interpreter the same
way: `nix develop --command node nickel-vm/scripts/smoke.mjs`.

The smoke test checks semantic `cli` objects, `cli_seed` arrays, terminal `{ done: true }`, failure `null` values, contradictory operation-and-seed rejection, unknown nonempty `cli_seed` entry-point rejection, and actionable missing-state errors. It intentionally does not pin incidental Nickel text formatting.

