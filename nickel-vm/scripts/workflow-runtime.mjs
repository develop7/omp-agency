import { readFile } from "node:fs/promises";
import { dirname, join, resolve } from "node:path";
import { fileURLToPath } from "node:url";

const runtimeRoot = resolve(dirname(fileURLToPath(import.meta.url)), "../..");

/** @typedef {{ exit: number, stdout: string, stderr: string }} WorkflowResult */

/**
 * Evaluate a /do workflow using assets and state discovered from the runtime
 * installation and supplied working directory. The request may be the CLI
 * bridge's JSON text or `{ operation, seed?, cwd? }`.
 *
 * @param {unknown} request
 * @returns {Promise<WorkflowResult>}
 */
export async function evaluateWorkflow(request) {
  try {
    const { cwd, operation, seed } = parseRequest(request);
    const [workflow_source, vocabulary_source, state_source] = await Promise.all([
      readWorkflowAsset(cwd, "workflow.ncl"),
      readWorkflowAsset(cwd, "workflow-manifest.json"),
      readStateSource(cwd),
    ]);
    const nickel = await loadNickel();
    const result = workflowResult(
      await nickel.eval_workflow({ workflow_source, vocabulary_source, state_source, operation, seed }),
    );
    return result.exit === 0
      ? { ...result, stdout: renderWorkflowOutput(operation, result.stdout) }
      : result;
  } catch (error) {
    return workflowFailure(error);
  }
}

/** @param {unknown} error @returns {WorkflowResult} */
export function workflowFailure(error) {
  return {
    exit: 1,
    stdout: "",
    stderr: error instanceof Error ? error.stack || error.message : String(error),
  };
}

/** @param {unknown} request */
function parseRequest(request) {
  const value = typeof request === "string" ? JSON.parse(request) : request;
  if (value === null || typeof value !== "object" || Array.isArray(value)) {
    throw new Error("workflow: request must be an object");
  }
  const { cwd = process.cwd(), operation, seed } = value;
  if (typeof cwd !== "string" || cwd === "") {
    throw new Error("workflow: cwd must be a non-empty string");
  }
  if (typeof operation !== "string" || operation === "") {
    throw new Error("workflow: operation must be a non-empty string");
  }
  if (seed !== undefined && seed !== null && typeof seed !== "string") {
    throw new Error("workflow: seed must be a string when provided");
  }
  return { cwd: resolve(cwd), operation, seed: seed ?? undefined };
}

/** @param {string} cwd @param {string} asset */
async function readWorkflowAsset(cwd, asset) {
  const bundledPath = join(runtimeRoot, "skills", "do", asset);
  const fallbackPath = join(cwd, "skills", "do", asset);
  try {
    return await readFile(bundledPath, "utf8");
  } catch (error) {
    if (!isMissingFile(error)) {
      throw cannotReadAsset(asset, bundledPath, fallbackPath, error);
    }
  }
  try {
    return await readFile(fallbackPath, "utf8");
  } catch (error) {
    throw cannotReadAsset(asset, bundledPath, fallbackPath, error);
  }
}

/** @param {string} cwd */
async function readStateSource(cwd) {
  const statePath = join(cwd, ".do-results.json");
  try {
    return await readFile(statePath, "utf8");
  } catch (error) {
    if (isMissingFile(error)) {
      throw new Error(
        `workflow: no .do-results.json in ${cwd} — run do-driver init first (from the repository root)`,
      );
    }
    const detail = error instanceof Error ? error.message : String(error);
    throw new Error(`workflow: cannot read state file .do-results.json at ${statePath}: ${detail}`);
  }
}

/** @param {unknown} error */
function isMissingFile(error) {
  return error !== null && typeof error === "object" && "code" in error && error.code === "ENOENT";
}

/** @param {string} asset @param {string} bundledPath @param {string} fallbackPath @param {unknown} error */
function cannotReadAsset(asset, bundledPath, fallbackPath, error) {
  const detail = error instanceof Error ? error.message : String(error);
  return new Error(
    `workflow: cannot read ${asset} at ${bundledPath} or in cwd at ${fallbackPath}: ${detail}`,
  );
}

let nickelPromise;

async function loadNickel() {
  if (nickelPromise === undefined) {
    nickelPromise = import("../dist/nickel_vm.js").catch((error) => {
      nickelPromise = undefined;
      const detail = error instanceof Error ? error.message : String(error);
      throw new Error(
        `workflow: cannot load Nickel WASM glue (${detail}); run 'just nickel-build' and retry`,
      );
    });
  }
  const nickel = await nickelPromise;
  if (typeof nickel.eval_workflow !== "function") {
    throw new Error("workflow: Nickel WASM glue does not export eval_workflow");
  }
  return nickel;
}

