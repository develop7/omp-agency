import assert from "node:assert/strict";
import { execFileSync, spawnSync } from "node:child_process";
import { mkdir, writeFile } from "node:fs/promises";
import { join } from "node:path";
import test from "node:test";
import {
  initState,
  invoke,
  readState,
  registerTools,
  withIsolatedRepo,
} from "./helpers.mjs";

function modelValue(result) {
  const text = result.content.map((part) => part.text).join("\n");
  return JSON.parse(text.replace(/^```json\n/, "").replace(/\n```$/, ""));
}

test("workflow decisions follow actual step transitions as structured data", async () => {
  await withIsolatedRepo(async (cwd) => {
    const tools = await initState(cwd, { noVcs: true });
    const first = await invoke(tools, "workflow", { field: "cli" }, cwd);
    assert.equal(modelValue(first).step, "sync");
    assert.equal(first.details.value.skip, false);
    await invoke(tools, "agency_driver", { op: "sync", noVcs: true }, cwd);
    const next = await invoke(tools, "workflow", { field: "cli" }, cwd);
    assert.equal(modelValue(next).step, "research");
    assert.equal(next.details.value.instructions, "nodes/research.md");
    await invoke(
      tools,
      "agency_driver",
      { op: "set", field: "status", value: "completed" },
      cwd,
    );
    const terminal = await invoke(tools, "workflow", { field: "cli" }, cwd);
    assert.deepEqual(modelValue(terminal), { done: true });
  });
});

test("oversized UTF-8 values remain complete in model content without duplicating details", async () => {
  await withIsolatedRepo(async (cwd) => {
    const tools = await initState(cwd, { noVcs: true });
    const value = "雪".repeat(12000);
    const result = await invoke(
      tools,
      "agency_driver",
      { op: "set", field: "note", value },
      cwd,
    );
    assert.equal(modelValue(result).value, value);
    assert.equal(result.details.value, null);
    assert.equal(result.useless, undefined);
    assert.equal((await readState(cwd)).note, value);
  });
});

test("Git path arrays preserve delimiter-containing filenames and empty matches", async () => {
  await withIsolatedRepo(async (cwd) => {
    const git = (...args) =>
      execFileSync("git", args, { cwd, stdio: "ignore" });
    git("init", "--quiet");
    git("config", "user.email", "test@example.com");
    git("config", "user.name", "Test");
    git("commit", "--allow-empty", "--quiet", "-m", "base");
    git("branch", "base");
    const tools = await initState(cwd, { noVcs: true });
    await invoke(
      tools,
      "agency_driver",
      { op: "set", field: "base", value: "base" },
      cwd,
    );
    const path = "line\nbreak\t雪.txt";
    await writeFile(join(cwd, path), "exact path\n");
    git("add", path);
    git("commit", "--quiet", "-m", "add path");
    const result = await invoke(tools, "vcs_read", { op: "new-files" }, cwd);
    assert.deepEqual(modelValue(result), [path]);
    assert.deepEqual(result.details.value, [path]);
    const empty = await invoke(
      tools,
      "vcs_read",
      { op: "new-files", paths: ["absent"] },
      cwd,
    );
    assert.deepEqual(modelValue(empty), []);
    assert.equal(empty.useless, true);
  });
});

test("forge rejects malformed JSON projections but leaves jq text uninterpreted", async () => {
  await withIsolatedRepo(async (cwd) => {
    const bin = join(cwd, "bin");
    await mkdir(bin);
    await writeFile(join(bin, "gh"), "#!/bin/sh\nprintf 'not-json\\n'\n", {
      mode: 0o755,
    });
    process.env.PATH = `${bin}:${process.env.PATH}`;
    process.env.FORGE_OVERRIDE = "github";
    const tools = registerTools();
    await assert.rejects(
      invoke(tools, "forge", { op: "pr-view", pr: "42", json: ["title"] }, cwd),
      /invalid JSON/,
    );
    const projected = await invoke(
      tools,
      "forge",
      { op: "pr-view", pr: "42", json: ["title"], github: { jq: ".title" } },
      cwd,
    );
    assert.equal(projected.details.value, null);
    assert.equal(projected.content[0].text, "not-json\n");
  });
});

test("forge capability absence is data but unsupported operations still fail", async () => {
  const cliPath = new URL("../../pure/dist/agency-do.js", import.meta.url)
    .pathname;
  await withIsolatedRepo(async (cwd) => {
    const tools = registerTools();
    for (const forge of ["github", "unknown"]) {
      process.env.FORGE_OVERRIDE = forge;
      const supported = forge === "github";
      const result = await invoke(
        tools,
        "forge",
        { op: "supports", operation: "pr-create" },
        cwd,
      );
      assert.equal(modelValue(result), supported);
      assert.equal(result.details.value, supported);
      const cli = spawnSync(
        process.execPath,
        [cliPath, "forge-op", "supports", "pr-create"],
        { cwd },
      );
      assert.equal(
        cli.status,
        supported ? 0 : 1,
        "the CLI retains shell-predicate exit codes",
      );
    }
    await assert.rejects(
      invoke(tools, "forge", { op: "pr-view", pr: "42" }, cwd),
      /does not support/,
    );
  });
});
