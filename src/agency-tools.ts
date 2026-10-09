import type { ExtensionAPI } from "@oh-my-pi/pi-coding-agent";
import { mkdtemp, rm, writeFile } from "node:fs/promises";
import { join } from "node:path";
import { evaluateWorkflow } from "../nickel-vm/scripts/workflow-runtime.mjs";
import { workflowEntryPoints, workflowSteps } from "./workflow-vocabulary.js";

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

// Lower typed option values into the existing CLI parser's operands. Lists remain
// lists of values; models never supply flag syntax or positional argument vectors.
function option(args: string[], flag: string, value: string | number | boolean | string[] | undefined): void {
  if (value === undefined || value === false) return;
  if (value === true) args.push(flag);
  else if (Array.isArray(value)) {
    for (const item of value) args.push(flag, item);
  } else args.push(flag, String(value));
}

async function executeForge(op: string, args: string[], body: string | undefined, ctx: ToolContext) {
  let tempDir: string | undefined;
  try {
    if (body !== undefined) {
      tempDir = await mkdtemp(join(ctx.cwd, ".agency-forge-"));
      const bodyPath = join(tempDir, "body.md");
      await writeFile(bodyPath, body, "utf8");
      args.push("--body-file", bodyPath);
    }
    return await executeApi("forge", [op, ...args]);
  } finally {
    if (tempDir !== undefined) await rm(tempDir, { recursive: true, force: true });
  }
}

