/**
 * Process-wide SQLite handle.
 *
 * One file (`<DATA_ROOT>/operator.db`), WAL journaling, foreign keys on.
 * Sync API (better-sqlite3) — every call returns immediately and the
 * worker pipeline never deadlocks on awaiting a query while holding the
 * libuv loop.
 *
 * Schema lives here too, applied idempotently on every boot. We
 * deliberately avoid a migration framework — the only deployment is the
 * demo app, and `CREATE TABLE IF NOT EXISTS` covers the cold-start path.
 * If a column needs to change, edit it here and write a one-off
 * `ALTER TABLE` underneath; squash later.
 */
import { mkdirSync } from "node:fs";
import path from "node:path";

import Database from "better-sqlite3";

const DATA_ROOT = path.resolve(process.env.DATA_ROOT ?? "./data");
const DB_PATH = path.join(DATA_ROOT, "operator.db");

mkdirSync(DATA_ROOT, { recursive: true });

export const db = new Database(DB_PATH);
// Next's production builder evaluates multiple route bundles concurrently.
// Give idempotent schema initialization and short WAL checkpoints time to
// finish instead of failing a sibling worker immediately with SQLITE_BUSY.
db.pragma("busy_timeout = 5000");
db.pragma("journal_mode = WAL");
db.pragma("synchronous = NORMAL");
db.pragma("foreign_keys = ON");

db.exec(`
  CREATE TABLE IF NOT EXISTS users (
    id            TEXT PRIMARY KEY,
    oidc_sub      TEXT UNIQUE,
    collector_id  TEXT COLLATE NOCASE UNIQUE,
    pin_hash      TEXT,
    email         TEXT,
    name          TEXT,
    upload_token  TEXT UNIQUE NOT NULL,
    created_at    TEXT NOT NULL,
    seeded        INTEGER NOT NULL DEFAULT 0
  );

  CREATE TABLE IF NOT EXISTS resources (
    id             TEXT PRIMARY KEY,
    user_id        TEXT,
    session_id     TEXT NOT NULL,
    artifact_kind  TEXT NOT NULL,
    upload_length  INTEGER NOT NULL,
    offset         INTEGER NOT NULL,
    metadata_json  TEXT NOT NULL,
    created_at     TEXT NOT NULL,
    last_patch_at  TEXT
  );
  CREATE INDEX IF NOT EXISTS idx_resources_user ON resources(user_id);
  CREATE UNIQUE INDEX IF NOT EXISTS idx_resources_active_artifact
    ON resources(session_id, artifact_kind);

  CREATE TABLE IF NOT EXISTS sessions (
    id             TEXT PRIMARY KEY,
    user_id        TEXT,
    received_at    TEXT NOT NULL,
    total_bytes    INTEGER NOT NULL DEFAULT 0,
    manifest_json  TEXT,
    expired_json   TEXT
  );
  CREATE INDEX IF NOT EXISTS idx_sessions_user_received
    ON sessions(user_id, received_at DESC);

  CREATE TABLE IF NOT EXISTS artifacts (
    session_id      TEXT NOT NULL,
    kind            TEXT NOT NULL,
    filename        TEXT NOT NULL,
    bytes           INTEGER NOT NULL,
    sha256          TEXT,
    stored_at       TEXT NOT NULL,
    uri             TEXT NOT NULL,
    corrupt         INTEGER NOT NULL DEFAULT 0,
    expected_sha256 TEXT,
    PRIMARY KEY (session_id, kind)
  );

  CREATE TABLE IF NOT EXISTS reviews (
    session_id  TEXT PRIMARY KEY,
    reviewed    INTEGER NOT NULL DEFAULT 0,
    flagged     INTEGER NOT NULL DEFAULT 0,
    notes       TEXT NOT NULL DEFAULT '',
    updated_at  TEXT NOT NULL DEFAULT ''
  );
`);

function ensureUserColumn(name: string, definition: string): void {
  const columns = db.prepare("PRAGMA table_info(users)").all() as Array<{ name: string }>;
  if (columns.some((column) => column.name === name)) return;
  try {
    db.exec(`ALTER TABLE users ADD COLUMN ${name} ${definition}`);
  } catch (error) {
    // Next's production builder can initialize the same SQLite file from
    // several workers. A sibling may have added the column after our PRAGMA.
    if (!String((error as Error).message).includes("duplicate column name")) throw error;
  }
}

ensureUserColumn("collector_id", "TEXT COLLATE NOCASE");
ensureUserColumn("pin_hash", "TEXT");
db.exec(`
  CREATE UNIQUE INDEX IF NOT EXISTS idx_users_collector_id
  ON users(collector_id COLLATE NOCASE)
  WHERE collector_id IS NOT NULL;
`);

// eslint-disable-next-line no-console
console.log(`[db] sqlite at ${DB_PATH}`);

export { DATA_ROOT };
