import type {
  FinalizedArtifact,
  ResourceRecord,
  SessionRecord,
} from "../types.js";

/**
 * Metadata index. Owns the per-resource (in-flight TUS upload) and
 * per-session (finalized artifacts) records.
 *
 * Implementations only need to be coherent within a single process —
 * we don't run the ingest across multiple Node workers because the
 * SessionEvents stream is process-local.
 */
export interface SessionDeletionTargets {
  artifactUris: string[];
  resourceIds: string[];
}

export interface SessionStore {
  // --- Resource (in-flight) state -------------------------------------------

  createResource(record: ResourceRecord): Promise<void>;
  getResource(id: string): Promise<ResourceRecord | null>;
  setResourceOffset(id: string, offset: number, lastPatchAt: string): Promise<void>;
  deleteResource(id: string): Promise<void>;

  // --- Session (finalized) state --------------------------------------------

  upsertSessionArtifact(
    sessionId: string,
    artifact: FinalizedArtifact,
    manifest?: Record<string, unknown>,
  ): Promise<SessionRecord>;

  /**
   * Mark a session as abandoned (manifest arrived but media didn't
   * follow within the orphan timeout). Returns the updated record so
   * the caller can emit a `session.updated` event. No-op if the
   * session doesn't exist; idempotent if already expired.
   */
  markSessionExpired(
    sessionId: string,
    expired: { at: string; reason: string },
  ): Promise<SessionRecord | null>;

  /**
   * Fetch a session by id.
   *
   * `opts.userId`, when set, scopes the lookup: returns `null` if the
   * stored row belongs to a different user. Stores that don't carry a
   * user dimension (e.g. `MemoryStore`) should ignore it.
   */
  getSession(id: string, opts?: { userId?: string }): Promise<SessionRecord | null>;

  listSessions(opts?: {
    limit?: number;
    cursor?: string;
    order?: "asc" | "desc";
    /** Restrict to sessions owned by this user. */
    userId?: string;
  }): Promise<{ items: SessionRecord[]; nextCursor: string | null }>;

  /** Lifetime-aggregated stats. Cheap implementations can recompute on call. */
  stats(opts?: { userId?: string }): Promise<StoreStats>;

  /**
   * Return the storage objects that must be removed before deleting a
   * session's metadata. Keeping this as a separate read lets callers
   * retry cleanup if the bytes layer fails partway through.
   */
  getSessionDeletionTargets(
    sessionId: string,
    opts?: { userId?: string },
  ): Promise<SessionDeletionTargets | null>;

  /**
   * Hard-delete a session and every artifact row pointing at it. Also
   * sweeps any in-flight TUS resources whose `sessionId` matches.
   *
   * Callers should clean the targets returned by
   * `getSessionDeletionTargets` first, then call this to commit the
   * metadata delete. Implementations MUST run the row deletes inside
   * one transaction (or equivalent) so a concurrent read can't observe
   * a session row whose artifacts have already been cleared.
   */
  deleteSession(
    sessionId: string,
    opts?: { userId?: string },
  ): Promise<SessionDeletionTargets | null>;
}

export interface StoreStats {
  sessionCount: number;
  totalBytes: number;
  /** ISO-8601 strings, "YYYY-MM-DD" granularity. */
  perDay: Record<string, { sessions: number; bytes: number }>;
}

export { MemoryStore } from "./memory.js";
