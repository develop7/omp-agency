import { describe, expect, test } from "bun:test";

import { shouldAllowStopAfterStateError, shouldContinueSession } from "./stop-guard";

describe("shouldContinueSession", () => {
  test.each(["working", "waiting"])("blocks an in-flight %s workflow", (active) => {
    expect(shouldContinueSession({ active, status: "running" })).toBe(true);
  });

  test.each(["completed", "failed"])("allows terminal %s workflows", (status) => {
    expect(shouldContinueSession({ active: "working", status })).toBe(false);
    expect(shouldContinueSession({ active: "waiting", status })).toBe(false);
  });

  test("allows inactive and malformed states", () => {
    expect(shouldContinueSession({ active: "idle", status: "running" })).toBe(false);
    expect(shouldContinueSession({ active: "waiting", status: "idle" })).toBe(false);
    expect(shouldContinueSession({})).toBe(false);
    expect(shouldContinueSession(null)).toBe(false);
  });
});

describe("shouldAllowStopAfterStateError", () => {
  test("allows a missing or unparseable state file", () => {
    expect(shouldAllowStopAfterStateError(Object.assign(new Error("missing"), { code: "ENOENT" }))).toBe(true);
    expect(shouldAllowStopAfterStateError(new SyntaxError("invalid JSON"))).toBe(true);
  });

  test.each(["EACCES", "EIO"])("continues when state-file access fails with %s", (code) => {
    expect(shouldAllowStopAfterStateError(Object.assign(new Error("state read failed"), { code }))).toBe(false);
  });
});
