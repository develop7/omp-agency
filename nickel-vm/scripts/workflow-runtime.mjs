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
    return workflowResult(
      await nickel.eval_workflow({ workflow_source, vocabulary_source, state_source, operation, seed }),
    );
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
