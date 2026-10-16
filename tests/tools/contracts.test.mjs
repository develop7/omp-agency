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
  snapshot,
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

test("job operation schemas reject out-of-contract operands", () => {
  const schema = tool(tools, "agency_driver").parameters;
  rejects(schema, { op: "job-start", id: "", name: "Pass 1", step: "police" });
  rejects(schema, { op: "job-start", id: "j1", name: "", step: "police" });
  rejects(schema, { op: "job-start", id: "j1", name: "Pass 1", step: "invented-step" });
  rejects(schema, { op: "job-start", id: "j1", name: "Pass 1", step: "police", budgetMinutes: 0 });
  rejects(schema, { op: "job-start", id: "j1", name: "Pass 1", step: "police", budgetMinutes: 121 });
  rejects(schema, { op: "job-start", id: "j1", name: "Pass 1", step: "police", budgetMinutes: 10.5 });
  // Timestamps are driver-computed; the op never accepts them.
  rejects(schema, { op: "job-start", id: "j1", name: "Pass 1", step: "police", startedAt: "2020-01-01T00:00:00Z" });
  rejects(schema, { op: "job-end", id: "", outcome: "completed" });
  rejects(schema, { op: "job-end", id: "j1", outcome: "finished" });
  rejects(schema, { op: "job-end", id: "j1", outcome: "completed", args: [] });
  assert.equal(schema.safeParse({ op: "job-start", id: "j1", name: "Pass 1", step: "police", budgetMinutes: 120 }).success, true);
  assert.equal(schema.safeParse({ op: "job-end", id: "j1", outcome: "escalated", verification: "handoff notes" }).success, true);
});

test("the jobs ledger cannot be written through set", () => {
  const schema = tool(tools, "agency_driver").parameters;
  rejects(schema, { op: "set", field: "jobs", value: "implement" });
  rejects(schema, { op: "set", field: "jobs", value: [] });
  rejects(schema, { op: "set", field: "jobs", value: [{ id: "j1" }] });
});

test("job-start and job-end own the persisted jobs ledger", async () => {
  await withIsolatedRepo(async (cwd) => {
    const registered = await initState(cwd, { noVcs: true });
    await invoke(registered, "agency_driver", {
      op: "job-start", id: "police-pass1", name: "Pass 1 structure review", step: "police", budgetMinutes: 10,
    }, cwd);
    const started = await readState(cwd);
    assert.equal(started.jobs.length, 1);
    const job = started.jobs[0];
    assert.equal(job.id, "police-pass1");
    assert.equal(job.name, "Pass 1 structure review");
    assert.equal(job.step, "police");
    assert.match(job.startedAt, /^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}Z$/);
    assert.equal(
      job.deadline,
      new Date(Date.parse(job.startedAt) + 10 * 60_000).toISOString().replace(/\.\d{3}Z$/, "Z"),
    );
    assert.equal(job.finishedAt, undefined);
    assert.equal(job.outcome, undefined);

    await assert.rejects(
      invoke(registered, "agency_driver", { op: "job-start", id: "police-pass1", name: "Other pass", step: "police" }, cwd),
      /already running/,
    );
    await assert.rejects(
      invoke(registered, "agency_driver", { op: "job-end", id: "ghost", outcome: "completed" }, cwd),
      /no unfinished job/,
    );

    await invoke(registered, "agency_driver", {
      op: "job-end", id: "police-pass1", outcome: "completed", verification: "reviewed 12 files",
    }, cwd);
    const finished = await readState(cwd);
    assert.equal(finished.jobs.length, 1);
    assert.match(finished.jobs[0].finishedAt, /^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}Z$/);
    assert.equal(finished.jobs[0].outcome, "completed");
    assert.equal(finished.jobs[0].verification, "reviewed 12 files");

    await assert.rejects(
      invoke(registered, "agency_driver", { op: "job-end", id: "police-pass1", outcome: "failed" }, cwd),
      /no unfinished job/,
    );
  });
});

