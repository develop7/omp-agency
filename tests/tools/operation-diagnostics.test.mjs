import assert from "node:assert/strict";
import { readdir } from "node:fs/promises";
import test from "node:test";
import {
  invoke,
  parseInput,
  registerTools,
  tool,
  withIsolatedRepo,
} from "./helpers.mjs";

const tools = registerTools();
const schema = (name) => tool(tools, name).parameters;

function diagnostic(name, input) {
  const result = parseInput(schema(name), input);
  assert.equal(
    result.success,
    false,
    `expected rejection: ${JSON.stringify(input)}`,
  );
  return result.error.message;
}

// Diagnostics include JSON.stringify-produced examples; validate their contents
// against the actual tool schema rather than relying on particular sample values.
function examples(name, message) {
  return [...message.matchAll(/\{[^{}]*\}/g)].flatMap(([text]) => {
    try {
      const value = JSON.parse(text);
      return parseInput(schema(name), value).success ? [value] : [];
    } catch {
      return [];
    }
  });
}

function exampleFor(name, message, op) {
  const example = examples(name, message).find((value) => value.op === op);
  assert.ok(example, `expected a valid ${op} JSON example in: ${message}`);
  return example;
}

const choices = /choos|choice|ambiguous|select/i;

test("missing and invalid op diagnostics provide supported operations and usable examples", () => {
  for (const [name, supported] of [
    ["vcs_read", "dirty"],
    ["vcs_write", "branch"],
    ["forge", "pr-view"],
    ["agency_driver", "summary"],
  ]) {
    for (const input of [{}, { op: "not-an-operation" }]) {
      const message = diagnostic(name, input);
      assert.match(message, /op/i);
      assert.ok(message.includes(supported), `${name}: ${message}`);
      assert.ok(
        examples(name, message).length,
        `${name} needs a usable example: ${message}`,
      );
    }
  }
});

test("legacy operation hints produce complete named-field examples but remain rejected", () => {
  for (const [name, op] of [
    ["agency_driver", "summary"],
    ["forge", "pr-view"],
  ]) {
    const message = diagnostic(name, { args: [op] });
    exampleFor(name, message, op);
  }
  const branch = exampleFor(
    "vcs_write",
    diagnostic("vcs_write", { args: ["branch"] }),
    "branch",
  );
  assert.equal(typeof branch.name, "string");
  assert.ok(branch.name.length > 0);
});

test("ambiguous and conflicting evidence requires an explicit operation choice", () => {
  const input = { message: "save changes", files: ["tracked.txt"] };
  const message = diagnostic("vcs_write", input);
  assert.match(message, choices);
  for (const op of ["commit", "fix-commit"]) {
    const example = exampleFor("vcs_write", message, op);
    assert.deepEqual(example.message, input.message);
    assert.deepEqual(example.files, input.files);
  }
  const matchingHint = diagnostic("vcs_write", { args: ["commit"], ...input });
  assert.match(matchingHint, choices);
  for (const op of ["commit", "fix-commit"])
    exampleFor("vcs_write", matchingHint, op);
  const conflict = diagnostic("vcs_write", { args: ["branch"], ...input });
  assert.match(conflict, choices);
  assert.match(conflict, /branch/i);
  assert.match(conflict, /commit/i);
});

test("invalid op with unique named fields suggests the matching operation", () => {
  const message = diagnostic("vcs_write", { op: "invalid", name: "topic" });
  assert.equal(exampleFor("vcs_write", message, "branch").name, "topic");
});

test("unknown legacy tokens receive supported-op guidance, not fuzzy matches", () => {
  const message = diagnostic("agency_driver", { args: ["summar"] });
  assert.match(message, /op/i);
  assert.match(message, /summary/i);
  assert.match(message, choices);
});

test("known operations preserve field rejection and never accept legacy args", () => {
  const malformed = diagnostic("vcs_write", { op: "branch", name: 17 });
  assert.match(malformed, /name/i);
  for (const [name, input] of [
    ["vcs_read", { op: "dirty", args: ["dirty"] }],
    ["vcs_write", { op: "branch", name: "topic", args: ["branch"] }],
    ["forge", { op: "pr-view", args: ["pr-view"] }],
    ["agency_driver", { op: "summary", args: ["summary"] }],
  ])
    diagnostic(name, input);
});

test("valid requests parse unchanged for each op-selected tool", () => {
  for (const [name, input] of [
    ["vcs_read", { op: "dirty" }],
    ["vcs_write", { op: "branch", name: "topic" }],
    ["forge", { op: "pr-view" }],
    ["agency_driver", { op: "summary" }],
  ]) {
    const result = parseInput(schema(name), input);
    assert.equal(result.success, true, name);
    assert.deepEqual(result.data, input);
  }
});

test("missing-op init-like invocation does not mutate isolated repository state", async () => {
  await withIsolatedRepo(async (cwd) => {
    const before = await readdir(cwd);
    await assert.rejects(
      invoke(tools, "agency_driver", { task: "diagnostic test" }, cwd),
    );
    assert.deepEqual(await readdir(cwd), before);
  });
});
