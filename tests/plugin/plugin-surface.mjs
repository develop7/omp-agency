// Adapter-level tests for the OMP plugin surface (src/agency-tools.ts).
//
// Loads the esbuild-bundled adapter (just build-plugin-test) with the REAL
// omptype zod shim OMP injects as `pi.zod`, registers the five agency
// tools against a mock ExtensionAPI, and drives their execute() handlers
// end-to-end through the lazily imported pure/dist/agency-api.js backend.
// Backend semantics live in the bats suites and the PureScript tests; here
// we prove registration, schema validation, adapter arg mapping, backend
// wiring, and the forge body lifecycle.
//
// Run via `just test-plugin`. Structure follows nickel-vm/scripts/smoke.mjs.
import fs from "node:fs";
import { test } from "node:test";
import assert from "node:assert/strict";
import os from "node:os";
import path from "node:path";
import { execFileSync } from "node:child_process";
import { fileURLToPath } from "node:url";
import { TEST_STATE } from "../fixtures/do-state.mjs";

const buildDir = path.join(path.dirname(fileURLToPath(import.meta.url)), "..", "..", ".test-build");
const [{ default: adapter }, { z }] = await Promise.all([
  import(path.join(buildDir, "adapter.mjs")),
  import(path.join(buildDir, "omptype-zod.mjs")),
]);

const tools = new Map();
const pi = {
  zod: z,
  registerTool: (tool) => tools.set(tool.name, tool),
};
adapter(pi);

// Minimal git fixture: init, identity, one commit on master.
function gitFixture(fixture) {
  const run = (args) => execFileSync("git", args, { cwd: fixture, stdio: "pipe" });
  run(["init", "-q", "-b", "master"]);
  run(["config", "user.email", "agency-plugin-test@example.com"]);
  run(["config", "user.name", "Agency Plugin Test"]);
  fs.writeFileSync(path.join(fixture, "README.md"), "fixture\n");
  run(["add", "README.md"]);
  run(["commit", "-q", "-m", "initial"]);
}

// Executable gh stub: appends JSON.stringify(argv) (+ the --body-file
// content, so the test can assert it before the adapter deletes the temp
// dir) to GH_LOG. Exits 1 with GH_STDERR when GH_FAIL is set.
const GH_STUB = [
  "#!/usr/bin/env node",
  'const fs = require("node:fs");',
  "const args = process.argv.slice(2);",
  'fs.appendFileSync(process.env.GH_LOG, JSON.stringify(args) + "\\n");',
  'const i = args.indexOf("--body-file");',
  "if (i !== -1) {",
  '  fs.appendFileSync(process.env.GH_LOG, fs.readFileSync(args[i + 1], "utf8"));',
  "}",
  "if (process.env.GH_FAIL) {",
  '  process.stderr.write(process.env.GH_STDERR || "boom\\n");',
  "  process.exit(1);",
  "}",
  "",
].join("\n");

function writeGhStub(fixture) {
  const bin = path.join(fixture, "bin");
  fs.mkdirSync(bin);
  const gh = path.join(bin, "gh");
  fs.writeFileSync(gh, GH_STUB);
  fs.chmodSync(gh, 0o755);
  return bin;
}

// Runs one tool call against a fresh mkdtemp fixture: chdir (the backend
// reads the process cwd), apply opts.env before the call, then ALWAYS
// restore cwd and env and remove the fixture unless opts.keep. setup
// prepares the fixture and returns a bin dir to prepend to PATH (or
// nothing for schema/backend-only cases).
async function execTool(name, params, opts = {}) {
  const fixture = fs.mkdtempSync(path.join(os.tmpdir(), "agency-plugin-"));
  const savedCwd = process.cwd();
  const savedEnv = {};
  const savedPath = process.env.PATH;
  let before;
  try {
    const bin = opts.setup ? opts.setup(fixture) : undefined;
    before = fixtureListing(fixture);
    if (opts.env) {
      for (const [key, value] of Object.entries(opts.env)) {
        savedEnv[key] = process.env[key];
        process.env[key] = value;
      }
    }
    if (bin) process.env.PATH = bin + path.delimiter + savedPath;
    process.chdir(fixture);
    const tool = tools.get(name);
    const result = await tool.execute("test-call", params, undefined, undefined, { cwd: fixture });
    return { result, error: undefined, fixture, before };
  } catch (error) {
    return { error, result: undefined, fixture, before };
  } finally {
    process.chdir(savedCwd);
    for (const key of Object.keys(savedEnv)) {
      if (savedEnv[key] === undefined) delete process.env[key];
      else process.env[key] = savedEnv[key];
    }
    process.env.PATH = savedPath;
    if (!opts.keep) fs.rmSync(fixture, { recursive: true, force: true });
  }
}