test("unfinished jobs block step-end and summary until job-end resolves them", async () => {
  await withIsolatedRepo(async (cwd) => {
    const registered = await initState(cwd, { noVcs: true });
    await invoke(registered, "agency_driver", {
      op: "job-start", id: "police-pass1", name: "Pass 1", step: "police", budgetMinutes: 10,
    }, cwd);
    await invoke(registered, "agency_driver", { op: "start", step: "police" }, cwd);

    const beforeGuard = await snapshot(cwd);
    await assert.rejects(
      invoke(registered, "agency_driver", { op: "end", status: "passed", verification: "ok" }, cwd),
      (error) => {
        assert.match(error.message, /unfinished job/);
        assert.match(error.message, /police-pass1/);
        assert.match(error.message, /verification reason/);
        return true;
      },
    );
    assert.equal(await snapshot(cwd), beforeGuard, "step-end guard must not mutate state");
    let state = await readState(cwd);
    assert.equal(state.steps.length, 0);
    assert.equal(state.pendingStep.name, "police");

    await assert.rejects(
      invoke(registered, "agency_driver", { op: "summary" }, cwd),
      (error) => {
        assert.match(error.message, /unfinished job/);
        assert.match(error.message, /verification reason/);
        return true;
      },
    );
    assert.equal(await snapshot(cwd), beforeGuard, "summary guard must not mutate state");

    // A job past its deadline is additionally reported as stalled.
    state = await readState(cwd);
    state.jobs[0].deadline = "2020-01-01T00:00:00Z";
    await writeFile(join(cwd, ".do-results.json"), JSON.stringify(state));
    const beforeStalled = await snapshot(cwd);
    await assert.rejects(
      invoke(registered, "agency_driver", { op: "summary" }, cwd),
      (error) => {
        assert.match(error.message, /unfinished job/);
        assert.match(error.message, /stalled/);
        assert.match(error.message, /police-pass1/);
        return true;
      },
    );
    assert.equal(await snapshot(cwd), beforeStalled, "stalled summary must not mutate state");

    await invoke(registered, "agency_driver", { op: "job-end", id: "police-pass1", outcome: "completed" }, cwd);
    const ended = await invoke(registered, "agency_driver", { op: "end", status: "passed", verification: "ok" }, cwd);
    assert.equal(ended.details.exit, 0);

    const summary = await invoke(registered, "agency_driver", { op: "summary" }, cwd);
    assert.match(summary.details.stdout, /\*\*Jobs\*\*/);
    assert.match(summary.details.stdout, /police-pass1/);
    assert.match(summary.details.stdout, /Pass 1/);
    assert.match(summary.details.stdout, /2020-01-01T00:00:00Z/);
    assert.match(summary.details.stdout, /completed/);

    state = await readState(cwd);
    assert.equal(state.steps.length, 1);
    assert.equal(state.pendingStep, undefined);
  });
});

test("the corrective step record is blocked by unfinished jobs", async () => {
  await withIsolatedRepo(async (cwd) => {
    const registered = await initState(cwd, { noVcs: true });
    await invoke(registered, "agency_driver", {
      op: "job-start", id: "police-pass1", name: "Pass 1", step: "police", budgetMinutes: 10,
    }, cwd);
    const before = await snapshot(cwd);
    await assert.rejects(
      invoke(registered, "agency_driver", {
        op: "step", step: "police", status: "passed", verification: "recorded directly",
        startedAt: "now", completedAt: "now",
      }, cwd),
      (error) => {
        assert.match(error.message, /unfinished job/);
        assert.match(error.message, /police-pass1/);
        return true;
      },
    );
    assert.equal(await snapshot(cwd), before, "step record guard must not mutate state");
  });
});

test("the done step blocks on unfinished jobs from any step", async () => {
  await withIsolatedRepo(async (cwd) => {
    const registered = await initState(cwd, { noVcs: true });
    await invoke(registered, "agency_driver", {
      op: "job-start", id: "impl-1", name: "Implement work", step: "implement", budgetMinutes: 10,
    }, cwd);
    await invoke(registered, "agency_driver", { op: "start", step: "done" }, cwd);

    const before = await snapshot(cwd);
    await assert.rejects(
      invoke(registered, "agency_driver", { op: "end", status: "passed", verification: "ok" }, cwd),
      (error) => {
        assert.match(error.message, /unfinished job/);
        assert.match(error.message, /impl-1/);
        return true;
      },
    );
    assert.equal(await snapshot(cwd), before, "blocked done end must not mutate state");
    const state = await readState(cwd);
    assert.equal(state.status, "running", "blocked done end must not terminalize the run");
    assert.equal(state.jobs[0].finishedAt, undefined);
  });
});

