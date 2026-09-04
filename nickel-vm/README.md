# nickel-vm

`nickel-vm` is the in-process Nickel evaluator used by Agency's `/do` workflow. It is compiled to WebAssembly and loaded by Node.js through the generated `wasm-bindgen` glue. Both the OMP workflow tool and the PureScript CLI use this one evaluator; neither starts a system `nickel` executable.

## Evaluation seam

The public `eval_workflow` function accepts the workflow source, `.do-results.json` source, operation (`cli` or `cli_seed`), and optional seed. It registers one in-memory `main.ncl` invocation and injects `workflow.ncl`, `.do-results.json`, and `seed.json` into Nickel's source cache as `SourcePath::Path` entries. The invocation imports them through Nickel's `%inmem_src%:` seam, so no temporary files or working-directory imports are needed. Seed values are serialized with `serde_json` as JSON strings in the in-memory `seed.json` document before Nickel evaluates the request.

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

The generated files in `dist/` are checked in because they are the runtime plugin artifact. `Cargo.lock` pins the dependency graph, including `wasm-bindgen = 0.2.127`, which must match the `wasm-bindgen-cli` used by the Nix development shell.

```bash
just nickel-build
node nickel-vm/scripts/smoke.mjs
```

The smoke test evaluates the three deterministic examples documented in `skills/do/workflow.ncl`: `cli` on `_test_state`, `cli_seed ""`, and `cli_seed "followup"`. It compares each rendered result byte-for-byte with the documented golden output.

