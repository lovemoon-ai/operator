import type {
  FinalizedArtifact,
  ResourceRecord,
  SessionRecord,
} from "../types.js";
import type { SessionStore, StoreStats } from "./index.js";

/**
 * In-process metadata store with optional JSON-file persistence.
 *
 * Use this for development and single-node deployments where the data
 * volume fits comfortably in RAM (anything up to ~100k sessions). For
 * larger deployments swap in a SQLite-backed store — same interface.
 */
export interface MemoryStoreOptions {
  /** If set, snapshot to this file on every mutation. */
  persistTo?: string;
}

export class MemoryStore implements SessionStore {
  private resources = new Map<string, ResourceRecord>();
  private sessions = new Map<string, SessionRecord>();
  private readonly persistTo: string | undefined;
  private persistPromise: Promise<void> = Promise.resolve();

  constructor(opts: MemoryStoreOptions = {}) {
    this.persistTo = opts.persistTo;
    if (this.persistTo) {
      this.loadFromDisk();
    }
  }

  // --- Resource ops ---------------------------------------------------------

  async createResource(record: ResourceRecord): Promise<void> {
    this.resources.set(record.id, { ...record });
    this.schedulePersist();
  }

  async getResource(id: string): Promise<ResourceRecord | null> {
    const r = this.resources.get(id);
    return r ? { ...r } : null;
  }

  async setResourceOffset(id: string, offset: number, lastPatchAt: string): Promise<void> {
    const r = this.resources.get(id);
    if (!r) return;
    r.offset = offset;
    r.lastPatchAt = lastPatchAt;
    this.schedulePersist();
  }

  async deleteResource(id: string): Promise<void> {
    if (this.resources.delete(id)) this.schedulePersist();
  }

  // --- Session ops ----------------------------------------------------------

  async upsertSessionArtifact(
    sessionId: string,
    artifact: FinalizedArtifact,
    manifest?: Record<string, unknown>,
  ): Promise<SessionRecord> {
    const existing = this.sessions.get(sessionId);
    const session: SessionRecord =
      existing ?? {
        id: sessionId,
        receivedAt: new Date().toISOString(),
        artifacts: {},
        totalBytes: 0,
      };
    const prev = session.artifacts[artifact.kind];
    if (prev) session.totalBytes -= prev.bytes;
    session.artifacts[artifact.kind] = artifact;
    session.totalBytes += artifact.bytes;
    if (manifest) session.manifest = manifest;
    this.sessions.set(sessionId, session);
    this.schedulePersist();
    return { ...session, artifacts: { ...session.artifacts } };
  }

  async markSessionExpired(
    sessionId: string,
    expired: { at: string; reason: string },
  ): Promise<SessionRecord | null> {
    const s = this.sessions.get(sessionId);
    if (!s) return null;
    if (!s.expired) {
      s.expired = expired;
      this.schedulePersist();
    }
    return { ...s, artifacts: { ...s.artifacts } };
  }

  async getSession(id: string, _opts?: { userId?: string }): Promise<SessionRecord | null> {
    const s = this.sessions.get(id);
    return s ? { ...s, artifacts: { ...s.artifacts } } : null;
  }

  async listSessions(opts: { limit?: number; cursor?: string; order?: "asc" | "desc"; userId?: string } = {}) {
    const order = opts.order ?? "desc";
    const limit = Math.max(1, Math.min(opts.limit ?? 50, 500));
    const all = Array.from(this.sessions.values()).sort((a, b) => {
      const cmp = a.receivedAt.localeCompare(b.receivedAt);
      return order === "asc" ? cmp : -cmp;
    });
    let start = 0;
    if (opts.cursor) {
      const idx = all.findIndex((s) => s.id === opts.cursor);
      if (idx >= 0) start = idx + 1;
    }
    const items = all.slice(start, start + limit).map((s) => ({ ...s, artifacts: { ...s.artifacts } }));
    const nextCursor = start + limit < all.length ? items[items.length - 1]?.id ?? null : null;
    return { items, nextCursor };
  }

  async deleteSession(
    sessionId: string,
    _opts?: { userId?: string },
  ): Promise<{ artifactUris: string[] } | null> {
    const s = this.sessions.get(sessionId);
    if (!s) return null;
    // MemoryStore is single-tenant; we ignore opts.userId and rely on
    // the caller (the read API) to gate by ownership before getting
    // here. SqliteStore enforces scoping itself because it carries the
    // user_id column.
    const artifactUris = Object.values(s.artifacts).map((a) => a.uri);
    this.sessions.delete(sessionId);
    // Sweep any in-flight upload that targets this session — without
    // this, a TUS PATCH still mid-flight would resurrect the row on
    // finalize and leave us with the old artifacts dangling.
    for (const [rid, r] of this.resources) {
      if (r.sessionId === sessionId) this.resources.delete(rid);
    }
    this.schedulePersist();
    return { artifactUris };
  }

  async stats(_opts?: { userId?: string }): Promise<StoreStats> {
    const perDay: StoreStats["perDay"] = {};
    let totalBytes = 0;
    for (const s of this.sessions.values()) {
      const day = s.receivedAt.slice(0, 10);
      const bucket = perDay[day] ?? (perDay[day] = { sessions: 0, bytes: 0 });
      bucket.sessions += 1;
      bucket.bytes += s.totalBytes;
      totalBytes += s.totalBytes;
    }
    return { sessionCount: this.sessions.size, totalBytes, perDay };
  }

  // --- Persistence ----------------------------------------------------------

  private schedulePersist(): void {
    if (!this.persistTo) return;
    // Coalesce bursts: append our save onto the trailing edge of the
    // last in-flight write so two rapid PATCHes don't both fsync.
    this.persistPromise = this.persistPromise.then(() => this.writeNow());
  }

  private async writeNow(): Promise<void> {
    if (!this.persistTo) return;
    const fs = await import("node:fs/promises");
    const payload = JSON.stringify(
      {
        resources: Object.fromEntries(this.resources),
        sessions: Object.fromEntries(this.sessions),
      },
      null,
      2,
    );
    const tmp = this.persistTo + ".tmp";
    await fs.writeFile(tmp, payload, "utf8");
    await fs.rename(tmp, this.persistTo);
  }

  private loadFromDisk(): void {
    if (!this.persistTo) return;
    try {
      // Sync import is fine — this runs once at construction.
      // eslint-disable-next-line @typescript-eslint/no-var-requires
      const fs = require("node:fs") as typeof import("node:fs");
      const text = fs.readFileSync(this.persistTo, "utf8");
      const parsed = JSON.parse(text) as {
        resources?: Record<string, ResourceRecord>;
        sessions?: Record<string, SessionRecord>;
      };
      for (const [k, v] of Object.entries(parsed.resources ?? {})) this.resources.set(k, v);
      for (const [k, v] of Object.entries(parsed.sessions ?? {})) this.sessions.set(k, v);
    } catch {
      /* fresh start */
    }
  }
}