test("set cannot claim completion while jobs are unfinished", async () => {
  await withIsolatedRepo(async (cwd) => {
    const registered = await initState(cwd, { noVcs: true });
    await invoke(registered, "agency_driver", {
      op: "job-start", id: "police-pass1", name: "Pass 1", step: "police", budgetMinutes: 10,
    }, cwd);

    await assert.rejects(
      invoke(registered, "agency_driver", { op: "set", field: "status", value: "completed" }, cwd),
      (error) => {
        assert.match(error.message, /unfinished job/);
        assert.match(error.message, /police-pass1/);
        return true;
      },
    );
    await assert.rejects(
      invoke(registered, "agency_driver", { op: "set", field: "active", value: "idle" }, cwd),
      /unfinished job/,
    );
    assert.equal((await readState(cwd)).status, "running", "rejected set must not mutate state");

    // Honest abort stays available while jobs are open.
    const failed = await invoke(registered, "agency_driver", { op: "set", field: "status", value: "failed" }, cwd);
    assert.equal(failed.details.exit, 0);

    await invoke(registered, "agency_driver", { op: "job-end", id: "police-pass1", outcome: "completed" }, cwd);
    const completed = await invoke(registered, "agency_driver", { op: "set", field: "status", value: "completed" }, cwd);
    assert.equal(completed.details.exit, 0);
    assert.equal((await readState(cwd)).status, "completed");
  });
});

test("summary surfaces an unparsable job deadline instead of silently unstalling", async () => {
  await withIsolatedRepo(async (cwd) => {
    const registered = await initState(cwd, { noVcs: true });
    await invoke(registered, "agency_driver", {
      op: "job-start", id: "police-pass1", name: "Pass 1", step: "police", budgetMinutes: 10,
    }, cwd);
    const state = await readState(cwd);
    state.jobs[0].deadline = "not-a-time";
    await writeFile(join(cwd, ".do-results.json"), JSON.stringify(state));
    const before = await snapshot(cwd);
    await assert.rejects(
      invoke(registered, "agency_driver", { op: "summary" }, cwd),
      (error) => {
        assert.match(error.message, /unfinished job/);
        assert.match(error.message, /deadline unparsable/);
        return true;
      },
    );
    assert.equal(await snapshot(cwd), before, "unparsable-deadline summary must not mutate state");
  });
});

test("summary marks jobs without a deadline as unbounded", async () => {
  await withIsolatedRepo(async (cwd) => {
    const registered = await initState(cwd, { noVcs: true });
    await invoke(registered, "agency_driver", {
      op: "job-start", id: "no-budget", name: "Unbounded work", step: "police",
    }, cwd);
    const before = await snapshot(cwd);
    await assert.rejects(
      invoke(registered, "agency_driver", { op: "summary" }, cwd),
      (error) => {
        assert.match(error.message, /unfinished job/);
        assert.match(error.message, /no-budget/);
        assert.match(error.message, /no deadline/);
        return true;
      },
    );
    assert.equal(await snapshot(cwd), before, "unbounded summary must not mutate state");
  });
});

test("restart init carries unfinished jobs forward; plain init discards them", async () => {
  await withIsolatedRepo(async (cwd) => {
    const registered = await initState(cwd, { noVcs: true });
    await invoke(registered, "agency_driver", {
      op: "job-start", id: "carry-me", name: "Carried job", step: "implement", budgetMinutes: 30,
    }, cwd);
    const before = (await readState(cwd)).jobs[0];

    const restarted = await invoke(registered, "agency_driver", { op: "init", restart: true, task: "restarted task" }, cwd);
    assert.equal(restarted.details.exit, 0);
    assert.match(restarted.details.stdout, /carried unfinished job/);
    assert.match(restarted.details.stdout, /carry-me/);
    assert.deepEqual((await readState(cwd)).jobs, [before]);

    // Finished jobs stay behind with the discarded run.
    await invoke(registered, "agency_driver", { op: "job-end", id: "carry-me", outcome: "completed" }, cwd);
    await invoke(registered, "agency_driver", { op: "init", restart: true, task: "again" }, cwd);
    assert.equal((await readState(cwd)).jobs, undefined);

    // A non-restarting init on a terminal run discards unfinished jobs too.
    // The driver refuses to terminalize over an open job, so the fixture
    // writes the terminal run the ops can no longer produce.
    await invoke(registered, "agency_driver", {
      op: "job-start", id: "dropped", name: "Dropped job", step: "implement",
    }, cwd);
    const terminal = await readState(cwd);
    terminal.status = "completed";
    terminal.active = "idle";
    await writeFile(join(cwd, ".do-results.json"), JSON.stringify(terminal));
    await invoke(registered, "agency_driver", { op: "init", task: "fresh run" }, cwd);
    assert.equal((await readState(cwd)).jobs, undefined);
  });
});

