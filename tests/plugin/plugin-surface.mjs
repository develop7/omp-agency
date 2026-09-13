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

function assert(name, actual, expected) {
  if (actual === expected) {
    console.log(`${name} passed`);
  } else {
    console.error(`${name} failed`);
    console.error(`Expected: ${expected}`);
    console.error(`Actual:   ${actual}`);
    throw new Error(`plugin assertion failed: ${name}`);
  }
}

// Asserts the call threw an Error whose message contains the substring.
function assertThrows(name, outcome, substring) {
  assert(`${name} throws`, outcome.error instanceof Error, true);
  assert(
    `${name} names the failure`,
    outcome.error.message.includes(substring),
    true,
  );
}

async function run() {
  // ─── registration ────────────────────────────────────────────────────
  assert(
    "registers exactly the five agency tools",
    [...tools.keys()].sort().join(","),
    "agency_driver,forge,vcs_read,vcs_write,workflow",
  );
  assert(
    "tools carry labels",
    ["vcs_read", "vcs_write", "forge", "workflow", "agency_driver"]
      .map((name) => tools.get(name).label)
      .join(","),
    "VCS Read,VCS Write,Forge,Workflow,Agency Driver",
  );
  assert(
    "every tool exposes a safeParse schema",
    [...tools.values()].every((tool) => typeof tool.parameters?.safeParse === "function"),
    true,
  );

  // ─── vcs_write schema ────────────────────────────────────────────────
  const vcsWrite = tools.get("vcs_write").parameters;
  assert(
    "vcs_write rejects commit with empty files",
    vcsWrite.safeParse({ op: "commit", message: "m", files: [] }).success,
    false,
  );
  assert(
    "vcs_write rejects commit with a stray ref",
    vcsWrite.safeParse({ op: "commit", message: "m", files: ["a"], ref: "x" }).success,
    false,
  );
  assert(
    "vcs_write rejects commit without files",
    vcsWrite.safeParse({ op: "commit", message: "m" }).success,
    false,
  );
  assert(
    "vcs_write rejects branch with files",
    vcsWrite.safeParse({ op: "branch", name: "n", files: ["x"] }).success,
    false,
  );
  assert(
    "vcs_write accepts commit with message and files",
    vcsWrite.safeParse({ op: "commit", message: "m", files: ["a"] }).success,
    true,
  );

  // ─── forge schema ────────────────────────────────────────────────────
  const forge = tools.get("forge").parameters;
  assert(
    "forge rejects body on pr-view",
    forge.safeParse({ op: "pr-view", args: [], body: "x" }).success,
    false,
  );
  assert(
    "forge accepts body on pr-create",
    forge.safeParse({ op: "pr-create", args: [], body: "x" }).success,
    true,
  );

  // ─── agency_driver schema ────────────────────────────────────────────
  const agencyDriver = tools.get("agency_driver").parameters;
  assert(
    "agency_driver rejects an unknown op",
    agencyDriver.safeParse({ op: "nonsense", args: [] }).success,
    false,
  );
  assert(
    "agency_driver accepts sync",
    agencyDriver.safeParse({ op: "sync", args: [] }).success,
    true,
  );

  // ─── workflow schema ─────────────────────────────────────────────────
  const workflow = tools.get("workflow").parameters;
  assert(
    "workflow rejects from on cli",
    workflow.safeParse({ field: "cli", from: "default" }).success,
    false,
  );
  assert(
    "workflow rejects an undeclared entry point",
    workflow.safeParse({ field: "cli_seed", from: "not-a-step" }).success,
    false,
  );
  assert(
    "workflow accepts cli_seed from default",
    workflow.safeParse({ field: "cli_seed", from: "default" }).success,
    true,
  );

  // ─── adapter ↔ backend wiring (one round-trip through agency-api.js) ─
  const detect = await execTool("vcs_read", { args: ["detect"] }, { setup: gitFixture });
  assert(
    "vcs_read detect reaches the backend in a git fixture",
    detect.result.content[0].text,
    "git\n",
  );

  // ─── backend failure surfacing ───────────────────────────────────────
  const push = await execTool("vcs_write", { op: "push" }, { setup: gitFixture });
  assert("vcs_write push without remote throws", push.error instanceof Error, true);

  // ─── Api-module partition guards (adapter-reachable only) ────────────
  const fetchCall = await execTool("vcs_read", { args: ["fetch"] });
  assertThrows(
    "vcs_read fetch is rejected",
    fetchCall,
    "vcs_read: fetch updates remote-tracking refs",
  );
  const branchRead = await execTool("vcs_read", { args: ["branch", "x"] });
  assertThrows(
    "vcs_read branch is rejected as mutating",
    branchRead,
    "vcs_read: mutating operation rejected",
  );
  // The mirrored vcs_write guard ("read-only operation rejected") is NOT
  // adapter-reachable: the tool schema rejects read ops before execute.

  // ─── forge body lifecycle (success) ──────────────────────────────────
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
    assert("forge pr-create with body succeeds", prCreate.result.details.exit, 0);
    const logged = fs.readFileSync(ghLog, "utf8");
    const newlineAt = logged.indexOf("\n");
    const ghArgv = JSON.parse(logged.slice(0, newlineAt));
    const ghBody = logged.slice(newlineAt + 1);
    assert(
      "gh receives pr create with the body file flag",
      JSON.stringify(ghArgv.slice(0, 5)),
      JSON.stringify(["pr", "create", "--title", "t", "--body-file"]),
    );
    assert(
      "gh receives exactly the expected argv",
      ghArgv.length,
      6,
    );
    const bodyPath = ghArgv[5];
    assert(
      "body file lives inside the fixture",
      path.relative(prCreate.fixture, bodyPath).startsWith(".."),
      false,
    );
    assert("gh received the exact body content", ghBody, "line1\nline2\n");
    assert(
      "forge leaves no artifacts behind on success",
      fixtureListing(prCreate.fixture),
      prCreate.before,
    );
  } finally {
    fs.rmSync(prCreate.fixture, { recursive: true, force: true });
    fs.rmSync(ghLog, { force: true });
  }

  // ─── forge body lifecycle (failure) ──────────────────────────────────
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
    assertThrows("forge pr-create failure surfaces stderr", prFail, "boom");
    assert(
      "forge leaves no artifacts behind on failure",
      fixtureListing(prFail.fixture),
      prFail.before,
    );
  } finally {
    fs.rmSync(prFail.fixture, { recursive: true, force: true });
    fs.rmSync(failLog, { force: true });
  }

  // ─── workflow tool ───────────────────────────────────────────────────
  const cli = await execTool("workflow", { field: "cli" }, {
    setup: (fixture) => {
      fs.writeFileSync(path.join(fixture, ".do-results.json"), JSON.stringify(TEST_STATE));
    },
  });
  assert("workflow cli succeeds", cli.result.details.exit, 0);
  const missingState = await execTool("workflow", { field: "cli" });
  assertThrows(
    "workflow without state surfaces the actionable error",
    missingState,
    "run do-driver init first",
  );

  // ─── agency_driver op concat proof ───────────────────────────────────
  const syncOp = await execTool("agency_driver", { op: "sync", args: [] });
  assertThrows(
    "agency_driver prepends sync to operands",
    syncOp,
    "noVcs is required",
  );
  const startOp = await execTool("agency_driver", { op: "start", args: [] });
  assertThrows(
    "agency_driver prepends start to operands",
    startOp,
    "step required",
  );

  // ─── vcs_read base (state read through the adapter) ──────────────────
  const baseOp = await execTool("vcs_read", { args: ["base"] }, {
    setup: (fixture) => {
      fs.writeFileSync(path.join(fixture, ".do-results.json"), JSON.stringify({ base: "main" }));
    },
  });
  assert(
    "vcs_read base reads persisted state",
    baseOp.result.content[0].text,
    "main\n",
  );
}

run().catch((error) => {
  console.error(error?.stack ?? error);
  process.exitCode = 1;
});