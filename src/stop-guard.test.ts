import { describe, expect, test } from "bun:test";

import { isMissingStateFile, shouldContinueSession } from "./stop-guard";

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