test("job-end requires a recorded reason for non-completed outcomes", async () => {
  await withIsolatedRepo(async (cwd) => {
    const registered = await initState(cwd, { noVcs: true });
    await invoke(registered, "agency_driver", {
      op: "job-start", id: "police-pass1", name: "Pass 1", step: "police", budgetMinutes: 10,
    }, cwd);
    await assert.rejects(
      invoke(registered, "agency_driver", { op: "job-end", id: "police-pass1", outcome: "cancelled" }, cwd),
      /recorded reason/,
    );
    assert.equal((await readState(cwd)).jobs[0].outcome, undefined, "rejected end must not resolve the job");
    await invoke(registered, "agency_driver", {
      op: "job-end", id: "police-pass1", outcome: "cancelled", verification: "worker stalled and was killed",
    }, cwd);
    const ended = await readState(cwd);
    assert.equal(ended.jobs[0].outcome, "cancelled");
    assert.equal(ended.jobs[0].verification, "worker stalled and was killed");
  });
});

test("job-end refuses a finish that precedes the job start", async () => {
  await withIsolatedRepo(async (cwd) => {
    const registered = await initState(cwd, { noVcs: true });
    await invoke(registered, "agency_driver", {
      op: "job-start", id: "police-pass1", name: "Pass 1", step: "police", budgetMinutes: 10,
    }, cwd);
    // Clock rollback equivalent: the persisted start is in the future, so the
    // driver-computed finish would land before it.
    const state = await readState(cwd);
    state.jobs[0].startedAt = "2030-01-01T00:00:00Z";
    await writeFile(join(cwd, ".do-results.json"), JSON.stringify(state));

    await assert.rejects(
      invoke(registered, "agency_driver", { op: "job-end", id: "police-pass1", outcome: "completed" }, cwd),
      /precedes/,
    );
    const after = await readState(cwd);
    assert.equal(after.jobs[0].finishedAt, undefined, "rejected end must leave the job unfinished");
  });
});

test("the jobs ledger is bounded at 32 entries end to end", async () => {
  await withIsolatedRepo(async (cwd) => {
    const registered = await initState(cwd, { noVcs: true });
    const state = await readState(cwd);
    state.jobs = Array.from({ length: 32 }, (_, index) => ({
      id: `job-${index}`,
      name: `Job ${index}`,
      step: "police",
      startedAt: "2026-10-16T12:00:00Z",
      finishedAt: "2026-10-16T12:01:00Z",
      outcome: "completed",
    }));
    await writeFile(join(cwd, ".do-results.json"), JSON.stringify(state));
    await assert.rejects(
      invoke(registered, "agency_driver", { op: "job-start", id: "one-more", name: "Overflow", step: "police" }, cwd),
      /job ledger limit/,
    );

    state.jobs.push({
      id: "job-32", name: "Job 32", step: "police",
      startedAt: "2026-10-16T12:00:00Z", finishedAt: "2026-10-16T12:01:00Z", outcome: "completed",
    });
    await writeFile(join(cwd, ".do-results.json"), JSON.stringify(state));
    await assert.rejects(
      invoke(registered, "agency_driver", { op: "summary" }, cwd),
      /job ledger limit \(32\) exceeded/,
    );
  });
});

test("workflow rejects legacy argv and unknown entry-point selectors", () => {
  const schema = tool(tools, "workflow").parameters;
  rejects(schema, { args: ["cli"] });
  rejects(schema, { field: "cli_seed", from: "not-an-entry-point" });
});

test("workflow cli + from rejection names the sibling cli_seed arm", () => {
  const schema = tool(tools, "workflow").parameters;
  for (const from of ["default", "not-an-entry-point"]) {
    const result = schema.safeParse({ field: "cli", from });
    assert.equal(result.success, false);
    const [issue] = result.error.issues;
    assert.equal(issue.code, "unrecognized_keys");
    assert.deepEqual(issue.keys, ["from"]);
    // Guidance, not exact prose: the error must point at the cli_seed arm.
    assert.match(issue.message, /cli_seed/);
  }
  // The hint keeps enumerating any other unrecognized keys, as the deleted
  // strict-object prose did.
  const mixed = schema.safeParse({ field: "cli", from: "default", junk: 1 });
  assert.equal(mixed.success, false);
  assert.match(mixed.error.issues[0].message, /cli_seed/);
  assert.match(mixed.error.issues[0].message, /junk/);
  // Both valid forms keep parsing unchanged.
  assert.equal(schema.safeParse({ field: "cli" }).success, true);
  assert.equal(schema.safeParse({ field: "cli_seed", from: "default" }).success, true);
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
