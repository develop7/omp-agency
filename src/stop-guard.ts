import type { ExtensionAPI } from "@oh-my-pi/pi-coding-agent";
import { readFileSync } from "node:fs";
import { join } from "node:path";

type WorkflowState = {
  active?: unknown;
  status?: unknown;
};

/** Whether persisted /do state still requires the session to continue. */

export function shouldContinueSession(state: unknown): boolean {
  if (typeof state !== "object" || state === null) {
    return false;
  }
  const { active, status } = state as WorkflowState;
  return status === "running" && (active === "working" || active === "waiting");
}

/** Whether no persisted workflow state exists, making stopping safe. */
export function isMissingStateFile(error: unknown): boolean {
  return typeof error === "object" && error !== null && "code" in error && error.code === "ENOENT";
}

export default function (pi: ExtensionAPI) {
  pi.on("session_stop", async (_event, ctx) => {
    let state: unknown;
    try {
      const raw = readFileSync(join(ctx.cwd, ".do-results.json"), "utf-8");
      state = JSON.parse(raw);
    } catch (error: unknown) {
      if (isMissingStateFile(error)) {
        return; // no state file means no persisted workflow to abandon
      }
      return {
        continue: true,
        additionalContext:
          "/do workflow state could not be read — resolve the state-file error before stopping.",
      };
    }
    if (shouldContinueSession(state)) {
      return {
        continue: true,
        additionalContext:
          "/do workflow still running — continue from where you left off. Check .do-results.json for current progress.",
      };
    }
  });
}