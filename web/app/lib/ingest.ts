/**
 * Process-wide ingest singleton.
 *
 * The same store / storage / events instances are shared between:
 *   - the TUS middleware on /api/ingest (writes)
 *   - the read API on /api/ingest-read (reads + SSE)
 *   - any server component that fetches sessions directly
 *
 * Storage is the on-disk byte tier (DiskStorage); the metadata store is
 * SqliteStore (`./db.ts` schema), which gives us per-user filtering and
 * survives restarts without re-parsing a JSON index.
 */

import path from "node:path";

import { DiskStorage, IngestEvents } from "@love-moon/ego-ingest";

import { DATA_ROOT } from "./db.js";
import { SqliteStore } from "./sqlite-store.js";

const SESSIONS_DIR = path.join(DATA_ROOT, "sessions");

export const ingest = {
  dataRoot: DATA_ROOT,
  events: new IngestEvents(),
  store: new SqliteStore(),
  storage: new DiskStorage({ root: SESSIONS_DIR, computeHashes: true }),
};
