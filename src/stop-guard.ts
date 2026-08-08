import type { ExtensionAPI } from "@oh-my-pi/pi-coding-agent";
import { readFileSync } from "node:fs";
import { join } from "node:path";

export default function (pi: ExtensionAPI) {
  pi.on("session_stop", async (_event, ctx) => {
    let active: string | undefined;
    try {
      const raw = readFileSync(join(ctx.cwd, ".do-results.json"), "utf-8");
      active = JSON.parse(raw).active;
    } catch {
      return; // no file or unparseable → allow stop
    }
    if (active === "working") {
      return {
        continue: true,
        additionalContext:
          "/do workflow still running — continue from where you left off. Check .do-results.json for current progress.",
      };
    }
  });
}