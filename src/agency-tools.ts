import type { ExtensionAPI } from "@oh-my-pi/pi-coding-agent";
import { mkdtemp, rm, writeFile } from "node:fs/promises";
import { join } from "node:path";
import { evaluateWorkflow } from "../nickel-vm/scripts/workflow-runtime.mjs";
import { workflowEntryPoints, workflowSteps } from "./workflow-vocabulary.js";
import { toolResult, renderResult, describeResult } from "./tool-results.js";

type ApiRequest = {
  tool: string;
  args: string[];
  captureOutput: boolean;
};

type ApiResult = {
  exit: number;
  stdout: string;
  stderr: string;
  value: unknown;
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

async function executeApi(tool: string, args: string[]) {
  const api = await loadApi();
  const result = await api.runTool({ tool, args, captureOutput: true })();
  if (result.exit !== 0) {
    throw new Error(result.stderr || result.stdout || emptyFailureMessage(tool, args, result.exit));
  }
  return toolResult(args[0], result);
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
  const selector = text.regex(/^[^-]/, "A selector cannot be a CLI flag");
  const strings = z.array(text);
  const step = z.enum(workflowSteps);
  const status = z.enum(["passed", "failed", "skipped"]);

  pi.registerTool({
    name: "vcs_read",
    label: "VCS Read",
    renderResult,
    describeResult,
    description:
      "Read-only VCS operations selected by op. Diff, new-files, and log-range optionally filter paths. dirty reports clean/dirty/no-vcs status, not a file list; these are successful results, while inspection errors fail. working-copy-status reports the working-copy changes for supported Git/jj repositories. head-revision/current-branch return the current branch/bookmark (under jj, on @ or its parent); head-commit-sha returns the feature commit CI will run against. Sync owns fetching. No raw CLI arguments are accepted.",
    parameters: z.union([
      z.object({ op: z.enum(["detect", "remote-url", "head-revision", "head-commit-sha", "default-branch", "current-branch", "base", "dirty", "working-copy-status", "log-head"]) }).strict(),
      z.object({ op: z.enum(["diff-range", "diff-names", "diff-stat", "new-files", "log-range"]), paths: strings.optional() }).strict(),
    ]),
    async execute(_toolCallId, params) {
      return executeApi("vcs_read", [params.op, ...("paths" in params ? params.paths ?? [] : [])]);
    },
  });

  pi.registerTool({
    name: "vcs_write",
    label: "VCS Write",
    renderResult,
    describeResult,
    description:
      "Mutating VCS operations: branch requires name; commit/fix-commit require message and files; push accepts ref. Only files the caller actually changed may be committed. Fields from other operations are rejected.",
    parameters: z.union([
      z.object({ op: z.literal("branch"), name: text }).strict(),
      z.object({ op: z.enum(["commit", "fix-commit"]), message: text, files: strings.min(1) }).strict(),
      z.object({ op: z.literal("push"), ref: selector.optional() }).strict(),
    ]),
    async execute(_toolCallId, params) {
      if (params.op === "branch") return executeApi("vcs_write", [params.op, params.name]);
      if (params.op === "push") return executeApi("vcs_write", [params.op, ...(params.ref === undefined ? [] : [params.ref])]);
      return executeApi("vcs_write", [params.op, params.message, ...params.files]);
    },
  });

  // GitHub's CLI vocabulary is a provider extension, not part of the neutral
  // operation fields. Each option owns its schema and lowering flag together.
  function githubOptions<Fields extends Record<string, { schema: Parameters<typeof z.object>[0][string]; flag: string }>>(fields: Fields) {
    const entries = Object.entries(fields);
    const shape = Object.fromEntries(entries.map(([name, field]) => [name, field.schema])) as {
      [Name in keyof Fields]: Fields[Name]["schema"];
    };
    return {
      schema: z.object(shape).strict().optional(),
      append(args: string[], values: Record<string, Parameters<typeof option>[2]> | undefined) {
        if (values === undefined) return;
        for (const [name, field] of entries) option(args, field.flag, values[name]);
      },
    };
  }
  const githubOutput = githubOptions({
    jq: { schema: text.optional(), flag: "--jq" },
    template: { schema: text.optional(), flag: "--template" },
  });
  const githubCreate = githubOptions({
    fill: { schema: z.boolean().optional(), flag: "--fill" },
    fillFirst: { schema: z.boolean().optional(), flag: "--fill-first" },
    fillVerbose: { schema: z.boolean().optional(), flag: "--fill-verbose" },
    noMaintainerEdit: { schema: z.boolean().optional(), flag: "--no-maintainer-edit" },
    editor: { schema: z.boolean().optional(), flag: "--editor" },
    web: { schema: z.boolean().optional(), flag: "--web" },
    recover: { schema: text.optional(), flag: "--recover" },
    templateFile: { schema: text.optional(), flag: "--template" },
    dryRun: { schema: z.boolean().optional(), flag: "--dry-run" },
  });
  const githubComment = githubOptions({
    editor: { schema: z.boolean().optional(), flag: "--editor" },
    web: { schema: z.boolean().optional(), flag: "--web" },
    yes: { schema: z.boolean().optional(), flag: "--yes" },
  });
  const outputFields = {
    repo: text.optional(), json: strings.min(1).optional(), web: z.boolean().optional(), github: githubOutput.schema,
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
    renderResult,
    describeResult,
    description:
      "Forge operations with named fields, never CLI flags. pr/issue identify a number, URL, or (PR only) branch; absent pr selects the current branch. JSON field names are supplied as a list. body and bodyFile are mutually exclusive. GitHub-only options such as jq, commit-based fill, and editor flows belong in github. Backend capability checks remain authoritative.",
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
      bodyOperation({
        op: z.literal("pr-create"), repo: text.optional(), title: text.optional(), ...bodyFields,
        base: text.optional(), head: text.optional(), draft: z.boolean().optional(),
        reviewers: strings.optional(), assignees: strings.optional(), labels: strings.optional(), projects: strings.optional(),
        milestone: text.optional(), github: githubCreate.schema,
      }),
      bodyOperation({
        op: z.literal("pr-edit"), pr: selector.optional(), repo: text.optional(), title: text.optional(), ...bodyFields,
        base: text.optional(), milestone: text.optional(), removeMilestone: z.boolean().optional(),
        addAssignees: strings.optional(), removeAssignees: strings.optional(),
        addLabels: strings.optional(), removeLabels: strings.optional(),
        addProjects: strings.optional(), removeProjects: strings.optional(),
        addReviewers: strings.optional(), removeReviewers: strings.optional(),
      }),
      bodyOperation({
        op: z.literal("pr-comment"), pr: selector.optional(), repo: text.optional(), ...bodyFields,
        editLast: z.boolean().optional(), deleteLast: z.boolean().optional(), createIfNone: z.boolean().optional(),
        github: githubComment.schema,
      }),
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
          githubOutput.append(args, params.github);
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
          githubCreate.append(args, params.github);
          option(args, "--reviewer", params.reviewers);
          option(args, "--assignee", params.assignees);
          option(args, "--label", params.labels);
          option(args, "--project", params.projects);
          option(args, "--milestone", params.milestone);
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
          githubComment.append(args, params.github);
          break;
      }
      option(args, "--body-file", "bodyFile" in params ? params.bodyFile : undefined);
      option(args, "--attach", params.attachments);
      return executeForge(params.op, args, "body" in params ? params.body : undefined, ctx);
    },
  });

  const cliField = "cli";
  const cliSeedField = "cli_seed";
  const cliShape = { field: z.literal(cliField) };
  const cliSeedShape = { field: z.literal(cliSeedField), from: z.enum(workflowEntryPoints) };
  // The one rule for unrecognized keys across both arms: each arm's own shape
  // owns the recognized set (plus `from`, which the cli hint owns), and the cli
  // arm's sibling-arm guidance precedes the key enumeration in the same single
  // issue. It runs as the union's refinement, so a misspelled `field` never
  // sees the hint — the arms' literals reject it first.
  function checkWorkflowKeys(
    value: Record<string, unknown>,
    ctx: { addIssue(issue: { message: string }): void },
  ): void {
    const cli = value.field === cliField;
    const knownKeys = cli ? [...Object.keys(cliShape), "from"] : Object.keys(cliSeedShape);
    const hint = cli && Object.hasOwn(value, "from")
      ? `cli takes no "from"; use the sibling arm { field: "${cliSeedField}", from: <entry point> } to supply one`
      : undefined;
    const others = Object.keys(value).filter(key => !knownKeys.includes(key));
    const parts = [hint, others.length > 0 ? `unrecognized keys: ${others.map(JSON.stringify).join(", ")}` : undefined]
      .filter((part): part is string => part !== undefined);
    if (parts.length > 0) ctx.addIssue({ message: parts.join("; ") });
  }
  const workflowArms = z.union([z.object(cliShape).passthrough(), z.object(cliSeedShape).passthrough()]);
  const workflowJson = workflowArms.toJsonSchema() as { anyOf: Array<Record<string, unknown>> };
  pi.registerTool({
    name: "workflow",
    label: "Workflow",
    renderResult,
    describeResult,
    description:
      "Evaluate the Nickel /do workflow. Use field cli for the next-step decision or cli_seed with a declared entry point to seed/resume.",
    // The model-facing schema stays closed like the deleted `.strict()` arms
    // (each emitted arm carries additionalProperties: false) while the runtime
    // refinement names unrecognized keys in one issue. The emission override
    // wraps the union whose members stay pure, so union errors keep routing
    // through the `field` discriminant to the aimed arm.
    parameters: pi.arktype.withJsonSchema(workflowArms.superRefine(checkWorkflowKeys), {
      ...workflowJson,
      anyOf: workflowJson.anyOf.map(arm => ({ ...arm, additionalProperties: false })),
    }),
    async execute(_toolCallId, params, _signal, _onUpdate, ctx) {
      const request = params.field === cliField
        ? { operation: cliField, cwd: ctx.cwd }
        : { operation: cliSeedField, seed: params.from, cwd: ctx.cwd };
      const result = await evaluateWorkflow(request);
      if (result.exit !== 0) {
        throw new Error(result.stderr || result.stdout || `workflow: evaluation failed with exit ${result.exit}`);
      }
      return toolResult(params.field, result);
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
    requireRemote: boolean,
    active: z.enum(["idle", "working", "waiting"]),
    status: z.enum(["idle", "running", "completed", "failed"]),
    from: z.enum(workflowEntryPoints), steps: z.array(recordedStep), pendingStep: pendingStep.nullable(),
    // The jobs ledger is driver-owned (job-start/job-end only): a value
    // schema that always rejects keeps it out of custom string fields and
    // makes every set spelling unparseable. The wire schema says the same
    // (`not: {}`), as the deleted z.never() emitted.
    jobs: pi.arktype.withJsonSchema(
      z.unknown().refine(() => false, "never set directly; the jobs ledger is driver-owned (job-start/job-end only)"),
      { not: {} },
    ),
  };

  pi.registerTool({
    name: "agency_driver",
    label: "Agency Driver",
    renderResult,
    describeResult,
    description:
      "Advance/inspect /do state with operation-specific named fields. init accepts task/review/noVcs/minimal/restart/from; base and stack belong to sync and are mutually exclusive. start/skip use step; end uses status/verification/reason. job-start records a bounded worker job (id/name/step, optional budgetMinutes 1-120, driver-computed timestamps); job-end resolves it with an outcome plus optional verification. set takes typed value: booleans for capability/options, structured values for steps/pendingStep, strings for custom fields; the jobs ledger itself is never set directly. Step names and entry points come from the workflow manifest. No raw CLI args.",
    parameters: z.union([
      z.object({
        op: z.literal("init"), task: text.refine(value => !value.startsWith("--"), "Task must not be a CLI flag").optional(),
        review: z.boolean().optional(), noVcs: z.boolean().optional(), minimal: z.boolean().optional(),
        restart: z.boolean().optional(), from: z.enum(workflowEntryPoints).optional(),
      }).strict().refine(value => !value.review || value.from === undefined || value.from === "default", "review requires the default entry point"),
      z.object({ op: z.enum(["start", "step-start"]), step }).strict(),
      z.object({ op: z.enum(["end", "step-end"]), ...completion }).strict(),
      z.object({ op: z.literal("skip"), step, reason: text }).strict(),
      z.object({
        op: z.literal("job-start"), id: text, name: text, step,
        budgetMinutes: z.number().int().min(1).max(120).optional(),
      }).strict(),
      z.object({
        op: z.literal("job-end"), id: text,
        outcome: z.enum(["completed", "failed", "cancelled", "escalated"]),
        // The driver maps "" to absent, so an empty reason would fail the
        // non-completed outcome rule only after passing the schema — the
        // contract must reject it up front instead.
        verification: z.string().min(1).optional(),
      }).strict(),
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
        case "job-start":
          args.push(params.id, params.name, params.step);
          if (params.budgetMinutes !== undefined) args.push(String(params.budgetMinutes));
          break;
        case "job-end":
          args.push(params.id, params.outcome);
          if (params.verification !== undefined) args.push(params.verification);
          break;
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

