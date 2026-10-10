import assert from "node:assert/strict";
import { execFileSync } from "node:child_process";
import { readFile, writeFile } from "node:fs/promises";
import { join } from "node:path";
import test from "node:test";
import { runInNewContext } from "node:vm";
import { initState, invoke, readState, registerTools, tool, withIsolatedRepo } from "./helpers.mjs";

// Execute the suggested calls rather than pinning the surrounding error prose.
async function recoveryChoices(cwd, registered, op = "diff-range") {
  let message;
  await assert.rejects(invoke(registered, "vcs_read", { op }, cwd), (error) => {
    message = error.message;
    return true;
  });
  return [...message.matchAll(/agency_driver\((\{[^\n]*?\})\)/g)].map((match) =>
    tool(registered, "agency_driver").parameters.parse(runInNewContext(`(${match[1]})`, {}, { timeout: 1000 })),
  );
}

function git(cwd, ...args) {
  return execFileSync("git", args, { cwd, encoding: "utf8", stdio: ["ignore", "pipe", "pipe"] });
}

async function recoveryRepo(run) {
  await withIsolatedRepo(async (cwd) => {
    git(cwd, "init", "--quiet");
    git(cwd, "config", "user.email", "recovery@example.invalid");
    git(cwd, "config", "user.name", "Recovery tests");
    await writeFile(join(cwd, "tracked.txt"), "tracked\n");
    git(cwd, "add", "tracked.txt");
    git(cwd, "commit", "--quiet", "-m", "initial");
    git(cwd, "branch", "-M", "base");
    const remote = join(cwd, ".git", "remote.git");
    git(cwd, "init", "--bare", remote);
    git(cwd, "remote", "add", "origin", remote);
    git(cwd, "branch", "parent");
    git(cwd, "checkout", "-b", "feature");
    await writeFile(join(cwd, "feature.txt"), "feature branch\n");
    git(cwd, "add", "feature.txt");
    git(cwd, "commit", "--quiet", "-m", "feature change");
    git(cwd, "push", "origin", "base", "parent", "feature");
    git(cwd, "--git-dir", remote, "symbolic-ref", "HEAD", "refs/heads/base");
    await run(cwd);
  });
}

const snapshot = (cwd) => readFile(join(cwd, ".do-results.json"), "utf8");

test("absent-run recovery offers runnable init choices without creating state", async () => {
  for (const noVcs of [true, false]) {
    await withIsolatedRepo(async (cwd) => {
      const registered = registerTools();
      const choices = await recoveryChoices(cwd, registered);
      await assert.rejects(readState(cwd), { code: "ENOENT" });
      assert.deepEqual(choices.map(({ op, noVcs }) => ({ op, noVcs })), [
        { op: "init", noVcs: true }, { op: "init", noVcs: false },
      ]);
      await invoke(registered, "agency_driver", choices.find((choice) => choice.noVcs === noVcs), cwd);
      const state = await readState(cwd);
      assert.equal(state.status, "running");
      assert.equal(state.noVcs, noVcs);
    });
  }
});

test("noVcs recovery sync preserves mode and resolves the missing base", async () => {
  await recoveryRepo(async (cwd) => {
    const registered = await initState(cwd, { noVcs: true });
    const before = await snapshot(cwd);
    const choices = await recoveryChoices(cwd, registered);
    assert.equal(await snapshot(cwd), before);
    assert.deepEqual(choices.map(({ op, noVcs }) => ({ op, noVcs })), [{ op: "sync", noVcs: true }]);
    await invoke(registered, "agency_driver", choices[0], cwd);
    const state = await readState(cwd);
    assert.equal(state.noVcs, true);
    assert.equal(state.base, "no-vcs");
    assert.equal(git(cwd, "branch", "--show-current").trim(), "feature");
    assert.equal((await invoke(registered, "vcs_read", { op: "base" }, cwd)).details.stdout.trim(), "no-vcs");
  });
});

test("alternate diff failures retain all base choices until an explicit recovery selection", async () => {
  for (const selector of ["explicit", "stack", "default"]) {
    await recoveryRepo(async (cwd) => {
      const registered = await initState(cwd, { noVcs: false });
      const before = await snapshot(cwd);
      let choices;
      for (const op of ["diff-range", "diff-stat", "new-files"]) {
        choices = await recoveryChoices(cwd, registered, op);
        assert.equal(await snapshot(cwd), before);
        assert.deepEqual(choices.map((choice) => choice.noVcs), [false, false, false]);
        assert.deepEqual(choices.map((choice) => choice.op), ["sync", "sync", "sync"]);
        assert.equal(choices.filter((choice) => choice.base !== undefined).length, 1);
        assert.equal(choices.filter((choice) => choice.stack === true).length, 1);
        assert.equal(choices.filter((choice) => choice.base === undefined && choice.stack !== true).length, 1);
      }
      const choice = selector === "explicit"
        ? { ...choices.find((candidate) => candidate.base !== undefined), base: "parent" }
        : choices.find((candidate) => selector === "stack" ? candidate.stack === true : candidate.base === undefined && candidate.stack !== true);
      await invoke(registered, "agency_driver", choice, cwd);
      assert.equal((await readState(cwd)).base, { explicit: "parent", stack: "feature", default: "base" }[selector]);
      const diff = (await invoke(registered, "vcs_read", { op: "diff-range" }, cwd)).details.stdout;
      if (selector === "stack") assert.equal(diff, "");
      else assert.match(diff, /feature\.txt[\s\S]*feature branch/);
    });
  }
});

test("inactive runs and invalid state offer no executable sync or reset recommendation", async () => {
  for (const noVcs of [true, false]) {
    for (const status of ["completed", "failed"]) {
      await withIsolatedRepo(async (cwd) => {
        const registered = await initState(cwd, { noVcs });
        await invoke(registered, "agency_driver", { op: "set", field: "status", value: status }, cwd);
        const before = await snapshot(cwd);
        assert.deepEqual(await recoveryChoices(cwd, registered), []);
        assert.equal(await snapshot(cwd), before);
      });
    }
  }
  await withIsolatedRepo(async (cwd) => {
    const registered = registerTools();
    for (const contents of ["{", JSON.stringify({ status: "running", noVcs: "invalid" })]) {
      await writeFile(join(cwd, ".do-results.json"), contents);
      assert.deepEqual(await recoveryChoices(cwd, registered), []);
      assert.equal(await snapshot(cwd), contents);
    }
  });
});

test("invalid commit lists preserve changes, history, and workflow state", async () => {
  await recoveryRepo(async (cwd) => {
    const registered = await initState(cwd, { noVcs: false });
    await writeFile(join(cwd, "changed.txt"), "must remain uncommitted\n");
    const before = await snapshot(cwd);
    const head = git(cwd, "rev-parse", "HEAD");
    const status = git(cwd, "status", "--porcelain");
    await assert.rejects(invoke(registered, "vcs_write", {
      op: "commit", message: "must reject unchanged path", files: ["changed.txt", "tracked.txt"],
    }, cwd), /tracked\.txt/);
    assert.equal(git(cwd, "rev-parse", "HEAD"), head);
    assert.equal(git(cwd, "status", "--porcelain"), status);
    assert.equal(await readFile(join(cwd, "changed.txt"), "utf8"), "must remain uncommitted\n");
    assert.equal(await snapshot(cwd), before);
  });
});
