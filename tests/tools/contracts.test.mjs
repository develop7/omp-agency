import assert from "node:assert/strict";
import { execFileSync } from "node:child_process";
import { mkdir, readFile, unlink, writeFile } from "node:fs/promises";
import { join } from "node:path";
import test from "node:test";
import {
  initState,
  invoke,
  readState,
  registerTools,
  tool,
  withIsolatedRepo,
} from "./helpers.mjs";

const tools = registerTools();
const manifest = JSON.parse(await readFile(new URL("../../skills/do/workflow-manifest.json", import.meta.url), "utf8"));

function rejects(schema, value) {
  assert.equal(schema.safeParse(value).success, false, `expected schema to reject ${JSON.stringify(value)}`);
}

function git(cwd, ...args) {
  execFileSync("git", args, { cwd, stdio: "ignore" });
}

async function gitRepo(run) {
  await withIsolatedRepo(async (cwd) => {
    git(cwd, "init", "--quiet");
    git(cwd, "config", "user.email", "tools@example.invalid");
    git(cwd, "config", "user.name", "Boundary tests");
    await writeFile(join(cwd, "tracked.txt"), "tracked\n");
    git(cwd, "add", "tracked.txt");
    git(cwd, "commit", "--quiet", "-m", "initial");
    git(cwd, "branch", "-M", "base");
    await run(cwd);
  });
}

test("tool schemas reject legacy raw argv contracts", () => {
  rejects(tool(tools, "vcs_read").parameters, { args: ["dirty"] });
  rejects(tool(tools, "vcs_write").parameters, { args: ["push"] });
  rejects(tool(tools, "agency_driver").parameters, { op: "start", args: ["implement"] });
  rejects(tool(tools, "workflow").parameters, { args: ["cli"] });
  rejects(tool(tools, "forge").parameters, { op: "pr-view", args: ["42"] });
});

test("vcs_read rejects paths on operations that do not consume them", () => {
  const schema = tool(tools, "vcs_read").parameters;
  for (const op of ["detect", "head-revision", "base", "dirty", "log-head"]) {
    rejects(schema, { op, paths: ["tracked.txt"] });
  }
  rejects(schema, { op: "diff-names", paths: ["tracked.txt"], args: ["--all"] });
});

test("vcs_write rejects option-like push refs", () => {
  rejects(tool(tools, "vcs_write").parameters, { op: "push", ref: "--force" });
});

test("push treats backend refs as operands without changing the remote", async () => {
  await gitRepo(async (cwd) => {
    git(cwd, "init", "--bare", "remote.git");
    git(cwd, "remote", "add", "origin", join(cwd, "remote.git"));
    const registered = await initState(cwd, { noVcs: false });
    await invoke(registered, "vcs_write", { op: "push", ref: "base" }, cwd);
    const remoteHead = () => execFileSync("git", ["--git-dir", join(cwd, "remote.git"), "rev-parse", "refs/heads/base"], { encoding: "utf8" });
    const before = remoteHead();
    await writeFile(join(cwd, "tracked.txt"), "changed\n");
    git(cwd, "add", "tracked.txt");
    git(cwd, "commit", "--quiet", "-m", "change local history");
    const { runTool } = await import("../../pure/dist/agency-api.js");
    const result = runTool({ tool: "vcs_write", args: ["push", "--force"], captureOutput: true })();
    assert.notEqual(result.exit, 0);
    assert.equal(remoteHead(), before);
  });
});
test("agency_driver rejects invalid operation fields and generated vocabulary values", () => {
  const schema = tool(tools, "agency_driver").parameters;
  rejects(schema, { op: "summary", args: [] });
  rejects(schema, { op: "start", step: "invented-step" });
  rejects(schema, { op: "end", status: "unknown" });
  rejects(schema, { op: "sync", stack: true });
  rejects(schema, { op: "sync", noVcs: true, stack: true });
  rejects(schema, { op: "init", restart: "yes" });
  rejects(schema, { op: "set", field: "minimal", value: "true" });
  rejects(schema, { op: "set", field: "active", value: "invented-step" });
  rejects(schema, { op: "set", field: "active", value: "implement" });
  rejects(schema, { op: "set", field: "pendingStep", value: "implement" });
  assert.equal(schema.safeParse({ op: "start", step: manifest.steps[0] }).success, true);
  assert.equal(schema.safeParse({ op: "set", field: "active", value: "working" }).success, true);
});

test("workflow rejects legacy argv and unknown entry-point selectors", () => {
  const schema = tool(tools, "workflow").parameters;
  rejects(schema, { args: ["cli"] });
  rejects(schema, { field: "cli", from: "default" });
  rejects(schema, { field: "cli_seed", from: "not-an-entry-point" });
});

