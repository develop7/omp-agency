import { stripVTControlCharacters } from "node:util";
import wrapAnsi from "wrap-ansi";
import type { Component } from "@oh-my-pi/pi-tui";
import type { NativeToolView, ToolRenderResult, RenderResultOptions } from "@oh-my-pi/pi-tui/tools/renderer";
import type { ToolDetails } from "./tool-results.js";

type Result = ToolRenderResult<ToolDetails>;

function record(value: unknown): value is Record<string, unknown> {
  return value !== null && typeof value === "object" && !Array.isArray(value);
}

/** The summary view owns its schema; other tool values use the generic projection. */
function summaryLines(value: Record<string, unknown>): string[] | undefined {
  const { workflow, steps, jobs, totalSeconds } = value;
  if (!record(workflow) || !Array.isArray(steps) || !steps.every(record)
    || !Array.isArray(jobs) || !jobs.every(record) || typeof totalSeconds !== "number") return;
  const timeline = steps.map(step =>
    `${step.startedAt} → ${step.completedAt}  ${step.name}: ${step.status} (${step.seconds}s)`);
  const ledger = jobs.map(job =>
    `${job.id} | ${job.step} | ${job.outcome ?? "running"} | ${job.deadline ?? "unbounded"}`);
  return [
    `${workflow.workflow}: ${workflow.status} — ${totalSeconds}s`,
    "Step timeline", ...timeline,
    "Jobs", "Job | Step | Outcome | Deadline", ...ledger,
  ];
}

/** Human views project semantic data, never parse the model-facing representation. */
function valueLines(value: unknown, indent = ""): string[] {
  if (Array.isArray(value)) {
    return value.length === 0 ? [`${indent}(none)`]
      : value.flatMap(item => valueLines(item, `${indent}  `));
  }
  if (record(value)) {
    return Object.entries(value).flatMap(([key, item]) =>
      item !== null && typeof item === "object"
        ? [`${indent}${key}:`, ...valueLines(item, `${indent}  `)]
        : [`${indent}${key}: ${String(item)}`]);
  }
  return [`${indent}${String(value)}`];
}

function presentation(result: Result, expanded: boolean): string {
  const value = result.details?.value;
  const summary = result.details?.op === "summary" && record(value) ? summaryLines(value) : undefined;
  // Oversized semantic values are intentionally not duplicated in details. Show
  // their complete content representation instead of introducing another channel.
  const lines = value === null || value === undefined
    ? result.content.flatMap(part => part.type === "text" ? (part.text ?? "").split("\n") : [])
    : summary ?? valueLines(value);
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
