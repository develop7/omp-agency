// Bundle entry for the adapter-level plugin tests. esbuild compiles this
// (and src/agency-tools.ts transitively) into .test-build/adapter.js; the
// external specifiers ../pure/dist/agency-api.js and
// ../nickel-vm/scripts/workflow-runtime.mjs stay verbatim and resolve
// relative to .test-build/ (one directory below the repo root).
import adapter from "../../src/agency-tools.ts";

export default adapter;