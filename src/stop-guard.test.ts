import { describe, expect, test } from "bun:test";

import { isMissingStateFile, shouldContinueSession } from "./stop-guard";

describe("shouldContinueSession", () => {
  test.each(["idle", "completed", "failed"])(
    "allows stopping from an idle %s workflow",
    (status) => {
      expect(shouldContinueSession({ active: "idle", status })).toBe(false);
    },
  );

  test.each([
    { active: "working", status: "running" },
    { active: "waiting", status: "running" },
    { active: "working", status: "completed" },
    { active: "idle", status: "running" },
    { active: "waiting", status: "idle" },
    {},
    null,
  ])("blocks untrusted or in-flight workflow state", (state) => {
    expect(shouldContinueSession(state)).toBe(true);
  });
});

describe("isMissingStateFile", () => {
  test("allows stopping only when the state file is absent", () => {
    expect(isMissingStateFile(Object.assign(new Error("missing"), { code: "ENOENT" }))).toBe(true);
  });

  test.each([
    new SyntaxError("invalid JSON"),
    Object.assign(new Error("state read failed"), { code: "EACCES" }),
    Object.assign(new Error("state read failed"), { code: "EIO" }),
  ])("continues when state cannot be trusted", (error) => {
    expect(isMissingStateFile(error)).toBe(false);
  });
});
