import type { ExtensionAPI } from "@oh-my-pi/pi-coding-agent";
import { mkdtemp, rm, writeFile } from "node:fs/promises";
import { join } from "node:path";
import { evaluateWorkflow } from "../nickel-vm/scripts/workflow-runtime.mjs";
import { workflowEntryPoints } from "./workflow-vocabulary.js";

type ApiRequest = {
  tool: string;
  args: string[];
  captureOutput: boolean;
};

type ApiResult = {
  exit: number;
  stdout: string;
  stderr: string;
};

type AgencyApi = {
  runTool(request: ApiRequest): () => ApiResult;
};

type ToolContext = {
  cwd: string;
};

// The exact arktype-composed phrase the harness write schema emits for a
// missing required string field (packages/ai validation.ts asserts its
// stability). The context event exposes no structured error field, so this
// substring match is the only extension-visible signal; harness rewording
// degrades the rewrite to the status-quo generic error.
const MISSING_CONTENT_ERROR = "content must be file content (was missing)";

// Device argument fields per schema (issue #79). When the model hoists these
// onto the outer write call, the harness write schema rejects with a generic
// error before the device dispatch ever runs, and no hook fires on that path.
// Rewrite the paired error with a targeted hint so recovery no longer depends
// on the model guessing. Kept in lockstep with the five parameter schemas
// below; a missed key only degrades to the pre-fix generic error, never to a
// wrong repair.
const DEVICE_ARG_KEYS = ["args", "body", "field", "files", "from", "message", "name", "op", "ref"];

function rewriteDeviceFieldHoistErrors(messages: readonly unknown[]): unknown[] | undefined {
  // Pair each failing write call with its tool result by call id.
  // Null prototype: toolCallIds are model-controlled strings, and a plain
  // object literal turns a "__proto__" id into prototype assignment. First
  // occurrence wins: a duplicated id (compaction artifacts) must not let a
  // later shape mispair with the first call's tool result.
  const failingCalls: Record<string, Record<string, unknown>> = Object.create(null);
  for (const message of messages) {
    if (!message || typeof message !== "object") continue;
    const record = message as Record<string, unknown>;
    if (record.role !== "assistant" || !Array.isArray(record.content)) continue;
    for (const block of record.content) {
      if (!block || typeof block !== "object") continue;
      const call = block as Record<string, unknown>;
      if (call.type !== "toolCall" || call.name !== "write") continue;
      if (typeof call.id !== "string" || call.id.length === 0) continue;
      const args = call.arguments;
      if (!args || typeof args !== "object" || Array.isArray(args)) continue;
      const shape = args as Record<string, unknown>;
      const path = shape.path;
      if (typeof path !== "string" || !path.startsWith("xd://")) continue;
      if ("content" in shape && shape.content !== undefined && shape.content !== null) continue;
      const hoisted = Object.keys(shape).filter(
        key => key !== "path" && key !== "i" && DEVICE_ARG_KEYS.includes(key),
      );
      if (hoisted.length === 0) continue;
      if (call.id in failingCalls) continue;
      failingCalls[call.id] = shape;
    }
  }
  if (Object.keys(failingCalls).length === 0) return undefined;

  // Marker embedded in the hint below; its presence makes the rewrite idempotent.
  const marker = "received no `content`, but found device argument fields";

  let changed = false;
  const next = [...messages];
  for (let index = 0; index < next.length; index++) {
    const message = next[index];
    if (!message || typeof message !== "object") continue;
    const record = message as Record<string, unknown>;
    if (record.role !== "toolResult" || record.toolName !== "write" || record.isError !== true) continue;
    if (typeof record.toolCallId !== "string" || record.toolCallId.length === 0) continue;
    const shape = failingCalls[record.toolCallId];
    if (!shape) continue;
    if (!Array.isArray(record.content)) continue;
    const text = record.content
      .filter(block => block && typeof block === "object" && (block as Record<string, unknown>).type === "text")
      .map(block => String((block as Record<string, unknown>).text))
      .join("\n");
    if (!text.includes(MISSING_CONTENT_ERROR)) continue;
    if (text.includes(marker)) continue;
    const path = String(shape.path);
    // Payload rebuild by exclusion (everything except path/i): a hoisted key
    // the DEVICE_ARG_KEYS list does not know yet still lands in the suggested
    // payload instead of being silently dropped from the repair. BigInt and
    // undefined/function/symbol values cannot survive JSON.stringify; they are
    // stringified or omitted rather than aborting the whole context event.
    const devicePayload: Record<string, unknown> = {};
    for (const [key, value] of Object.entries(shape)) {
      if (key === "path" || key === "i") continue;
      if (value === undefined || typeof value === "function" || typeof value === "symbol") continue;
      devicePayload[key] = typeof value === "bigint" ? String(value) : value;
    }
    let payloadJson: string;
    try {
      payloadJson = JSON.stringify(devicePayload);
    } catch (error) {
      // Best-effort: cycle or getter throw in a model-supplied value degrades
      // to a hint without the payload line rather than failing the request.
      payloadJson = `  content: <unserializable (${error instanceof Error ? error.message : String(error)})>`;
    }
    const hint = [
      `Target ${path} ${marker} on the write call.`,
      `Put them inside a JSON object as the \`content\` field:`,
      `  content: ${payloadJson}`,
      ``,
      `The write call itself carries only path (and the intent \`i\`).`,
    ].join("\n");
    const replacement = {
      ...record,
      content: [...record.content, { type: "text", text: hint }],
    };
    next[index] = replacement;
    changed = true;
  }
  return changed ? next : undefined;
}

