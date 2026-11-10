import { createHash } from "node:crypto";
import { DatabaseSync } from "node:sqlite";
import { existsSync, mkdirSync, realpathSync } from "node:fs";
import { dirname, join, resolve } from "node:path";
import { homedir } from "node:os";

const transactions = new Map();
const UPSERT_SQL =
  "INSERT INTO run(workspace_path, state_json) VALUES (?, ?) ON CONFLICT(workspace_path) DO UPDATE SET state_json = excluded.state_json";
const SCHEMA_SQL =
  "CREATE TABLE IF NOT EXISTS run (workspace_path TEXT PRIMARY KEY, state_json TEXT NOT NULL) STRICT";

// The worktree's external snapshot path is derived once per context. Linked
// worktrees intentionally have independent state databases.
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

// Readers use readOnly and never create a file/schema. Writers enable WAL and
// FULL durability. Schema setup is idempotent inside BEGIN IMMEDIATE: a second
// first-writer rechecks the version after waiting rather than failing on a
// duplicate table.
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
      const currentVersion = db
        .prepare("PRAGMA user_version")
        .get().user_version;
      if (currentVersion === 0) {
        db.exec(SCHEMA_SQL);
        db.exec("PRAGMA user_version = 1");
      } else if (currentVersion !== 1) {
        throw new Error(
          `state: unsupported schema version ${currentVersion} at ${location.dbPath}`,
        );
      }
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
      active.prepare(UPSERT_SQL).run(location.workspacePath, json);
      return;
    }
    const db = openState(location, true);
    try {
      db.exec("BEGIN IMMEDIATE");
      try {
        db.prepare(UPSERT_SQL).run(location.workspacePath, json);
        db.exec("COMMIT");
      } catch (error) {
        try {
          db.exec("ROLLBACK");
        } catch (rollbackError) {
          throw new Error(
            `state: write failed at ${location.dbPath}: ${error?.message ?? error}; rollback failed: ${rollbackError?.message ?? rollbackError}`,
            { cause: error },
          );
        }
        throw error;
      }
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
      try {
        db.exec("BEGIN IMMEDIATE");
      } catch (error) {
        throw new Error(
          `state: unable to begin mutation at ${location.dbPath}; another mutation may be running or the WAL is contended: ${error?.message ?? error}`,
          { cause: error },
        );
      }
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