test("forge rejects injected selectors, arbitrary argv, and conflicting bodies", () => {
  const schema = tool(tools, "forge").parameters;
  rejects(schema, { op: "pr-view", pr: "--repo=evil" });
  rejects(schema, { op: "issue-view", issue: "" });
  rejects(schema, { op: "pr-checks", interval: 0 });
  rejects(schema, { op: "pr-create", body: "x", bodyFile: "x.md" });
  rejects(schema, { op: "pr-edit", body: "x", bodyFile: "x.md" });
  rejects(schema, { op: "pr-comment", body: "x", bodyFile: "x.md" });
  rejects(schema, { op: "pr-create", title: "title", args: ["--repo=evil"] });
  assert.equal(schema.safeParse({ op: "pr-view", pr: "42" }).success, true);
  assert.equal(schema.safeParse({ op: "supports", operation: "pull-request" }).success, true);
});

test("forge keeps provider-only options in a strict GitHub extension", () => {
  const schema = tool(tools, "forge").parameters;
  rejects(schema, { op: "pr-create", fillFirst: true });
  rejects(schema, { op: "pr-view", jq: ".number" });
  rejects(schema, { op: "pr-comment", github: { arbitrary: true } });
  assert.equal(schema.safeParse({ op: "pr-create", github: { fillFirst: true } }).success, true);
  assert.equal(schema.safeParse({ op: "pr-view", json: ["number"], github: { jq: ".number" } }).success, true);
});

test("real PureScript lifecycle retains a failed step's reason", async () => {
  await withIsolatedRepo(async (cwd) => {
    const registered = await initState(cwd, { noVcs: true });
    await invoke(registered, "agency_driver", { op: "start", step: "implement" }, cwd);
    await invoke(registered, "agency_driver", {
      op: "end",
      status: "failed",
      verification: "node --test",
      reason: "the contract assertion failed",
    }, cwd);
    const state = await readState(cwd);
    const step = state.steps.find((item) => item.name === "implement");
    assert.equal(step.status, "failed");
    assert.equal(step.verification, "node --test");
    assert.equal(step.reason, "the contract assertion failed");
  });
});

test("real no-VCS sync succeeds only through the explicit noVcs contract", async () => {
  await withIsolatedRepo(async (cwd) => {
    const registered = await initState(cwd, { noVcs: true });
    const synced = await invoke(registered, "agency_driver", { op: "sync", noVcs: true }, cwd);
    assert.equal(synced.details.exit, 0);
    assert.equal((await readState(cwd)).noVcs, true);
    rejects(tool(registered, "agency_driver").parameters, { op: "sync", stack: true });
    rejects(tool(registered, "agency_driver").parameters, { op: "sync", noVcs: true, stack: true });
  });
});
test("registered dirty reports Git and jj working-copy status tokens", async () => {
  await gitRepo(async (cwd) => {
    const registered = registerTools();
    const result = async () => (await invoke(registered, "vcs_read", { op: "dirty" }, cwd)).details.stdout.trim();
    assert.equal(await result(), "clean");

    await writeFile(join(cwd, "tracked.txt"), "staged change\n");
    git(cwd, "add", "tracked.txt");
    assert.equal(await result(), "dirty");
    git(cwd, "reset", "--hard", "--quiet");
    await writeFile(join(cwd, "untracked.txt"), "untracked\n");
    assert.equal(await result(), "dirty");
  });

  await withIsolatedRepo(async (cwd) => {
    execFileSync("jj", ["git", "init"], { cwd, stdio: "ignore" });
    process.env.VCS_OVERRIDE = "jj";
    const registered = registerTools();
    const result = async () => (await invoke(registered, "vcs_read", { op: "dirty" }, cwd)).details.stdout.trim();
    assert.equal(await result(), "clean");
    await writeFile(join(cwd, "jj-change.txt"), "changed\n");
    assert.equal(await result(), "dirty");
  });
});

test("registered dirty distinguishes Git and jj inspection failures from no VCS", async () => {
  await withIsolatedRepo(async (cwd) => {
    const registered = registerTools();
    process.env.VCS_OVERRIDE = "git";
    await assert.rejects(
      invoke(registered, "vcs_read", { op: "dirty" }, cwd),
      /fatal|not a git repository/i,
    );
    process.env.VCS_OVERRIDE = "jj";
    await assert.rejects(
      invoke(registered, "vcs_read", { op: "dirty" }, cwd),
      /jj.*repo/i,
    );
    process.env.VCS_OVERRIDE = "";
    const noVcs = await invoke(registered, "vcs_read", { op: "dirty" }, cwd);
    assert.equal(noVcs.details.stdout.trim(), "no-vcs");
  });
});

