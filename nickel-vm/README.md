# nickel-vm

`nickel-vm` is the in-process Nickel evaluator used by Agency's `/do` workflow. It is compiled to WebAssembly and loaded by Node.js through the generated `wasm-bindgen` glue. Both the OMP workflow tool and the PureScript CLI use the same Node runtime adapter; neither starts a system `nickel` executable.

## Workflow runtime

`scripts/workflow-runtime.mjs` exports `evaluateWorkflow({ operation, seed?, cwd? })`, which returns `{ exit, stdout, stderr }`. It is the only Node implementation that loads the WASM glue, discovers workflow assets, reads `.do-results.json`, constructs the evaluator request, validates the JSON evaluator wire, renders the public legacy Nickel text, and converts failures to that result protocol. It loads `skills/do` assets packaged beside the runtime first, then falls back to `<cwd>/skills/do`; state is always `<cwd>/.do-results.json`. The CLI bridge only frames stdin/stdout around this primitive, while the OMP extension invokes it directly.

## Evaluation seam

The WASM-level `eval_workflow` function accepts the workflow source, workflow vocabulary manifest, `.do-results.json` source, operation (`cli` or `cli_seed`), and optional seed. The shared Node runtime supplies those sources after discovery. It registers one in-memory `main.ncl` invocation and injects `workflow.ncl`, `workflow-manifest.json`, `.do-results.json`, and `seed.json` into Nickel's source cache as `SourcePath::Path` entries. The invocation imports them through Nickel's `%inmem_src%:` seam, so no temporary files or working-directory imports are needed. On success, the WASM evaluator returns the workflow result as JSON text; the runtime validates its operation-specific shape and renders the existing Nickel-text `stdout` contract. Seed values are serialized with `serde_json` as JSON strings in the in-memory `seed.json` document before Nickel evaluates the request.

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
the core version requires re-verifying the smoke goldens.

## Build and smoke test

Run inside the pinned toolchain: `nix develop` first (it provides the exact
Node.js and wasm-bindgen the artifact was built with).

The generated files in `dist/` are checked in because they are the runtime plugin artifact. `Cargo.lock` pins the dependency graph, including `wasm-bindgen = 0.2.127`, which must match the `wasm-bindgen-cli` used by the Nix development shell.

```bash
nix develop
just nickel-build
node nickel-vm/scripts/smoke.mjs
```

For one-off invocations outside the dev shell, pin the interpreter the same
way: `nix develop --command node nickel-vm/scripts/smoke.mjs`.

The smoke test compares the documented valid `cli` and `cli_seed` results byte-for-byte through the shared runtime, verifies that an unknown nonempty `cli_seed` entry point is rejected, and checks that a missing state file reports the initialization action.

