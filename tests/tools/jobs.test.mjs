import assert from "node:assert/strict";
import { readFile, writeFile } from "node:fs/promises";
import { join } from "node:path";
import test from "node:test";
import { initState, invoke, readState, registerTools, tool, withIsolatedRepo } from "./helpers.mjs";

const tools = registerTools();
const schema = tool(tools, "agency_driver").parameters;
const snapshot = (cwd) => readFile(join(cwd, ".do-results.json"), "utf8");

function rejects(value) {
  assert.equal(schema.safeParse(value).success, false, `expected schema to reject ${JSON.stringify(value)}`);
}

test("job operation schemas reject out-of-contract operands", () => {
  rejects({ op: "job-start", id: "", name: "Pass 1", step: "police" });
  rejects({ op: "job-start", id: "j1", name: "", step: "police" });
  rejects({ op: "job-start", id: "j1", name: "Pass 1", step: "invented-step" });
  rejects({ op: "job-start", id: "j1", name: "Pass 1", step: "police", budgetMinutes: 0 });
  rejects({ op: "job-start", id: "j1", name: "Pass 1", step: "police", budgetMinutes: 121 });
  rejects({ op: "job-start", id: "j1", name: "Pass 1", step: "police", budgetMinutes: 10.5 });
  // Timestamps are driver-computed; the op never accepts them.
  rejects({ op: "job-start", id: "j1", name: "Pass 1", step: "police", startedAt: "2020-01-01T00:00:00Z" });
  rejects({ op: "job-end", id: "", outcome: "completed" });
  rejects({ op: "job-end", id: "j1", outcome: "finished" });
  rejects({ op: "job-end", id: "j1", outcome: "completed", args: [] });
  assert.equal(schema.safeParse({ op: "job-start", id: "j1", name: "Pass 1", step: "police", budgetMinutes: 120 }).success, true);
  assert.equal(schema.safeParse({ op: "job-end", id: "j1", outcome: "escalated", verification: "handoff notes" }).success, true);
});

test("the jobs ledger cannot be written through set", () => {
  rejects({ op: "set", field: "jobs", value: "implement" });
  rejects({ op: "set", field: "jobs", value: [] });
  rejects({ op: "set", field: "jobs", value: [{ id: "j1" }] });
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

test("restart init carries unfinished jobs forward; plain init discards them", async () => {
  await withIsolatedRepo(async (cwd) => {
    const registered = await initState(cwd, { noVcs: true });
    await invoke(registered, "agency_driver", {
      op: "job-start", id: "carry-me", name: "Carried job", step: "implement", budgetMinutes: 30,
    }, cwd);
    const before = (await readState(cwd)).jobs[0];

    const restarted = await invoke(registered, "agency_driver", { op: "init", restart: true, task: "restarted task" }, cwd);
    assert.equal(restarted.details.exit, 0);
    assert.deepEqual((await readState(cwd)).jobs, [before]);

    // Finished jobs stay behind with the discarded run.
    await invoke(registered, "agency_driver", { op: "job-end", id: "carry-me", outcome: "completed" }, cwd);
    await invoke(registered, "agency_driver", { op: "init", restart: true, task: "again" }, cwd);
    assert.equal((await readState(cwd)).jobs, undefined);

    // A non-restarting init on a terminal run discards unfinished jobs too.
    await invoke(registered, "agency_driver", {
      op: "job-start", id: "dropped", name: "Dropped job", step: "implement",
    }, cwd);
    await invoke(registered, "agency_driver", { op: "start", step: "done" }, cwd);
    await invoke(registered, "agency_driver", { op: "end", status: "passed", verification: "ok" }, cwd);
    await invoke(registered, "agency_driver", { op: "init", task: "fresh run" }, cwd);
    assert.equal((await readState(cwd)).jobs, undefined);
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
