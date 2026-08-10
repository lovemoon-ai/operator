/**
 * SQLite-backed implementation of `@love-moon/ego-ingest`'s `SessionStore`.
 *
 * Two extension hooks vs. the generic interface:
 *
 *   1. INSERT paths (`createResource`, first `upsertSessionArtifact`)
 *      pick up `user_id` from the AsyncLocalStorage context bound by
 *      the outer auth middleware. UPDATE paths preserve whatever
 *      `user_id` is already on the row, so post-ingest workers running
 *      outside an HTTP context don't accidentally null out ownership.
 *
 *   2. Reads (`getSession`, `listSessions`, `stats`) honor the optional
 *      `userId` param on the interface. When the caller doesn't pass
 *      one, no filter is applied — this is what lets the orphan
 *      watchdog scan all sessions at boot.
 *
 * Schema lives in `./db.ts` — this file just does CRUD against it.
 */
import type {
  FinalizedArtifact,
  ResourceRecord,
  SessionRecord,
} from "@love-moon/ego-ingest";
import type { SessionStore, StoreStats } from "@love-moon/ego-ingest";

import { db } from "./db.js";
import { currentUserId } from "./auth-context.js";

// --- Row shapes (mirror the schema in db.ts) -----------------------------

interface ResourceRow {
  id: string;
  user_id: string | null;
  session_id: string;
  artifact_kind: string;
  upload_length: number;
  offset: number;
  metadata_json: string;
  created_at: string;
  last_patch_at: string | null;
}

interface SessionRow {
  id: string;
  user_id: string | null;
  received_at: string;
  total_bytes: number;
  manifest_json: string | null;
  expired_json: string | null;
}

interface ArtifactRow {
  session_id: string;
  kind: string;
  filename: string;
  bytes: number;
  sha256: string | null;
  stored_at: string;
  uri: string;
  corrupt: number;
  expected_sha256: string | null;
}

interface SessionDeletionTargets {
  artifactUris: string[];
  resourceIds: string[];
}

// --- Prepared statements -------------------------------------------------

const stmts = {
  insertResource: db.prepare<[
    string, string | null, string, string, number, number, string, string, string | null,
  ]>(`
    INSERT INTO resources (id, user_id, session_id, artifact_kind, upload_length, offset, metadata_json, created_at, last_patch_at)
    VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)
  `),
  getResource: db.prepare<[string], ResourceRow>(`SELECT * FROM resources WHERE id = ?`),
  getResourceScoped: db.prepare<[string, string], ResourceRow>(`
    SELECT * FROM resources WHERE id = ? AND user_id = ?
  `),
  getResourceOwnerForSession: db.prepare<[string], { user_id: string | null }>(`
    SELECT user_id FROM resources WHERE session_id = ? LIMIT 1
  `),
  getActiveResourceForArtifact: db.prepare<
    [string, string],
    { id: string; user_id: string | null }
  >(`
    SELECT id, user_id FROM resources
    WHERE session_id = ? AND artifact_kind = ? LIMIT 1
  `),
  setResourceOffset: db.prepare<[number, string, string]>(`
    UPDATE resources SET offset = ?, last_patch_at = ? WHERE id = ?
  `),
  setResourceOffsetScoped: db.prepare<[number, string, string, string]>(`
    UPDATE resources SET offset = ?, last_patch_at = ? WHERE id = ? AND user_id = ?
  `),
  deleteResource: db.prepare<[string]>(`DELETE FROM resources WHERE id = ?`),
  deleteResourceScoped: db.prepare<[string, string]>(`
    DELETE FROM resources WHERE id = ? AND user_id = ?
  `),

  getSession: db.prepare<[string], SessionRow>(`SELECT * FROM sessions WHERE id = ?`),
  getSessionScoped: db.prepare<[string, string], SessionRow>(`
    SELECT * FROM sessions WHERE id = ? AND user_id = ?
  `),
  insertSession: db.prepare<[string, string | null, string]>(`
    INSERT INTO sessions (id, user_id, received_at) VALUES (?, ?, ?)
  `),
  updateSessionManifest: db.prepare<[string, string]>(`
    UPDATE sessions SET manifest_json = ? WHERE id = ?
  `),
  updateSessionTotalBytes: db.prepare<[number, string]>(`
    UPDATE sessions SET total_bytes = ? WHERE id = ?
  `),
  updateSessionExpired: db.prepare<[string, string]>(`
    UPDATE sessions SET expired_json = ? WHERE id = ?
  `),

  listArtifacts: db.prepare<[string], ArtifactRow>(`
    SELECT * FROM artifacts WHERE session_id = ?
  `),
  upsertArtifact: db.prepare<[
    string, string, string, number, string | null, string, string, number, string | null,
  ]>(`
    INSERT INTO artifacts (session_id, kind, filename, bytes, sha256, stored_at, uri, corrupt, expected_sha256)
    VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)
    ON CONFLICT(session_id, kind) DO UPDATE SET
      filename = excluded.filename,
      bytes = excluded.bytes,
      sha256 = excluded.sha256,
      stored_at = excluded.stored_at,
      uri = excluded.uri,
      corrupt = excluded.corrupt,
      expected_sha256 = excluded.expected_sha256
  `),

  statsAll: db.prepare<[], { sessionCount: number; totalBytes: number }>(`
    SELECT COUNT(*) AS sessionCount, COALESCE(SUM(total_bytes), 0) AS totalBytes FROM sessions
  `),
  statsUser: db.prepare<[string], { sessionCount: number; totalBytes: number }>(`
    SELECT COUNT(*) AS sessionCount, COALESCE(SUM(total_bytes), 0) AS totalBytes
    FROM sessions WHERE user_id = ?
  `),
  perDayAll: db.prepare<[], { day: string; sessions: number; bytes: number }>(`
    SELECT substr(received_at, 1, 10) AS day, COUNT(*) AS sessions, COALESCE(SUM(total_bytes), 0) AS bytes
    FROM sessions GROUP BY day
  `),
  perDayUser: db.prepare<[string], { day: string; sessions: number; bytes: number }>(`
    SELECT substr(received_at, 1, 10) AS day, COUNT(*) AS sessions, COALESCE(SUM(total_bytes), 0) AS bytes
    FROM sessions WHERE user_id = ? GROUP BY day
  `),

  // Delete plumbing for the dashboard's "Remove" button. The lookup
  // statements above (`getSession` / `getSessionScoped`) decide whether
  // the caller is allowed to proceed; the three deletes below run
  // unconditionally once inside the transaction.
  listArtifactUris: db.prepare<[string], { uri: string }>(`
    SELECT uri FROM artifacts WHERE session_id = ?
  `),
  deleteArtifactsForSession: db.prepare<[string]>(`
    DELETE FROM artifacts WHERE session_id = ?
  `),
  deleteResourcesForSession: db.prepare<[string]>(`
    DELETE FROM resources WHERE session_id = ?
  `),
  deleteResourcesForSessionScoped: db.prepare<[string, string]>(`
    DELETE FROM resources WHERE session_id = ? AND user_id = ?
  `),
  listResourceIdsForSession: db.prepare<[string], { id: string }>(`
    SELECT id FROM resources WHERE session_id = ?
  `),
  listResourceIdsForSessionScoped: db.prepare<[string, string], { id: string }>(`
    SELECT id FROM resources WHERE session_id = ? AND user_id = ?
  `),
  deleteSessionRow: db.prepare<[string]>(`
    DELETE FROM sessions WHERE id = ?
  `),
};

