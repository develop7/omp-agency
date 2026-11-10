import { createHash } from "node:crypto";
import { DatabaseSync } from "node:sqlite";
import { existsSync, mkdirSync, realpathSync } from "node:fs";
import { dirname, join, resolve } from "node:path";
import { homedir } from "node:os";

const transactions = new Map();

function stateLocation(root, workspace) {
  const workspacePath = realpathSync.native(workspace);
  const configured = root || process.env.AGENCY_STATE_DIR;
  const agentRoot = process.env.PI_CODING_AGENT_DIR;
  const home = homedir();
  const fallback =
    process.platform === "win32"
      ? join(
          process.env.LOCALAPPDATA || join(home, "AppData", "Local"),
          "omp",
          "agency",
        )
      : process.platform === "darwin"
        ? join(home, "Library", "Application Support", "omp", "agency")
        : join(
            process.env.XDG_STATE_HOME || join(home, ".local", "state"),
            "omp",
            "agency",
          );
  const directory = resolve(
    configured || (agentRoot ? join(agentRoot, "agency") : fallback),
  );
  const filename = `${createHash("sha256").update(workspacePath).digest("hex")}.db`;
  return { dbPath: join(directory, filename), workspacePath };
}

function openState(location, create) {
  if (create)
    mkdirSync(dirname(location.dbPath), { recursive: true, mode: 0o700 });
  const db = new DatabaseSync(location.dbPath, { readOnly: !create });
  db.exec("PRAGMA busy_timeout = 5000");
  const version = db.prepare("PRAGMA user_version").get().user_version;
  if (version !== 1 && (version > 1 || !create))
    throw new Error(
      `state: unsupported schema version ${version} at ${location.dbPath}`,
    );
  if (!create) return db;
  const journalMode = db
    .prepare("PRAGMA journal_mode = WAL")
    .get().journal_mode;
  if (journalMode.toLowerCase() !== "wal")
    throw new Error(`state: SQLite WAL mode unavailable at ${location.dbPath}`);
  db.exec("PRAGMA synchronous = FULL");
  if (version < 1) {
    db.exec("BEGIN IMMEDIATE");
    try {
      db.exec(
        "CREATE TABLE run (workspace_path TEXT PRIMARY KEY, state_json TEXT NOT NULL) STRICT",
      );
      db.exec("PRAGMA user_version = 1");
      db.exec("COMMIT");
    } catch (error) {
      try {
        db.exec("ROLLBACK");
      } catch (rollbackError) {
        throw new Error(
          `state: schema initialization failed at ${location.dbPath}: ${error?.message ?? error}; rollback failed: ${rollbackError?.message ?? rollbackError}`,
          { cause: error },
        );
      }
      throw error;
    }
  }
  return db;
}

function readState(db, workspacePath) {
  return (
    db
      .prepare("SELECT state_json FROM run WHERE workspace_path = ?")
      .get(workspacePath)?.state_json ?? null
  );
}

export function stateDbPath(root) {
  return (workspace) => () => stateLocation(root, workspace).dbPath;
}

export function readStateJson(dbPath) {
  return (workspacePath) => () => {
    const location = { dbPath, workspacePath };
    const active = transactions.get(location.dbPath);
    if (active) return readState(active, workspacePath);
    let db;
    try {
      if (!existsSync(location.dbPath)) return null;
      db = openState(location, false);
      return readState(db, workspacePath);
    } catch (error) {
      throw new Error(
        `state: cannot read ${location.dbPath}: ${error?.message ?? error}`,
        { cause: error },
      );
    } finally {
      db?.close();
    }
  };
}

export function writeStateJson(dbPath) {
  return (workspacePath) => (json) => () => {
    const location = { dbPath, workspacePath };
    const active = transactions.get(location.dbPath);
    if (active) {
      active
        .prepare(
          "INSERT INTO run(workspace_path, state_json) VALUES (?, ?) ON CONFLICT(workspace_path) DO UPDATE SET state_json = excluded.state_json",
        )
        .run(location.workspacePath, json);
      return;
    }
    const db = openState(location, true);
    try {
      db.prepare(
        "INSERT INTO run(workspace_path, state_json) VALUES (?, ?) ON CONFLICT(workspace_path) DO UPDATE SET state_json = excluded.state_json",
      ).run(location.workspacePath, json);
    } finally {
      db.close();
    }
  };
}

export function withStateTransaction(dbPath) {
  return (workspacePath) => (action) => () => {
    const location = { dbPath, workspacePath };
    if (transactions.has(location.dbPath))
      throw new Error(`state: nested transaction at ${location.dbPath}`);
    const db = openState(location, true);
    try {
      db.exec("BEGIN IMMEDIATE");
      transactions.set(location.dbPath, db);
      try {
        const result = action();
        db.exec("COMMIT");
        return result;
      } catch (error) {
        try {
          db.exec("ROLLBACK");
        } catch (rollbackError) {
          throw new Error(
            `state: transaction failed at ${location.dbPath}: ${error?.message ?? error}; rollback failed: ${rollbackError?.message ?? rollbackError}`,
            { cause: error },
          );
        }
        throw error;
      } finally {
        transactions.delete(location.dbPath);
      }
    } finally {
      db.close();
    }
  };
}

function canonicalIso(date) {
  return date.toISOString().replace(/\.\d{3}Z$/, "Z");
}

export function nowIso() {
  return canonicalIso(new Date());
}

export function formatEpochIso(epoch) {
  return canonicalIso(new Date(epoch * 1000));
}

export function bundleDir() {
  return import.meta.dirname ?? new URL(".", import.meta.url).pathname;
}

export function isCanonicalIso(value) {
  if (!/^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}Z$/.test(value)) return false;
  const date = new Date(value);
  return !Number.isNaN(date.valueOf()) && canonicalIso(date) === value;
}
