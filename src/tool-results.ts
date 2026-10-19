import { stripVTControlCharacters } from "node:util";
import wrapAnsi from "wrap-ansi";
import type { Component } from "@oh-my-pi/pi-tui";
import type { NativeToolView, ToolRenderResult, RenderResultOptions } from "@oh-my-pi/pi-tui/tools/renderer";

/** Operation identity and its opaque semantic result; null means no inline value. */
export type ToolDetails = { op: string; value: unknown };
type Result = ToolRenderResult<ToolDetails>;
const maxDetailsBytes = 32 * 1024;

/** The full value reaches the model; only small values are duplicated in history details. */
export function toolResult(op: string, result: { stdout: string; value: unknown }) {
  const json = result.value === null ? undefined : JSON.stringify(result.value, null, 2);
  const text = json === undefined ? result.stdout || "ok"
    : typeof result.value === "string" ? result.value : `\`\`\`json\n${json}\n\`\`\``;
  return {
    content: [{ type: "text" as const, text }],
    details: { op, value: json !== undefined && Buffer.byteLength(json) <= maxDetailsBytes ? result.value : null },
    ...(Array.isArray(result.value) && result.value.length === 0 ? { useless: true } : {}),
  };
}

function record(value: unknown): value is Record<string, unknown> {
  return value !== null && typeof value === "object" && !Array.isArray(value);
}

/** Human views are projections of the semantic payload, never parsed model content. */
function valueLines(value: unknown, indent = ""): string[] {
  if (Array.isArray(value)) {
    return value.length === 0 ? [`${indent}(none)`]
      : value.flatMap(item => valueLines(item, `${indent}  `));
  }
  if (record(value)) {
    if (record(value.workflow) && Array.isArray(value.steps) && Array.isArray(value.jobs)) {
      const steps = value.steps.filter(record).map(step =>
        `${step.startedAt} → ${step.completedAt}  ${step.name}: ${step.status} (${step.seconds}s)`);
      const jobs = value.jobs.filter(record).map(job =>
        `${job.id} | ${job.step} | ${job.outcome ?? "running"} | ${job.deadline ?? "unbounded"}`);
      return [
        `${value.workflow.workflow}: ${value.workflow.status} — ${value.totalSeconds}s`,
        "Step timeline", ...steps,
        "Jobs", "Job | Step | Outcome | Deadline", ...jobs,
      ];
    }
    return Object.entries(value).flatMap(([key, item]) =>
      item !== null && typeof item === "object"
        ? [`${indent}${key}:`, ...valueLines(item, `${indent}  `)]
        : [`${indent}${key}: ${String(item)}`]);
  }
  return [`${indent}${String(value)}`];
}

function presentation(result: Result, expanded: boolean): string {
  const value = result.details?.value;
  const lines = value === null || value === undefined
    ? result.content.flatMap(part => part.type === "text" ? (part.text ?? "").split("\n") : [])
    : valueLines(value);
  const visible = expanded || lines.length <= 12 ? lines : [...lines.slice(0, 12), `… ${lines.length - 12} more lines (expand)`];
  return stripVTControlCharacters(visible.join("\n")).replace(/\r/g, "");
}

/** Render immutable human-readable rows with Unicode-aware terminal wrapping. */
export function renderResult(result: Result, options: RenderResultOptions): Component {
  const text = presentation(result, options.expanded);
  return {
    render(width: number) {
      return wrapAnsi(text, Math.max(1, width), { hard: true, trim: false }).split("\n");
    },
  };
}

/** Describe the same human view for native TSP terminals without ANSI framing. */
export function describeResult(result: Result, options: RenderResultOptions): NativeToolView {
  return {
    tool: { target: result.details?.op },
    body: [{ k: "text", p: { text: presentation(result, options.expanded) } }],
    tone: result.isError ? "error" : undefined,
  };
}
