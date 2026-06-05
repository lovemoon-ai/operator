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

  getSession(id: string): Promise<SessionRecord | null>;

  listSessions(opts?: {
    limit?: number;
    cursor?: string;
    order?: "asc" | "desc";
  }): Promise<{ items: SessionRecord[]; nextCursor: string | null }>;

  /** Lifetime-aggregated stats. Cheap implementations can recompute on call. */
  stats(): Promise<StoreStats>;
}

export interface StoreStats {
  sessionCount: number;
  totalBytes: number;
  /** ISO-8601 strings, "YYYY-MM-DD" granularity. */
  perDay: Record<string, { sessions: number; bytes: number }>;
}

export { MemoryStore } from "./memory.js";
