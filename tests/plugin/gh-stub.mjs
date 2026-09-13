#!/usr/bin/env node
// Test stub for the `gh` CLI: appends JSON.stringify(argv) (plus the
// --body-file content, so a test can assert it before the adapter deletes
// the temp dir) to $GH_LOG. Exits 1 with $GH_STDERR when $GH_FAIL is set.
// tests/plugin/plugin-surface.mjs copies this into the fixture's bin/.
const fs = require("node:fs");
const args = process.argv.slice(2);
fs.appendFileSync(process.env.GH_LOG, JSON.stringify(args) + "\n");
const i = args.indexOf("--body-file");
if (i !== -1) {
  fs.appendFileSync(process.env.GH_LOG, fs.readFileSync(args[i + 1], "utf8"));
}
if (process.env.GH_FAIL) {
  process.stderr.write(process.env.GH_STDERR || "boom\n");
  process.exit(1);
}