/** Shared invocation-convention sentence appended to every device description. */
function writeInvocationNote(example: string): string {
  return `Invoke via the write tool: the outer call carries only path and i; ALL arguments (${example}) go inside a JSON object as the content field — never hoisted onto the write call itself.`;
}

const forgeBodyOperations = ["pr-create", "pr-edit", "pr-comment"];

let apiPromise: Promise<AgencyApi> | undefined;

async function loadApi(): Promise<AgencyApi> {
  apiPromise ??= import("../pure/dist/agency-api.js") as unknown as Promise<AgencyApi>;
  return apiPromise;
}
async function executeWorkflow(
  params: { field: "cli" } | { field: "cli_seed"; from: string },
  ctx: ToolContext,
): Promise<{
  content: Array<{ type: "text"; text: string }>;
  details: ApiResult;
}> {
  const request = params.field === "cli"
    ? { operation: "cli" as const, cwd: ctx.cwd }
    : { operation: "cli_seed" as const, seed: params.from, cwd: ctx.cwd };
  const result = await evaluateWorkflow(request);
  if (result.exit !== 0) {
    throw new Error(result.stderr || result.stdout || `workflow: evaluation failed with exit ${result.exit}`);
  }
  return {
    content: [{ type: "text", text: result.stdout || "ok" }],
    details: result,
  };
}
async function executeApi(tool: string, args: string[]): Promise<{
  content: Array<{ type: "text"; text: string }>;
  details: ApiResult;
}> {
  const api = await loadApi();
  const result = await api.runTool({ tool, args, captureOutput: true })();
  if (result.exit !== 0) {
    throw new Error(result.stderr || result.stdout || emptyFailureMessage(tool, args, result.exit));
  }
  return {
    content: [{ type: "text", text: result.stdout || "ok" }],
    details: result,
  };
}

function emptyFailureMessage(tool: string, args: string[], exit: number): string {
  const operation = args[0] ?? "operation";
  if (tool === "forge" && operation === "supports") {
    return `forge supports ${args[1] ?? "operation"}: not supported`;
  }
  return `${tool} ${operation} failed: exit ${exit} (no output)`;
}

function requireValue(value: string | undefined, field: string, operation: string): string {
  if (value === undefined || value === "") {
    throw new Error(`vcs_write ${operation} requires ${field}`);
  }
  return value;
}

function requireFiles(files: string[] | undefined, operation: string): string[] {
  if (files === undefined || files.length === 0) {
    throw new Error(`vcs_write ${operation} requires at least one file`);
  }
  return files;
}

async function executeForge(
  params: { op: string; args: string[]; body?: string },
  ctx: ToolContext,
): Promise<{
  content: Array<{ type: "text"; text: string }>;
  details: ApiResult;
}> {
  let tempDir: string | undefined;
  try {
    if (params.body !== undefined && !forgeBodyOperations.includes(params.op)) {
      throw new Error(
        `forge ${params.op} does not accept body; body is only valid for pr-create, pr-edit, and pr-comment`,
      );
    }
    let args = params.args;
    if (params.body !== undefined) {
      tempDir = await mkdtemp(join(ctx.cwd, ".agency-forge-"));
      const bodyPath = join(tempDir, "body.md");
      await writeFile(bodyPath, params.body, "utf8");
      args = [...args, "--body-file", bodyPath];
    }
    return await executeApi("forge", [params.op, ...args]);
  } finally {
    if (tempDir !== undefined) {
      await rm(tempDir, { recursive: true, force: true });
    }
  }
}

