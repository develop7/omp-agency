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
  if (tool === "vcs_read" && operation === "dirty") {
    return "vcs_read dirty: working copy clean";
  }
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
      "Read-only VCS operations. Use args exactly as the semantic vcs-op CLI: detect, remote-url, head-revision, head-commit-sha, default-branch, current-branch, base, dirty, diff-range, diff-names, diff-stat, new-files, log-range, or log-head, followed by any operation arguments such as paths. Fetching belongs to agency_driver sync because it updates remote-tracking refs.",
    parameters: z.object({ args: z.array(z.string()) }),
    async execute(_toolCallId, params, _signal, _onUpdate, _ctx) {
      return executeApi("vcs_read", params.args);
    },
  });

  pi.registerTool({
    name: "vcs_write",
    label: "VCS Write",
    description:
      "Mutating VCS operations with operation-specific arguments: branch requires name; commit and fix-commit require message and a non-empty files list; push accepts an optional ref. Do not provide fields from another operation.",
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
      "Forge operations over the detected remote host. Use op detect, supports, pr-view, pr-create, pr-edit, pr-comment, issue-view, or pr-checks; pass forge CLI flags in args. The body field is only valid for pr-create, pr-edit, and pr-comment.",
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
      "Evaluate the Nickel /do workflow. Use field cli for the next-step decision or cli_seed with a declared workflow entry point to seed/resume from that entry point.",
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
      "Advance or inspect /do workflow state through the existing driver and results parsers. op selects one of init, start, end, skip, set, summary, sync, step-start, step-end, or step; args contains only that operation's operands and must not repeat op (for example, { op: \"sync\", args: [\"false\"] } or { op: \"start\", args: [\"research\"] }).",
    parameters: z.object({
      op: z.enum(["init", "start", "end", "skip", "set", "summary", "sync", "step-start", "step-end", "step"]),
      args: z.array(z.string()),
    }),
    async execute(_toolCallId, params, _signal, _onUpdate, _ctx) {
      return executeApi("agency_driver", [params.op, ...params.args]);
    },
  });
}