// Sorted fixture-root listing, comma-joined: comparing before/after
// snapshots catches ANY leaked artifact, not just ones with a known name.
function fixtureListing(fixture) {
  return fs.readdirSync(fixture).sort().join(",");
}


test("registration", async () => {
assert.equal([...tools.keys()].sort().join(","), "agency_driver,forge,vcs_read,vcs_write,workflow", "registers exactly the five agency tools");
assert.equal(["vcs_read", "vcs_write", "forge", "workflow", "agency_driver"]
    .map((name) => tools.get(name).label)
    .join(","), "VCS Read,VCS Write,Forge,Workflow,Agency Driver", "tools carry labels");
assert.equal([...tools.values()].every((tool) => typeof tool.parameters?.safeParse === "function"), true, "every tool exposes a safeParse schema");
});

test("vcs_write schema", async () => {
const vcsWrite = tools.get("vcs_write").parameters;
assert.equal(vcsWrite.safeParse({ op: "commit", message: "m", files: [] }).success, false, "vcs_write rejects commit with empty files");
assert.equal(vcsWrite.safeParse({ op: "commit", message: "m", files: ["a"], ref: "x" }).success, false, "vcs_write rejects commit with a stray ref");
assert.equal(vcsWrite.safeParse({ op: "commit", message: "m" }).success, false, "vcs_write rejects commit without files");
assert.equal(vcsWrite.safeParse({ op: "branch", name: "n", files: ["x"] }).success, false, "vcs_write rejects branch with files");
assert.equal(vcsWrite.safeParse({ op: "commit", message: "m", files: ["a"] }).success, true, "vcs_write accepts commit with message and files");
});

test("forge schema", async () => {
const forge = tools.get("forge").parameters;
assert.equal(forge.safeParse({ op: "pr-view", args: [], body: "x" }).success, false, "forge rejects body on pr-view");
assert.equal(forge.safeParse({ op: "pr-create", args: [], body: "x" }).success, true, "forge accepts body on pr-create");
});

test("agency_driver schema", async () => {
const agencyDriver = tools.get("agency_driver").parameters;
assert.equal(agencyDriver.safeParse({ op: "nonsense", args: [] }).success, false, "agency_driver rejects an unknown op");
assert.equal(agencyDriver.safeParse({ op: "sync", args: [] }).success, true, "agency_driver accepts sync");
});

test("workflow schema", async () => {
const workflow = tools.get("workflow").parameters;
assert.equal(workflow.safeParse({ field: "cli", from: "default" }).success, false, "workflow rejects from on cli");
assert.equal(workflow.safeParse({ field: "cli_seed", from: "not-a-step" }).success, false, "workflow rejects an undeclared entry point");
assert.equal(workflow.safeParse({ field: "cli_seed", from: "default" }).success, true, "workflow accepts cli_seed from default");
});

test("adapter ↔ backend wiring (one round-trip through agency-api.js)", async () => {
const detect = await execTool("vcs_read", { args: ["detect"] }, { setup: gitFixture });
assert.equal(detect.result.content[0].text, "git\n", "vcs_read detect reaches the backend in a git fixture");
});

test("backend failure surfacing", async () => {
const push = await execTool("vcs_write", { op: "push" }, { setup: gitFixture });
assert.equal(push.error instanceof Error, true, "vcs_write push without remote throws");
});

test("Api-module partition guards (adapter-reachable only)", async () => {
const fetchCall = await execTool("vcs_read", { args: ["fetch"] });
assert.ok(fetchCall.error instanceof Error, "vcs_read fetch is rejected throws");
assert.match(fetchCall.error.message, /vcs_read: fetch updates remote-tracking refs/, "vcs_read fetch is rejected names the failure");
const branchRead = await execTool("vcs_read", { args: ["branch", "x"] });
assert.ok(branchRead.error instanceof Error, "vcs_read branch is rejected as mutating throws");
assert.match(branchRead.error.message, /vcs_read: mutating operation rejected/, "vcs_read branch is rejected as mutating names the failure");
// The mirrored vcs_write guard ("read-only operation rejected") is NOT
// adapter-reachable: the tool schema rejects read ops before execute.
});