export default function (pi: ExtensionAPI) {
  const z = pi.zod;

  pi.registerTool({
    name: "vcs_read",
    label: "VCS Read",
    description:
      "Read-only VCS operations. Use args exactly as the semantic vcs-op CLI: detect, remote-url, head-revision, head-commit-sha, default-branch, current-branch, base, dirty, diff-range, diff-names, diff-stat, new-files, log-range, or log-head, followed by any operation arguments such as paths. Fetching belongs to agency_driver sync because it updates remote-tracking refs. " +
      writeInvocationNote('{ "args": [...] }'),
    parameters: z.object({ args: z.array(z.string()) }),
    async execute(_toolCallId, params, _signal, _onUpdate, _ctx) {
      return executeApi("vcs_read", params.args);
    },
  });

  pi.registerTool({
    name: "vcs_write",
    label: "VCS Write",
    description:
      "Mutating VCS operations with operation-specific arguments: branch requires name; commit and fix-commit require message and a non-empty files list; push accepts an optional ref. Do not provide fields from another operation. " +
      writeInvocationNote('{ "op": ..., "message": ... }'),
    parameters: z.union([
      z.object({
        op: z.literal("branch"),
        name: z.string().min(1),
        message: z.undefined().optional(),
        files: z.undefined().optional(),
        ref: z.undefined().optional(),
      }).strict(),
      z.object({
        op: z.literal("commit"),
        message: z.string().min(1),
        files: z.array(z.string().min(1)).min(1),
        name: z.undefined().optional(),
        ref: z.undefined().optional(),
      }).strict(),
      z.object({
        op: z.literal("fix-commit"),
        message: z.string().min(1),
        files: z.array(z.string().min(1)).min(1),
        name: z.undefined().optional(),
        ref: z.undefined().optional(),
      }).strict(),
      z.object({
        op: z.literal("push"),
        ref: z.string().min(1).optional(),
        name: z.undefined().optional(),
        message: z.undefined().optional(),
        files: z.undefined().optional(),
      }).strict(),
    ]),
    async execute(_toolCallId, params, _signal, _onUpdate, _ctx) {
      if (params.op === "branch") {
        return executeApi("vcs_write", ["branch", requireValue(params.name, "name", params.op)]);
      }
      if (params.op === "push") {
        return executeApi("vcs_write", ["push", ...(params.ref === undefined ? [] : [params.ref])]);
      }
      const message = requireValue(params.message, "message", params.op);
      const files = requireFiles(params.files, params.op);
      return executeApi("vcs_write", [params.op, message, ...files]);
    },
  });

  pi.registerTool({
    name: "forge",
    label: "Forge",
    description:
      "Forge operations over the detected remote host. Use op detect, supports, pr-view, pr-create, pr-edit, pr-comment, issue-view, or pr-checks; pass forge CLI flags in args. The body field is only valid for pr-create, pr-edit, and pr-comment. " +
      writeInvocationNote('{ "op": ..., "args": [...] }'),
    parameters: z.union([
      z.object({
        op: z.literal("detect"),
        args: z.array(z.string()),
        body: z.undefined().optional(),
      }).strict(),
      z.object({
        op: z.literal("supports"),
        args: z.array(z.string()),
        body: z.undefined().optional(),
      }).strict(),
      z.object({
        op: z.literal("pr-view"),
        args: z.array(z.string()),
        body: z.undefined().optional(),
      }).strict(),
      z.object({
        op: z.literal("pr-create"),
        args: z.array(z.string()),
        body: z.string().optional(),
      }).strict(),
      z.object({
        op: z.literal("pr-edit"),
        args: z.array(z.string()),
        body: z.string().optional(),
      }).strict(),
      z.object({
        op: z.literal("pr-comment"),
        args: z.array(z.string()),
        body: z.string().optional(),
      }).strict(),
      z.object({
        op: z.literal("issue-view"),
        args: z.array(z.string()),
        body: z.undefined().optional(),
      }).strict(),
      z.object({
        op: z.literal("pr-checks"),
        args: z.array(z.string()),
        body: z.undefined().optional(),
      }).strict(),
    ]),
    async execute(_toolCallId, params, _signal, _onUpdate, ctx) {
      return executeForge(params, ctx);
    },
  });

  pi.registerTool({
    name: "workflow",
    label: "Workflow",
    description:
      "Evaluate the Nickel /do workflow. Use field cli for the next-step decision or cli_seed with a declared workflow entry point to seed/resume from that entry point. " +
      writeInvocationNote('{ "field": "cli" }'),
    parameters: z.union([
      z.object({
        field: z.literal("cli"),
        from: z.undefined().optional(),
      }).strict(),
      z.object({
        field: z.literal("cli_seed"),
        from: z.enum(workflowEntryPoints),
      }).strict(),
    ]),
    async execute(_toolCallId, params, _signal, _onUpdate, ctx) {
      if (params.field === "cli") {
        return executeWorkflow({ field: params.field }, ctx);
      }
      return executeWorkflow({ field: params.field, from: params.from }, ctx);
    },
  });

  pi.registerTool({
    name: "agency_driver",
    label: "Agency Driver",
    description:
      'Advance or inspect /do workflow state through the existing driver and results parsers. op selects one of init, start, end, skip, set, summary, sync, step-start, step-end, or step; args contains only that operation\'s operands and must not repeat op (for example, { op: "sync", args: ["false"] } or { op: "start", args: ["research"] }). ' +
      writeInvocationNote('{ "op": ..., "args": [...] }'),
    parameters: z.object({
      op: z.enum(["init", "start", "end", "skip", "set", "summary", "sync", "step-start", "step-end", "step"]),
      args: z.array(z.string()),
    }),
    async execute(_toolCallId, params, _signal, _onUpdate, _ctx) {
      return executeApi("agency_driver", [params.op, ...params.args]);
    },
  });

  pi.on("context", event => {
    const rewritten = rewriteDeviceFieldHoistErrors(event.messages);
    return rewritten ? { messages: rewritten } : undefined;
  });
}
