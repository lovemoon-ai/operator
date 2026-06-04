/**
 * Process-wide ingest singleton.
 *
 * The same store / storage / events instances are shared between:
 *   - the TUS middleware on /api/ingest (writes)
 *   - the read API on /api/ingest-read (reads + SSE)
 *   - any server component that fetches sessions directly
 *
 * If you later split the ingest server onto its own process (so the
 * Next app only renders), point the React components at the remote
 * /api/ingest-read URL and delete this file.
 */

import path from "node:path";

import {
  DiskStorage,
  IngestEvents,
  MemoryStore,
} from "@love-moon/ego-ingest";

const DATA_ROOT = path.resolve(process.env.DATA_ROOT ?? "./data");
const SESSIONS_DIR = path.join(DATA_ROOT, "sessions");
const INDEX_FILE = path.join(DATA_ROOT, "sessions.index.json");

export const ingest = {
  dataRoot: DATA_ROOT,
  events: new IngestEvents(),
  store: new MemoryStore({ persistTo: INDEX_FILE }),
  storage: new DiskStorage({ root: SESSIONS_DIR, computeHashes: true }),
};