test("forge body lifecycle (success)", async () => {
const ghLog = path.join(os.tmpdir(), `agency-plugin-gh-${process.pid}-${Date.now()}.log`);
fs.writeFileSync(ghLog, "");
const prCreate = await execTool(
  "forge",
  { op: "pr-create", args: ["--title", "t"], body: "line1\nline2\n" },
  {
    keep: true,
    setup: writeGhStub,
    env: { FORGE_OVERRIDE: "github", GH_LOG: ghLog },
  },
);
try {
  assert.equal(prCreate.result.details.exit, 0, "forge pr-create with body succeeds");
  const logged = fs.readFileSync(ghLog, "utf8");
  const newlineAt = logged.indexOf("\n");
  const ghArgv = JSON.parse(logged.slice(0, newlineAt));
  const ghBody = logged.slice(newlineAt + 1);
  assert.equal(JSON.stringify(ghArgv.slice(0, 5)), JSON.stringify(["pr", "create", "--title", "t", "--body-file"]), "gh receives pr create with the body file flag");
  assert.equal(ghArgv.length, 6, "gh receives exactly the expected argv");
  const bodyPath = ghArgv[5];
  assert.equal(path.relative(prCreate.fixture, bodyPath).startsWith(".."), false, "body file lives inside the fixture");
  assert.equal(ghBody, "line1\nline2\n", "gh received the exact body content");
  assert.equal(fixtureListing(prCreate.fixture), prCreate.before, "forge leaves no artifacts behind on success");
} finally {
  fs.rmSync(prCreate.fixture, { recursive: true, force: true });
  fs.rmSync(ghLog, { force: true });
}
});

test("forge body lifecycle (failure)", async () => {
const failLog = path.join(os.tmpdir(), `agency-plugin-gh-${process.pid}-${Date.now()}.log`);
fs.writeFileSync(failLog, "");
const prFail = await execTool(
  "forge",
  { op: "pr-create", args: [], body: "x" },
  {
    keep: true,
    setup: writeGhStub,
    env: { FORGE_OVERRIDE: "github", GH_LOG: failLog, GH_FAIL: "1", GH_STDERR: "boom\n" },
  },
);
try {
  assert.ok(prFail.error instanceof Error, "forge pr-create failure surfaces stderr throws");
assert.match(prFail.error.message, /boom/, "forge pr-create failure surfaces stderr names the failure");
  assert.equal(fixtureListing(prFail.fixture), prFail.before, "forge leaves no artifacts behind on failure");
} finally {
  fs.rmSync(prFail.fixture, { recursive: true, force: true });
  fs.rmSync(failLog, { force: true });
}
});

test("workflow tool", async () => {
const cli = await execTool("workflow", { field: "cli" }, {
  setup: (fixture) => {
    fs.writeFileSync(path.join(fixture, ".do-results.json"), JSON.stringify(TEST_STATE));
  },
});
assert.equal(cli.result.details.exit, 0, "workflow cli succeeds");
const missingState = await execTool("workflow", { field: "cli" });
assert.ok(missingState.error instanceof Error, "workflow without state surfaces the actionable error throws");
assert.match(missingState.error.message, /run do-driver init first/, "workflow without state surfaces the actionable error names the failure");
});

test("agency_driver op concat proof", async () => {
const syncOp = await execTool("agency_driver", { op: "sync", args: [] });
assert.ok(syncOp.error instanceof Error, "agency_driver prepends sync to operands throws");
assert.match(syncOp.error.message, /noVcs is required/, "agency_driver prepends sync to operands names the failure");
const startOp = await execTool("agency_driver", { op: "start", args: [] });
assert.ok(startOp.error instanceof Error, "agency_driver prepends start to operands throws");
assert.match(startOp.error.message, /step required/, "agency_driver prepends start to operands names the failure");
});

test("vcs_read base (state read through the adapter)", async () => {
const baseOp = await execTool("vcs_read", { args: ["base"] }, {
  setup: (fixture) => {
    fs.writeFileSync(path.join(fixture, ".do-results.json"), JSON.stringify({ base: "main" }));
  },
});
assert.equal(baseOp.result.content[0].text, "main\n", "vcs_read base reads persisted state");
});