// --- Helpers -------------------------------------------------------------

function rowToSession(row: SessionRow): SessionRecord {
  const artifacts: Record<string, FinalizedArtifact> = {};
  for (const a of stmts.listArtifacts.all(row.id)) {
    artifacts[a.kind] = {
      kind: a.kind,
      filename: a.filename,
      bytes: a.bytes,
      sha256: a.sha256 ?? undefined,
      storedAt: a.stored_at,
      uri: a.uri,
      corrupt: a.corrupt ? true : undefined,
      expectedSha256: a.expected_sha256 ?? undefined,
    };
  }
  const session: SessionRecord = {
    id: row.id,
    receivedAt: row.received_at,
    artifacts,
    totalBytes: row.total_bytes,
  };
  if (row.manifest_json) {
    try {
      session.manifest = JSON.parse(row.manifest_json) as Record<string, unknown>;
    } catch {
      /* ignore corrupt manifest blob */
    }
  }
  if (row.expired_json) {
    try {
      session.expired = JSON.parse(row.expired_json) as { at: string; reason: string };
    } catch {
      /* ignore */
    }
  }
  return session;
}

function recomputeTotalBytes(sessionId: string): number {
  let total = 0;
  for (const a of stmts.listArtifacts.all(sessionId)) total += a.bytes;
  return total;
}

// --- Store ---------------------------------------------------------------

export class SqliteStore implements SessionStore {
  // --- Resources ----------------------------------------------------------

  async createResource(record: ResourceRecord, opts: { userId?: string } = {}): Promise<void> {
    const userId = opts.userId ?? currentUserId() ?? null;
    const txn = db.transaction(() => {
      const existingSession = stmts.getSession.get(record.sessionId);
      if (existingSession && existingSession.user_id !== userId) {
        throw new SessionOwnershipConflictError(record.sessionId);
      }
      const existingResource = stmts.getResourceOwnerForSession.get(record.sessionId);
      if (existingResource && existingResource.user_id !== userId) {
        throw new SessionOwnershipConflictError(record.sessionId);
      }
      const activeArtifact = stmts.getActiveResourceForArtifact.get(
        record.sessionId,
        record.artifactKind,
      );
      if (activeArtifact) {
        throw new ActiveArtifactUploadConflictError(
          record.sessionId,
          record.artifactKind,
        );
      }
      stmts.insertResource.run(
        record.id,
        userId,
        record.sessionId,
        record.artifactKind,
        record.uploadLength,
        record.offset,
        JSON.stringify(record.metadata),
        record.createdAt,
        record.lastPatchAt ?? null,
      );
    });
    txn();
  }

