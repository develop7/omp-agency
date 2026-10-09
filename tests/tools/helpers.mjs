import { mkdtemp, readFile, rm } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { z } from "zod";
import agencyTools from "../../dist/agency-tools.mjs";

export function registerTools() {
  const tools = new Map();
  agencyTools({
    zod: z,
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
  const params = definition.parameters.parse(input);
  return definition.execute("boundary-test", params, undefined, undefined, { cwd });
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