/** @param {unknown} value @returns {WorkflowResult} */
function workflowResult(value) {
  if (
    value === null ||
    typeof value !== "object" ||
    typeof value.exit !== "number" ||
    !Number.isInteger(value.exit) ||
    typeof value.stdout !== "string" ||
    typeof value.stderr !== "string"
  ) {
    throw new Error("workflow: Nickel WASM returned an invalid result");
  }
  return value;
}

/** @param {string} operation @param {string} source */
function renderWorkflowOutput(operation, source) {
  let value;
  try {
    value = JSON.parse(source);
  } catch (error) {
    const detail = error instanceof Error ? error.message : String(error);
    throw new Error(`workflow: Nickel returned invalid JSON output: ${detail}`);
  }
  if (operation === "cli") return renderCli(value);
  if (operation === "cli_seed") return renderCliSeed(value);
  throw new Error(`workflow: unsupported operation '${operation}'`);
}

/** @param {unknown} value */
function renderCli(value) {
  if (!isRecord(value)) {
    throw new Error("workflow: Nickel cli output must be an object");
  }
  if (value.done === true && Object.keys(value).length === 1) {
    return "{ done = true }";
  }
  const fields = ["step", "skip", "pattern", "instructions", "requires", "pattern_config"];
  requireExactFields("cli", value, fields);
  return `{ step = ${renderString(value.step, "cli step")}, skip = ${renderBoolean(value.skip, "cli skip")}, pattern = ${renderTag(value.pattern, "cli pattern")}, instructions = ${renderString(value.instructions, "cli instructions")}, requires = ${renderStringArray(value.requires, "cli requires")}, pattern_config = ${renderPatternConfig(value.pattern_config)} }`;
}

/** @param {unknown} value */
function renderCliSeed(value) {
  if (!Array.isArray(value)) {
    throw new Error("workflow: Nickel cli_seed output must be an array");
  }
  return `[${value.map(renderSeedStep).join(", ")}]`;
}

/** @param {unknown} value */
function renderSeedStep(value) {
  if (!isRecord(value)) {
    throw new Error("workflow: Nickel cli_seed items must be objects");
  }
  requireExactFields("cli_seed item", value, ["name", "initial_status"]);
  return `{ name = ${renderString(value.name, "cli_seed name")}, initial_status = ${renderTag(value.initial_status, "cli_seed initial_status")} }`;
}

/** @param {unknown} value */
function renderPatternConfig(value) {
  if (!isRecord(value)) {
    throw new Error("workflow: cli pattern_config must be an object");
  }
  const fields = Object.entries(value)
    .map(([key, item]) => `${key} = ${key === "loop_artifacts" ? renderTag(item, "pattern_config loop_artifacts") : renderJsonValue(item, `pattern_config ${key}`)}`)
    .join(", ");
  return fields === "" ? "{}" : `{ ${fields} }`;
}

/** @param {unknown} value @param {string} context */
function renderJsonValue(value, context) {
  if (typeof value === "string") return JSON.stringify(value);
  if (typeof value === "boolean" || typeof value === "number") return String(value);
  if (value === null) return "null";
  if (Array.isArray(value)) return `[${value.map((item) => renderJsonValue(item, context)).join(", ")}]`;
  if (isRecord(value)) {
    const fields = Object.entries(value)
      .map(([key, item]) => `${key} = ${renderJsonValue(item, context)}`)
      .join(", ");
    return fields === "" ? "{}" : `{ ${fields} }`;
  }
  throw new Error(`workflow: ${context} has an unsupported JSON value`);
}

/** @param {unknown} value @param {string} context */
function renderString(value, context) {
  if (typeof value !== "string") throw new Error(`workflow: ${context} must be a string`);
  return JSON.stringify(value);
}

/** @param {unknown} value @param {string} context */
function renderBoolean(value, context) {
  if (typeof value !== "boolean") throw new Error(`workflow: ${context} must be a boolean`);
  return String(value);
}

/** @param {unknown} value @param {string} context */
function renderStringArray(value, context) {
  if (!Array.isArray(value) || value.some((item) => typeof item !== "string")) {
    throw new Error(`workflow: ${context} must be an array of strings`);
  }
  return `[${value.map((item) => JSON.stringify(item)).join(", ")}]`;
}

/** @param {unknown} value @param {string} context */
function renderTag(value, context) {
  if (typeof value !== "string" || !/^[A-Za-z][A-Za-z0-9_-]*$/.test(value)) {
    throw new Error(`workflow: ${context} must be a valid tag`);
  }
  return `'${value}`;
}

/** @param {string} context @param {Record<string, unknown>} value @param {string[]} fields */
function requireExactFields(context, value, fields) {
  const actual = Object.keys(value);
  if (
    actual.length !== fields.length ||
    fields.some((field) => !Object.hasOwn(value, field))
  ) {
    throw new Error(`workflow: Nickel ${context} output has an invalid shape`);
  }
}

/** @param {unknown} value */
function isRecord(value) {
  return value !== null && typeof value === "object" && !Array.isArray(value);
}