/** Register the model-facing contracts; the shared core retains semantic validation. */
export default function (pi: ExtensionAPI) {
  const z = pi.zod;
  const text = z.string().min(1);
  const strings = z.array(text);
  const step = z.enum(workflowSteps);
  const status = z.enum(["passed", "failed", "skipped"]);

  pi.registerTool({
    name: "vcs_read",
    label: "VCS Read",
    description:
      "Read-only VCS operations selected by op. Diff, new-files, and log-range optionally filter paths. head-revision/current-branch return the current branch/bookmark (under jj, on @ or its parent); head-commit-sha returns the feature commit CI will run against. Sync owns fetching. No raw CLI arguments are accepted.",
    parameters: z.union([
      z.object({ op: z.enum(["detect", "remote-url", "head-revision", "head-commit-sha", "default-branch", "current-branch", "base", "dirty", "log-head"]) }).strict(),
      z.object({ op: z.enum(["diff-range", "diff-names", "diff-stat", "new-files", "log-range"]), paths: strings.optional() }).strict(),
    ]),
    async execute(_toolCallId, params) {
      return executeApi("vcs_read", [params.op, ...("paths" in params ? params.paths ?? [] : [])]);
    },
  });

  pi.registerTool({
    name: "vcs_write",
    label: "VCS Write",
    description:
      "Mutating VCS operations: branch requires name; commit/fix-commit require message and files; push accepts ref. Only files the caller actually changed may be committed. Fields from other operations are rejected.",
    parameters: z.union([
      z.object({ op: z.literal("branch"), name: text }).strict(),
      z.object({ op: z.enum(["commit", "fix-commit"]), message: text, files: strings.min(1) }).strict(),
      z.object({ op: z.literal("push"), ref: text.optional() }).strict(),
    ]),
    async execute(_toolCallId, params) {
      if (params.op === "branch") return executeApi("vcs_write", [params.op, params.name]);
      if (params.op === "push") return executeApi("vcs_write", [params.op, ...(params.ref === undefined ? [] : [params.ref])]);
      return executeApi("vcs_write", [params.op, params.message, ...params.files]);
    },
  });

  const selector = text.refine(value => !value.startsWith("-"), "A selector cannot be a CLI flag");
  const outputFields = {
    repo: text.optional(), json: strings.min(1).optional(), jq: text.optional(),
    template: text.optional(), web: z.boolean().optional(),
  };
  const bodyFields = { attachments: strings.optional() };
  // Body alternatives are distinct closed shapes, so exclusivity is visible
  // to both runtime validation and the model-facing JSON Schema.
  function bodyOperation<Shape extends Parameters<typeof z.object>[0]>(shape: Shape) {
    return z.union([
      z.object({ ...shape, body: z.string() }).strict(),
      z.object({ ...shape, bodyFile: text }).strict(),
      z.object(shape).strict(),
    ]);
  }

  pi.registerTool({
    name: "forge",
    label: "Forge",
    description:
      "Forge operations with named fields, never CLI flags. pr/issue identify a number, URL, or (PR only) branch; absent pr selects the current branch. JSON field names are supplied as a list. body and bodyFile are mutually exclusive. Attachments are file paths, optionally suffixed with #alt text. Backend capability checks remain authoritative.",
    parameters: z.union([
      z.object({ op: z.literal("detect") }).strict(),
      z.object({ op: z.literal("supports"), operation: text }).strict(),
      z.object({ op: z.literal("pr-view"), pr: selector.optional(), comments: z.boolean().optional(), ...outputFields }).strict(),
      z.object({ op: z.literal("issue-view"), issue: selector, comments: z.boolean().optional(), ...outputFields }).strict(),
      z.object({
        op: z.literal("pr-checks"), pr: selector.optional(), ...outputFields,
        watch: z.boolean().optional(), required: z.boolean().optional(),
        failFast: z.boolean().optional(), interval: z.number().int().positive().optional(),
      }).strict(),
      bodyOperation({ op: z.literal("pr-create"), repo: text.optional(), title: text.optional(), ...bodyFields,
      base: text.optional(), head: text.optional(), draft: z.boolean().optional(),
      fill: z.boolean().optional(), fillFirst: z.boolean().optional(), fillVerbose: z.boolean().optional(),
      reviewers: strings.optional(), assignees: strings.optional(), labels: strings.optional(), projects: strings.optional(),
      milestone: text.optional(), noMaintainerEdit: z.boolean().optional(),
      editor: z.boolean().optional(), web: z.boolean().optional(), recover: text.optional(),
      templateFile: text.optional(), dryRun: z.boolean().optional(), }),
      bodyOperation({ op: z.literal("pr-edit"), pr: selector.optional(), repo: text.optional(), title: text.optional(), ...bodyFields,
      base: text.optional(), milestone: text.optional(), removeMilestone: z.boolean().optional(),
      addAssignees: strings.optional(), removeAssignees: strings.optional(),
      addLabels: strings.optional(), removeLabels: strings.optional(),
      addProjects: strings.optional(), removeProjects: strings.optional(),
      addReviewers: strings.optional(), removeReviewers: strings.optional(), }),
      bodyOperation({ op: z.literal("pr-comment"), pr: selector.optional(), repo: text.optional(), ...bodyFields,
      editLast: z.boolean().optional(), deleteLast: z.boolean().optional(), createIfNone: z.boolean().optional(),
      editor: z.boolean().optional(), web: z.boolean().optional(), yes: z.boolean().optional(), }),
    ]),
    async execute(_toolCallId, params, _signal, _onUpdate, ctx) {
      const args: string[] = [];
      if (params.op === "detect") return executeApi("forge", [params.op]);
      if (params.op === "supports") return executeApi("forge", [params.op, params.operation]);
      if ("pr" in params && params.pr !== undefined) args.push(params.pr);
      if (params.op === "issue-view") args.push(params.issue);
      option(args, "--repo", params.repo);
      switch (params.op) {
        case "pr-view": case "issue-view": case "pr-checks":
          option(args, "--json", params.json?.join(","));
          option(args, "--jq", params.jq);
          option(args, "--template", params.template);
          option(args, "--web", params.web);
          if (params.op === "pr-checks") {
            option(args, "--watch", params.watch);
            option(args, "--required", params.required);
            option(args, "--fail-fast", params.failFast);
            option(args, "--interval", params.interval);
          } else option(args, "--comments", params.comments);
          return executeApi("forge", [params.op, ...args]);
        case "pr-create":
          option(args, "--title", params.title);
          option(args, "--base", params.base);
          option(args, "--head", params.head);
          option(args, "--draft", params.draft);
          option(args, "--fill", params.fill);
          option(args, "--fill-first", params.fillFirst);
          option(args, "--fill-verbose", params.fillVerbose);
          option(args, "--reviewer", params.reviewers);
          option(args, "--assignee", params.assignees);
          option(args, "--label", params.labels);
          option(args, "--project", params.projects);
          option(args, "--milestone", params.milestone);
          option(args, "--no-maintainer-edit", params.noMaintainerEdit);
          option(args, "--editor", params.editor);
          option(args, "--web", params.web);
          option(args, "--recover", params.recover);
          option(args, "--template", params.templateFile);
          option(args, "--dry-run", params.dryRun);
          break;
        case "pr-edit":
          option(args, "--title", params.title);
          option(args, "--base", params.base);
          option(args, "--milestone", params.milestone);
          option(args, "--remove-milestone", params.removeMilestone);
          option(args, "--add-assignee", params.addAssignees);
          option(args, "--remove-assignee", params.removeAssignees);
          option(args, "--add-label", params.addLabels);
          option(args, "--remove-label", params.removeLabels);
          option(args, "--add-project", params.addProjects);
          option(args, "--remove-project", params.removeProjects);
          option(args, "--add-reviewer", params.addReviewers);
          option(args, "--remove-reviewer", params.removeReviewers);
          break;
        case "pr-comment":
          option(args, "--edit-last", params.editLast);
          option(args, "--delete-last", params.deleteLast);
          option(args, "--create-if-none", params.createIfNone);
          option(args, "--editor", params.editor);
          option(args, "--web", params.web);
          option(args, "--yes", params.yes);
          break;
      }
      option(args, "--body-file", "bodyFile" in params ? params.bodyFile : undefined);
      option(args, "--attach", params.attachments);
      return executeForge(params.op, args, "body" in params ? params.body : undefined, ctx);
    },
  });

  pi.registerTool({
    name: "workflow",
    label: "Workflow",
    description:
      "Evaluate the Nickel /do workflow. Use field cli for the next-step decision or cli_seed with a declared entry point to seed/resume.",
    parameters: z.union([
      z.object({ field: z.literal("cli") }).strict(),
      z.object({ field: z.literal("cli_seed"), from: z.enum(workflowEntryPoints) }).strict(),
    ]),
    async execute(_toolCallId, params, _signal, _onUpdate, ctx) {
      return executeWorkflow(params, ctx);
    },
  });

  const boolean = z.boolean();
  const recordedStep = z.object({
    name: step, status, verification: z.string(), startedAt: text, completedAt: text, reason: text.optional(),
  }).strict();
  const pendingStep = z.object({ name: step, startedAt: text }).strict();
  const completion = { status, verification: z.string().optional(), reason: text.optional() };
  // These keys define both the typed cases and the custom-field exclusion.
  const stateValues = {
    review: boolean, noVcs: boolean, minimal: boolean, hasEvidence: boolean,
    supportsPrCreate: boolean, supportsPrComment: boolean, supportsIssueView: boolean, supportsPrChecks: boolean,
    active: z.enum(["idle", "working", "waiting"]),
    status: z.enum(["idle", "running", "completed", "failed"]),
    from: z.enum(workflowEntryPoints), steps: z.array(recordedStep), pendingStep: pendingStep.nullable(),
  };

  pi.registerTool({
    name: "agency_driver",
    label: "Agency Driver",
    description:
      "Advance/inspect /do state with operation-specific named fields. init accepts task/review/noVcs/minimal/restart/from; base and stack belong to sync and are mutually exclusive. start/skip use step; end uses status/verification/reason. set takes typed value: booleans for capability/options, structured values for steps/pendingStep, strings for custom fields. Step names and entry points come from the workflow manifest. No raw CLI args.",
    parameters: z.union([
      z.object({
        op: z.literal("init"), task: text.refine(value => !value.startsWith("--"), "Task must not be a CLI flag").optional(),
        review: z.boolean().optional(), noVcs: z.boolean().optional(), minimal: z.boolean().optional(),
        restart: z.boolean().optional(), from: z.enum(workflowEntryPoints).optional(),
      }).strict().refine(value => !value.review || value.from === undefined || value.from === "default", "review requires the default entry point"),
      z.object({ op: z.enum(["start", "step-start"]), step }).strict(),
      z.object({ op: z.enum(["end", "step-end"]), ...completion }).strict(),
      z.object({ op: z.literal("skip"), step, reason: text }).strict(),
      z.object({ op: z.literal("summary") }).strict(),
      z.object({ op: z.literal("sync"), noVcs: z.boolean() }).strict(),
      z.object({ op: z.literal("sync"), noVcs: z.literal(false), base: text }).strict(),
      z.object({ op: z.literal("sync"), noVcs: z.literal(false), stack: z.literal(true) }).strict(),
      ...Object.entries(stateValues).map(([field, value]) =>
        z.object({ op: z.literal("set"), field: z.literal(field), value }).strict()),
      // State intentionally supports additional string fields. Exclude typed
      // fields here so malformed typed values cannot fall through to this arm.
      z.object({ op: z.literal("set"), field: text.refine(value => !Object.hasOwn(stateValues, value), "Use the typed value for this field"), value: text }).strict(),
      z.object({ op: z.literal("step"), step, status, verification: z.string(), startedAt: text, completedAt: text, reason: text.optional() }).strict(),
    ]),
    async execute(_toolCallId, params) {
      const args: string[] = [params.op];
      switch (params.op) {
        case "init":
          option(args, "--review", params.review);
          option(args, "--no-vcs", params.noVcs);
          option(args, "--minimal", params.minimal);
          option(args, "--restart", params.restart);
          if (params.from !== undefined) args.push("--from=" + params.from);
          if (params.task !== undefined) args.push(params.task);
          break;
        case "start": case "step-start": args.push(params.step); break;
        case "end": case "step-end":
          args.push(params.status);
          if (params.verification !== undefined || params.reason !== undefined) args.push(params.verification ?? "");
          if (params.reason !== undefined) args.push(params.reason);
          break;
        case "skip": args.push(params.step, params.reason); break;
        case "summary": break;
        case "sync":
          args.push(String(params.noVcs));
          option(args, "--base", "base" in params ? params.base : undefined);
          option(args, "--stack", "stack" in params ? params.stack : undefined);
          break;
        case "set":
          args.push(params.field, typeof params.value === "string" ? params.value : JSON.stringify(params.value));
          break;
        case "step":
          args.push(params.step, params.status, params.verification, params.startedAt, params.completedAt);
          if (params.reason !== undefined) args.push(params.reason);
          break;
      }
      return executeApi("agency_driver", args);
    },
  });
}