test("registered working-copy-status reports clean and Git staged, untracked, and deleted paths", async () => {
  await gitRepo(async (cwd) => {
    const registered = registerTools();
    const clean = await invoke(registered, "vcs_read", { op: "working-copy-status" }, cwd);
    assert.equal(clean.details.stdout, "");

    await writeFile(join(cwd, "deleted.txt"), "to delete\n");
    git(cwd, "add", "deleted.txt");
    git(cwd, "commit", "--quiet", "-m", "add deleted fixture");
    await writeFile(join(cwd, "staged.txt"), "staged\n");
    await mkdir(join(cwd, "nested"));
    await writeFile(join(cwd, "nested", "untracked.txt"), "nested\n");
    git(cwd, "add", "staged.txt");
    await writeFile(join(cwd, "untracked.txt"), "new\n");
    await unlink(join(cwd, "deleted.txt"));

    const dirty = await invoke(registered, "vcs_read", { op: "working-copy-status" }, cwd);
    const status = dirty.content.map((part) => part.text).join("\n");
    assert.match(status, /staged\.txt/);
    assert.match(status, /untracked\.txt/);
    assert.match(status, /nested\/untracked\.txt/);
    assert.match(status, /deleted\.txt/);
  });
});

test("registered working-copy-status reports jj working-copy changes without a base", async () => {
  await withIsolatedRepo(async (cwd) => {
    execFileSync("jj", ["git", "init"], { cwd, stdio: "ignore" });
    process.env.VCS_OVERRIDE = "jj";
    const registered = registerTools();
    const clean = await invoke(registered, "vcs_read", { op: "working-copy-status" }, cwd);
    assert.equal(clean.details.stdout, "");
    await writeFile(join(cwd, "jj-change.txt"), "changed\n");
    const dirty = await invoke(registered, "vcs_read", { op: "working-copy-status" }, cwd);
    assert.match(dirty.content.map((part) => part.text).join("\n"), /jj-change\.txt/);
  });
});

test("registered working-copy-status distinguishes inspection failure from no VCS", async () => {
  await withIsolatedRepo(async (cwd) => {
    const registered = registerTools();
    process.env.VCS_OVERRIDE = "git";
    await assert.rejects(
      invoke(registered, "vcs_read", { op: "working-copy-status" }, cwd),
      /fatal|not a git repository/i,
    );
    process.env.VCS_OVERRIDE = "";
    await assert.rejects(
      invoke(registered, "vcs_read", { op: "working-copy-status" }, cwd),
      /no VCS/i,
    );
  });
});

test("typed set persists boolean and enum values through the real API", async () => {
  await withIsolatedRepo(async (cwd) => {
    const registered = await initState(cwd, { noVcs: true });
    await invoke(registered, "agency_driver", { op: "set", field: "minimal", value: true }, cwd);
    await invoke(registered, "agency_driver", { op: "set", field: "active", value: "working" }, cwd);
    const state = await readState(cwd);
    assert.equal(state.minimal, true);
    assert.equal(state.active, "working");
  });
});

test("vcs_read filters file results without mutating the real git fixture", async () => {
  await gitRepo(async (cwd) => {
    const registered = await initState(cwd, { noVcs: true });
    git(cwd, "checkout", "-b", "feature");
    await invoke(registered, "agency_driver", { op: "set", field: "base", value: "base" }, cwd);
    await writeFile(join(cwd, "one-new.txt"), "one\n");
    await writeFile(join(cwd, "two-new.txt"), "two\n");
    git(cwd, "add", "one-new.txt", "two-new.txt");
    git(cwd, "commit", "--quiet", "-m", "add files");
    const before = execFileSync("git", ["status", "--porcelain"], { cwd, encoding: "utf8" });
    const result = await invoke(registered, "vcs_read", { op: "new-files" }, cwd);
    const text = result.content.map((part) => part.text).join("\n");
    assert.match(text, /one-new\.txt/);
    assert.match(text, /two-new\.txt/);
    assert.equal(execFileSync("git", ["status", "--porcelain"], { cwd, encoding: "utf8" }), before);
    const filtered = await invoke(registered, "vcs_read", { op: "new-files", paths: ["one-new.txt"] }, cwd);
    const filteredText = filtered.content.map((part) => part.text).join("\n");
    assert.match(filteredText, /one-new\.txt/);
    assert.doesNotMatch(filteredText, /two-new\.txt/);
  });
});