  async getResource(id: string, opts: { userId?: string } = {}): Promise<ResourceRecord | null> {
    const scopedUserId = opts.userId ?? currentUserId() ?? undefined;
    const row = scopedUserId
      ? stmts.getResourceScoped.get(id, scopedUserId)
      : stmts.getResource.get(id);
    if (!row) return null;
    return {
      id: row.id,
      sessionId: row.session_id,
      artifactKind: row.artifact_kind,
      uploadLength: row.upload_length,
      offset: row.offset,
      metadata: JSON.parse(row.metadata_json),
      createdAt: row.created_at,
      lastPatchAt: row.last_patch_at ?? undefined,
    };
  }

  async setResourceOffset(
    id: string,
    offset: number,
    lastPatchAt: string,
    opts: { userId?: string } = {},
  ): Promise<void> {
    const scopedUserId = opts.userId ?? currentUserId() ?? undefined;
    if (scopedUserId) {
      stmts.setResourceOffsetScoped.run(offset, lastPatchAt, id, scopedUserId);
    } else {
      stmts.setResourceOffset.run(offset, lastPatchAt, id);
    }
  }

  async deleteResource(id: string, opts: { userId?: string } = {}): Promise<void> {
    const scopedUserId = opts.userId ?? currentUserId() ?? undefined;
    if (scopedUserId) {
      stmts.deleteResourceScoped.run(id, scopedUserId);
    } else {
      stmts.deleteResource.run(id);
    }
  }

  // --- Sessions -----------------------------------------------------------

  async upsertSessionArtifact(
    sessionId: string,
    artifact: FinalizedArtifact,
    manifest?: Record<string, unknown>,
    opts: { userId?: string } = {},
  ): Promise<SessionRecord> {
    // Wrap the per-session writes in a transaction so a concurrent reader
    // never sees an artifact row without its parent session row.
    const txn = db.transaction(() => {
      const existing = stmts.getSession.get(sessionId);
      const userId = opts.userId ?? currentUserId() ?? null;
      if (existing && userId !== null && existing.user_id !== userId) {
        throw new SessionOwnershipConflictError(sessionId);
      }
      if (!existing) {
        stmts.insertSession.run(
          sessionId,
          userId,
          new Date().toISOString(),
        );
      }
      stmts.upsertArtifact.run(
        sessionId,
        artifact.kind,
        artifact.filename,
        artifact.bytes,
        artifact.sha256 ?? null,
        artifact.storedAt,
        artifact.uri,
        artifact.corrupt ? 1 : 0,
        artifact.expectedSha256 ?? null,
      );
      stmts.updateSessionTotalBytes.run(recomputeTotalBytes(sessionId), sessionId);
      if (manifest) {
        stmts.updateSessionManifest.run(JSON.stringify(manifest), sessionId);
      }
    });
    txn();
    return rowToSession(stmts.getSession.get(sessionId)!);
  }

  async markSessionExpired(
    sessionId: string,
    expired: { at: string; reason: string },
  ): Promise<SessionRecord | null> {
    const row = stmts.getSession.get(sessionId);
    if (!row) return null;
    if (!row.expired_json) {
      stmts.updateSessionExpired.run(JSON.stringify(expired), sessionId);
    }
    return rowToSession(stmts.getSession.get(sessionId)!);
  }

  async getSession(id: string, opts?: { userId?: string }): Promise<SessionRecord | null> {
    const row = opts?.userId
      ? stmts.getSessionScoped.get(id, opts.userId)
      : stmts.getSession.get(id);
    return row ? rowToSession(row) : null;
  }

