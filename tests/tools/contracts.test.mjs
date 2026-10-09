import assert from "node:assert/strict";
import { execFileSync } from "node:child_process";
import { readFile, writeFile } from "node:fs/promises";
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
    await invoke(registered, "agency_driver", { op: "sync", noVcs: true }, cwd);
    rejects(tool(registered, "agency_driver").parameters, { op: "sync", stack: true });
    rejects(tool(registered, "agency_driver").parameters, { op: "sync", noVcs: true, stack: true });
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
