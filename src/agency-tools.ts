import type { ExtensionAPI } from "@oh-my-pi/pi-coding-agent";
import { mkdtemp, rm, writeFile } from "node:fs/promises";
import { join } from "node:path";

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

let apiPromise: Promise<AgencyApi> | undefined;

async function loadApi(): Promise<AgencyApi> {
  apiPromise ??= import("../pure/dist/agency-api.js") as unknown as Promise<AgencyApi>;
  return apiPromise;
}

async function executeApi(tool: string, args: string[]): Promise<{
  content: Array<{ type: "text"; text: string }>;
  details: ApiResult;
}> {
  const api = await loadApi();
  const result = await api.runTool({ tool, args, captureOutput: true })();
  if (result.exit !== 0) {
    throw new Error(result.stderr || result.stdout);
  }
  return {
    content: [{ type: "text", text: result.stdout || "ok" }],
    details: result,
  };
}

function requireValue(value: string | undefined, field: string, operation: string): string {
  if (value === undefined || value === "") {
    throw new Error(`vcs_write ${operation} requires ${field}`);
  }
  return value;
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
      "Read-only VCS operations. Use args exactly as the semantic vcs-op CLI: detect, fetch, remote-url, head-revision, head-commit-sha, default-branch, current-branch, base, dirty, diff-range, diff-names, diff-stat, new-files, log-range, or log-head, followed by any operation arguments such as paths.",
    parameters: z.object({ args: z.array(z.string()) }),
    async execute(_toolCallId, params, _signal, _onUpdate, _ctx) {
      return executeApi("vcs_read", params.args);
    },
  });

  pi.registerTool({
    name: "vcs_write",
    label: "VCS Write",
    description:
      "Mutating VCS operations with critical arguments hoisted into a schema. branch requires name as the new branch/bookmark name; commit and fix-commit require message and files; push accepts an optional ref.",
    parameters: z.object({
      op: z.enum(["branch", "commit", "push", "fix-commit"]),
      message: z.string().optional(),
      files: z.array(z.string()).optional(),
      ref: z.string().optional(),
      name: z.string().optional(),
    }),
    async execute(_toolCallId, params, _signal, _onUpdate, _ctx) {
      if (params.op === "branch") {
        return executeApi("vcs_write", ["branch", requireValue(params.name, "name", params.op)]);
      }
      if (params.op === "push") {
        return executeApi("vcs_write", ["push", ...(params.ref === undefined ? [] : [params.ref])]);
      }
      const message = requireValue(params.message, "message", params.op);
      if (params.files === undefined) {
        throw new Error(`vcs_write ${params.op} requires files`);
      }
      return executeApi("vcs_write", [params.op, message, ...params.files]);
    },
  });

  pi.registerTool({
    name: "forge",
    label: "Forge",
    description:
      "Forge operations over the detected remote host. Use op detect or supports, pr-view, pr-create, pr-edit, pr-comment, issue-view, or pr-checks; pass forge CLI flags in args. Supply body for body-bearing operations instead of constructing a body-file argument.",
    parameters: z.object({
      op: z.enum(["detect", "supports", "pr-view", "pr-create", "pr-edit", "pr-comment", "issue-view", "pr-checks"]),
      args: z.array(z.string()),
      body: z.string().optional(),
    }),
    async execute(_toolCallId, params, _signal, _onUpdate, ctx) {
      return executeForge(params, ctx);
    },
  });

  pi.registerTool({
    name: "workflow",
    label: "Workflow",
    description:
      "Evaluate the Nickel /do workflow. field cli returns the next-step decision for .do-results.json; field cli_seed requires from when seeding or resuming a workflow.",
    parameters: z.object({
      field: z.enum(["cli", "cli_seed"]),
      from: z.string().optional(),
    }),
    async execute(_toolCallId, params, _signal, _onUpdate, _ctx) {
      if (params.field === "cli" && params.from !== undefined) {
        throw new Error("workflow: from is only valid with cli_seed");
      }
      return executeApi("workflow", [params.field, ...(params.from === undefined ? [] : [params.from])]);
    },
  });

  pi.registerTool({
    name: "agency_driver",
    label: "Agency Driver",
    description:
      "Advance or inspect /do workflow state through the existing driver and results parsers. op is one of init, start, end, skip, set, summary, sync, step-start, step-end, or step; args are the exact remaining CLI arguments for that operation.",
    parameters: z.object({
      op: z.enum(["init", "start", "end", "skip", "set", "summary", "sync", "step-start", "step-end", "step"]),
      args: z.array(z.string()),
    }),
    async execute(_toolCallId, params, _signal, _onUpdate, _ctx) {
      return executeApi("agency_driver", [params.op, ...params.args]);
    },
  });
}