  async listSessions(opts: {
    limit?: number;
    cursor?: string;
    order?: "asc" | "desc";
    userId?: string;
  } = {}) {
    const order = opts.order === "asc" ? "ASC" : "DESC";
    const limit = Math.max(1, Math.min(opts.limit ?? 50, 500));
    // Cursor is a session.id — translate to its received_at so we can
    // page on that field (which is what we ORDER BY). Stops the
    // listing from skipping/duplicating rows when many sessions share
    // a timestamp.
    let cursorReceivedAt: string | null = null;
    if (opts.cursor) {
      const c = stmts.getSession.get(opts.cursor);
      cursorReceivedAt = c?.received_at ?? null;
    }
    // Build SQL dynamically — better-sqlite3 needs prepared statements,
    // so we compose once per call. Six branches (user × cursor × order)
    // would be overkill; one branch with conditional clauses keeps it
    // legible and `prepare` caches identical SQL strings internally.
    const filters: string[] = [];
    const params: (string | number)[] = [];
    if (opts.userId) {
      filters.push("user_id = ?");
      params.push(opts.userId);
    }
    if (cursorReceivedAt !== null) {
      filters.push(order === "DESC" ? "received_at < ?" : "received_at > ?");
      params.push(cursorReceivedAt);
    }
    const where = filters.length ? `WHERE ${filters.join(" AND ")}` : "";
    const sql = `SELECT * FROM sessions ${where} ORDER BY received_at ${order} LIMIT ?`;
    const rows = db.prepare<typeof params, SessionRow>(sql).all(...params, limit + 1);
    const slice = rows.slice(0, limit);
    const nextCursor = rows.length > limit ? slice[slice.length - 1]?.id ?? null : null;
    return { items: slice.map(rowToSession), nextCursor };
  }

  async getSessionDeletionTargets(
    sessionId: string,
    opts: { userId?: string } = {},
  ): Promise<SessionDeletionTargets | null> {
    const scopedUserId = opts.userId ?? currentUserId() ?? undefined;
    const session = scopedUserId
      ? stmts.getSessionScoped.get(sessionId, scopedUserId)
      : stmts.getSession.get(sessionId);
    const artifactUris = session
      ? stmts.listArtifactUris.all(sessionId).map((r) => r.uri)
      : [];
    const resourceIds = scopedUserId
      ? stmts.listResourceIdsForSessionScoped.all(sessionId, scopedUserId).map((r) => r.id)
      : stmts.listResourceIdsForSession.all(sessionId).map((r) => r.id);
    if (!session && resourceIds.length === 0) return null;
    return { artifactUris, resourceIds };
  }

  async deleteSession(
    sessionId: string,
    opts: { userId?: string } = {},
  ): Promise<SessionDeletionTargets | null> {
    // Wrap lookup + deletes in a single transaction so a concurrent
    // GET /sessions/:id can never observe a half-deleted state (e.g.
    // session row present, artifact rows gone). The transaction is
    // sync (better-sqlite3 style); we hand the result back through
    // the surrounding Promise.
    const txn = db.transaction(() => {
      const scopedUserId = opts.userId ?? currentUserId() ?? undefined;
      const session = scopedUserId
        ? stmts.getSessionScoped.get(sessionId, scopedUserId)
        : stmts.getSession.get(sessionId);
      // Capture URIs BEFORE deleting artifact rows — the storage layer
      // needs them to rm the actual bytes off disk after we commit.
      const artifactUris = session
        ? stmts.listArtifactUris.all(sessionId).map((r) => r.uri)
        : [];
      const resourceIds = scopedUserId
        ? stmts.listResourceIdsForSessionScoped.all(sessionId, scopedUserId).map((r) => r.id)
        : stmts.listResourceIdsForSession.all(sessionId).map((r) => r.id);
      if (!session && resourceIds.length === 0) return null;
      if (session) {
        stmts.deleteArtifactsForSession.run(sessionId);
        stmts.deleteSessionRow.run(sessionId);
      }
      if (scopedUserId) {
        stmts.deleteResourcesForSessionScoped.run(sessionId, scopedUserId);
      } else {
        stmts.deleteResourcesForSession.run(sessionId);
      }
      return { artifactUris, resourceIds };
    });
    return txn();
  }

  async stats(opts?: { userId?: string }): Promise<StoreStats> {
    const head = opts?.userId
      ? stmts.statsUser.get(opts.userId)
      : stmts.statsAll.get();
    const days = opts?.userId
      ? stmts.perDayUser.all(opts.userId)
      : stmts.perDayAll.all();
    const perDay: StoreStats["perDay"] = {};
    for (const d of days) perDay[d.day] = { sessions: d.sessions, bytes: d.bytes };
    return {
      sessionCount: head?.sessionCount ?? 0,
      totalBytes: head?.totalBytes ?? 0,
      perDay,
    };
  }
}

export class SessionOwnershipConflictError extends Error {
  readonly code = "SESSION_OWNERSHIP_CONFLICT";

  constructor(sessionId: string) {
    super(`session ${sessionId} belongs to another user`);
    this.name = "SessionOwnershipConflictError";
  }
}

export class ActiveArtifactUploadConflictError extends Error {
  readonly code = "ACTIVE_ARTIFACT_UPLOAD_CONFLICT";

  constructor(sessionId: string, artifactKind: string) {
    super(`artifact ${sessionId}/${artifactKind} is already being uploaded`);
    this.name = "ActiveArtifactUploadConflictError";
  }
}
