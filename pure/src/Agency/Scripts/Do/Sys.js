import { spawnSync } from "node:child_process";
import * as fs from "node:fs";

export function execImpl(cmd) {
  return (args) => () => {
    const r = spawnSync(cmd, args, { encoding: "utf8", maxBuffer: 64 * 1024 * 1024 });
    if (r.error) {
      return { code: 1, stdout: r.stdout ?? "", stderr: String(r.error.message ?? r.error) };
    }
    return { code: r.status ?? 1, stdout: r.stdout ?? "", stderr: r.stderr ?? "" };
  };
}

export function execInherit(cmd) {
  return (args) => () => {
    const r = spawnSync(cmd, args, { stdio: "inherit" });
    return (r.status ?? 1) | 0;
  };
}

export function execInheritInput(cmd) {
  return (args) => (input) => () => {
    const r = spawnSync(cmd, args, { input, stdio: ["pipe", "inherit", "inherit"] });
    return (r.status ?? 1) | 0;
  };
}

export function readUtf8(p) {
  return () => fs.readFileSync(p, "utf8");
}

export function writeUtf8(p) {
  return (s) => () => fs.writeFileSync(p, s);
}

export function rename(from) {
  return (to) => () => fs.renameSync(from, to);
}

export function existsImpl(p) {
  return () => fs.existsSync(p);
}

export function isDir(p) {
  return () => {
    try {
      return fs.statSync(p).isDirectory();
    } catch {
      return false;
    }
  };
}

// PureScript's no-argument Effect imports are invoked directly by generated JS.
export function nowIso() {
  return new Date().toISOString().replace(/\.\d{3}Z$/, "Z");
}

export function getEnv(k) {
  return () => process.env[k] ?? "";
}

export function argv() {
  return process.argv.slice(2);
}

export function exit(c) {
  return () => process.exit(c);
}

export function cwd() {
  return process.cwd();
}

export function stdoutWrite(s) {
  return () => process.stdout.write(s);
}

export function stderrWrite(s) {
  return () => process.stderr.write(s);
}

export function realpath(p) {
  return () => fs.realpathSync(p);
}

export function isoToEpoch(value) {
  return () => {
    const parsed = Date.parse(value);
    return Number.isFinite(parsed) ? Math.floor(parsed / 1000) : 0;
  };
}
