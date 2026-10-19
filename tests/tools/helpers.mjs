import { mkdtemp, readFile, rm } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { type } from "@oh-my-pi/omptype";
import * as zod from "@oh-my-pi/omptype/zod";
import agencyTools from "../../dist/agency-tools.mjs";

// Facade schemas carry safeParse; core omptype wrappers (type.withJsonSchema)
// are callable validators returning type.errors. Normalize both to one result
// shape so assertions read the schema contract, not the builder flavor.
export function parseInput(schema, value) {
  if (typeof schema.safeParse === "function") return schema.safeParse(value);
  const out = schema(value);
  if (!(out instanceof type.errors)) return { success: true, data: out };
  return {
    success: false,
    error: { message: out.summary, issues: out.map(issue => ({ path: [...issue.path], message: issue.problem })) },
  };
}

export function registerTools() {
  const tools = new Map();
  agencyTools({
    arktype: type,
    zod,
    registerTool(tool) {
      tools.set(tool.name, tool);
    },
  });
  return tools;
}

export function tool(tools, name) {
  const definition = tools.get(name);
  if (!definition) throw new Error(`Tool not registered: ${name}`);
  return definition;
}

export async function invoke(tools, name, input, cwd = process.cwd()) {
  const definition = tool(tools, name);
  const params = parseInput(definition.parameters, input);
  if (!params.success) throw new Error(params.error.message);
  return definition.execute("boundary-test", params.data, undefined, undefined, { cwd });
}

export async function withIsolatedRepo(run) {
  const oldCwd = process.cwd();
  const oldEnv = { ...process.env };
  const cwd = await mkdtemp(join(tmpdir(), "agency-tool-contract-"));
  try {
    process.chdir(cwd);
    await run(cwd);
  } finally {
    process.chdir(oldCwd);
    for (const key of Object.keys(process.env)) {
      if (!(key in oldEnv)) delete process.env[key];
    }
    Object.assign(process.env, oldEnv);
    await rm(cwd, { recursive: true, force: true });
  }
}

export async function initState(cwd = process.cwd(), options = {}) {
  const tools = registerTools();
  await invoke(tools, "agency_driver", { op: "init", ...options }, cwd);
  return tools;
}

export async function readState(cwd = process.cwd()) {
  return JSON.parse(await readFile(join(cwd, ".do-results.json"), "utf8"));
}

export const snapshot = (cwd) => readFile(join(cwd, ".do-results.json"), "utf8");
