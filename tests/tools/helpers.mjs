import { mkdtemp, readFile, rm } from "node:fs/promises";
import { tmpdir } from "node:os";
import { createHash } from "node:crypto";
import { realpathSync } from "node:fs";
import { join } from "node:path";
import { DatabaseSync } from "node:sqlite";
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
    error: {
      message: out.summary,
      issues: out.map((issue) => ({
        path: [...issue.path],
        message: issue.problem,
      })),
    },
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
  return definition.execute(
    "boundary-test",
    params.data,
    undefined,
    undefined,
    { cwd },
  );
}

export async function withIsolatedRepo(run) {
  const oldCwd = process.cwd();
  const oldEnv = { ...process.env };
  const cwd = await mkdtemp(join(tmpdir(), "agency-tool-contract-"));
  try {
    process.chdir(cwd);
    process.env.AGENCY_STATE_DIR = join(cwd, "agency-state");
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
  const registered = registerTools();
  const result = await invoke(
    registered,
    "agency_driver",
    { op: "state" },
    cwd,
  );
  return result.details.value;
}

export const snapshot = async (cwd) => JSON.stringify(await readState(cwd));

async function stateDbPath(cwd) {
  const workspacePath = realpathSync.native(cwd);
  const digest = createHash("sha256").update(workspacePath).digest("hex");
  return join(process.env.AGENCY_STATE_DIR, `${digest}.db`);
}

export async function readStoredState(cwd) {
  const db = new DatabaseSync(await stateDbPath(cwd), { readOnly: true });
  const value = db
    .prepare("SELECT state_json FROM run WHERE workspace_path = ?")
    .get(realpathSync.native(cwd))?.state_json;
  db.close();
  return value;
}

// Test-only anomaly injection. Production and ordinary assertions use `state`.
export async function writeStoredState(cwd, state) {
  const db = new DatabaseSync(await stateDbPath(cwd));
  db.prepare("UPDATE run SET state_json = ? WHERE workspace_path = ?").run(
    typeof state === "string" ? state : JSON.stringify(state),
    realpathSync.native(cwd),
  );
  db.close();
}
