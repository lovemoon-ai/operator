import { randomBytes } from "node:crypto";
import { readFile } from "node:fs/promises";
import type { Request, RequestHandler, Response } from "express";
import express from "express";

import { IngestEvents } from "../events.js";
import type { ArtifactWriteHandle } from "../storage/index.js";
import type { SessionDeletionTargets } from "../store/index.js";
import type {
  AuthFn,
  IngestOptions,
  ResourceRecord,
  UploadMetadata,
} from "../types.js";
import { SCHEMA_VERSION, TUS_VERSION } from "../types.js";
import { parseUploadMetadata } from "./metadata.js";

const TUS_EXTENSIONS = "creation,termination";
const DEFAULT_MAX_UPLOAD = 100 * 1024 ** 3; // 100 GB
const DEFAULT_ORPHAN_TIMEOUT_MS = 15 * 60 * 1000; // 15 minutes

/**
 * Mount as `app.use('/ingest', createIngestMiddleware(...))`.
 *
 * Implements TUS 1.0.0 core + the `creation` and `termination`
 * extensions. We deliberately do not implement `concatenation`
 * (the XR client uploads each artifact as its own resource) or
 * `creation-defer-length` (the XR client always knows Upload-Length
 * up front because the MP4 is finalized before upload starts).
 *
 * Routing:
 *   OPTIONS  /                         → capabilities
 *   POST     /                         → create resource
 *   HEAD     /<resourceId>             → query offset
 *   PATCH    /<resourceId>             → append bytes
 *   DELETE   /<resourceId>             → cancel in-flight upload
 */
export function createIngestMiddleware(opts: IngestOptions & { events?: IngestEvents }): RequestHandler {
  const events = opts.events ?? new IngestEvents();
  const auth = opts.auth ?? alwaysAllow;
  const acceptedSchemas = new Set(opts.acceptedSchemas ?? [SCHEMA_VERSION]);
  const maxUploadBytes = opts.maxUploadSizeBytes ?? DEFAULT_MAX_UPLOAD;
  const orphanTimeoutMs = opts.orphanTimeoutMs ?? DEFAULT_ORPHAN_TIMEOUT_MS;

  // Map of session_id → setTimeout handle for the watchdog. Scheduled
  // when manifest lands without media; cleared when media (or any
  // non-manifest artifact, which counts as the session "really
  // started") arrives. We use a sparse Map instead of a per-session
  // record so the orphan logic costs zero memory for sessions that
  // complete normally.
  const orphanTimers = new Map<string, NodeJS.Timeout>();
  function clearOrphanTimer(sessionId: string): void {
    const t = orphanTimers.get(sessionId);
    if (t) {
      clearTimeout(t);
      orphanTimers.delete(sessionId);
    }
  }
  function scheduleOrphanTimer(sessionId: string, durationMs?: number): void {
    const ms = durationMs ?? orphanTimeoutMs;
    if (orphanTimeoutMs <= 0) return; // watchdog globally disabled
    clearOrphanTimer(sessionId);
    if (ms <= 0) {
      // Resume path: the deadline has already passed (manifest is
      // older than orphanTimeoutMs). Fire immediately on the next
      // tick so the persisted index gets the `expired` flag without
      // blocking server startup on a sync call.
      setImmediate(() => void runOrphanCheck(sessionId).catch(logTimerError));
      return;
    }
    orphanTimers.set(
      sessionId,
      setTimeout(() => {
        orphanTimers.delete(sessionId);
        // The setTimeout callback can't be async (Node treats a
        // returned Promise rejection as unhandled), so we wrap the
        // real work in an explicitly-caught helper. Any store/event
        // failure now lands in a clear log line instead of crashing
        // the ingest process.
        void runOrphanCheck(sessionId).catch(logTimerError);
      }, ms).unref(),
    );
  }

  async function runOrphanCheck(sessionId: string): Promise<void> {
    const s = await opts.store.getSession(sessionId);
    if (!s) return; // session got deleted in the meantime
    if (s.artifacts["media"]) return; // raced — media arrived just before timer fired
    if (s.expired) return; // already marked
    const reason =
      `no media artifact within ${formatDuration(orphanTimeoutMs)} of manifest landing`;
    const updated = await opts.store.markSessionExpired(sessionId, {
      at: new Date().toISOString(),
      reason,
    });
    // eslint-disable-next-line no-console
    console.warn(`[ego-ingest] session ${sessionId} expired: ${reason}`);
    if (updated) events.emit({ type: "session.updated", session: updated });
    events.emit({ type: "session.expired", sessionId, reason });
  }

  function logTimerError(err: unknown): void {
    // eslint-disable-next-line no-console
    console.error(`[ego-ingest] orphan watchdog failed:`, err);
  }

  /**
   * Resume watchdogs after a server restart. The in-memory timer
   * map is process-local — without this, a manifest that landed
   * 14 minutes before a restart would lose its 1-minute remaining
   * countdown and get a fresh 15 minutes instead, hiding stuck
   * uploads from the dashboard.
   *
   * For each session that has a manifest but no media and isn't
   * already flagged expired, compute remaining time = (manifest
   * storedAt + orphanTimeoutMs) − now and schedule with that.
   * Sessions whose deadline already passed fire on the next tick
   * via the `durationMs <= 0` branch in scheduleOrphanTimer.
   *
   * The scan pages through `listSessions` 500 at a time so even a
   * 100k-session deployment is bounded by store IO, not by us
   * holding the whole index in memory at once.
   */
  async function rehydrateOrphanTimers(): Promise<number> {
    if (orphanTimeoutMs <= 0) return 0;
    let cursor: string | undefined;
    let resumed = 0;
    const now = Date.now();
    do {
      const page = await opts.store.listSessions({ limit: 500, cursor, order: "desc" });
      for (const s of page.items) {
        if (s.expired) continue;
        const manifest = s.artifacts["manifest"];
        if (!manifest) continue;
        if (s.artifacts["media"]) continue;
        const landedAt = Date.parse(manifest.storedAt);
        if (!Number.isFinite(landedAt)) continue; // pathological; let it expire on next manifest event
        const remaining = landedAt + orphanTimeoutMs - now;
        scheduleOrphanTimer(s.id, remaining);
        resumed += 1;
      }
      cursor = page.nextCursor ?? undefined;
    } while (cursor);
    return resumed;
  }

  // Kick off rehydration without blocking the middleware constructor
  // return. The middleware is ready to accept uploads immediately;
  // resumed timers just settle into place in the background.
  rehydrateOrphanTimers()
    .then((n) => {
      if (n > 0) {
        // eslint-disable-next-line no-console
        console.log(`[ego-ingest] resumed ${n} orphan watchdog timer(s) from disk`);
      }
    })
    .catch(logTimerError);

  const router = express.Router();

  router.use((req, res, next) => {
    // Every TUS response gets these. Cheaper than per-handler repetition.
    res.setHeader("Tus-Resumable", TUS_VERSION);
    res.setHeader("Cache-Control", "no-store");
    next();
  });

  router.options("/", (_req, res) => {
    res.setHeader("Tus-Version", TUS_VERSION);
    res.setHeader("Tus-Extension", TUS_EXTENSIONS);
    res.setHeader("Tus-Max-Size", String(maxUploadBytes));
    res.status(204).end();
  });

  router.post("/", async (req, res) => {
    if (!(await runAuth(auth, req, res))) return;
    if (req.header("Tus-Resumable") !== TUS_VERSION) return tusError(res, 412, "Tus-Resumable mismatch");

    const uploadLength = Number(req.header("Upload-Length") ?? "0");
    if (!Number.isFinite(uploadLength) || uploadLength <= 0) {
      return tusError(res, 400, "Upload-Length required and > 0");
    }
    if (uploadLength > maxUploadBytes) {
      return tusError(res, 413, `Upload-Length exceeds Tus-Max-Size (${maxUploadBytes})`);
    }

    const metadata = parseUploadMetadata(req.header("Upload-Metadata"));
    if (!metadata.session_id || !metadata.artifact_kind) {
      return tusError(res, 400, "Upload-Metadata must include session_id and artifact_kind");
    }
    if (metadata.schema && !acceptedSchemas.has(metadata.schema)) {
      return tusError(res, 415, `unsupported schema: ${metadata.schema}`);
    }

    const resourceId = newResourceId();
    const now = new Date().toISOString();

    await opts.storage.openResource(resourceId, { uploadLength });

    const record: ResourceRecord = {
      id: resourceId,
      sessionId: metadata.session_id,
      artifactKind: metadata.artifact_kind,
      uploadLength,
      offset: 0,
      metadata,
      createdAt: now,
    };
    await opts.store.createResource(record);
    events.emit({ type: "resource.created", resource: record });

    res.setHeader("Location", `${trimSlashes(req.baseUrl)}/${resourceId}`);
    res.setHeader("Upload-Offset", "0");
    res.setHeader("Upload-Length", String(uploadLength));
    res.status(201).end();
  });

  router.head("/:resourceId", async (req, res) => {
    if (!(await runAuth(auth, req, res))) return;
    const id = req.params.resourceId!;
    const record = await opts.store.getResource(id);
    if (!record) return res.status(404).end();
    // Trust the storage driver's actual append position; if it diverged
    // from the persisted JSON index, repair the index so the following PATCH
    // validates against the same offset HEAD just advertised.
    const diskOffset = await opts.storage.resourceOffset(id);
    if (diskOffset > record.uploadLength) return tusError(res, 409, "storage offset exceeds Upload-Length");
    const offset = diskOffset;
    if (offset !== record.offset) {
      await opts.store.setResourceOffset(id, offset, new Date().toISOString());
    }
    res.setHeader("Upload-Offset", String(offset));
    res.setHeader("Upload-Length", String(record.uploadLength));
    res.status(200).end();
  });

  router.patch("/:resourceId", async (req, res) => {
    if (!(await runAuth(auth, req, res))) return;
    if (req.header("Tus-Resumable") !== TUS_VERSION) return tusError(res, 412, "Tus-Resumable mismatch");
    if (req.header("Content-Type") !== "application/offset+octet-stream") {
      return tusError(res, 415, "Content-Type must be application/offset+octet-stream");
    }
    const id = req.params.resourceId!;
    const record = await opts.store.getResource(id);
    if (!record) return res.status(404).end();
    const storageOffset = await opts.storage.resourceOffset(id);
    if (storageOffset > record.uploadLength) {
      return tusError(res, 409, "storage offset exceeds Upload-Length");
    }

    const clientOffset = Number(req.header("Upload-Offset") ?? "-1");
    if (!Number.isFinite(clientOffset) || clientOffset < 0) {
      return tusError(res, 400, "Upload-Offset required");
    }
    if (clientOffset !== storageOffset) {
      return tusError(res, 409, `Upload-Offset mismatch: server=${storageOffset} client=${clientOffset}`);
    }

    const contentLength = Number(req.header("Content-Length") ?? "-1");
    if (!Number.isFinite(contentLength) || contentLength < 0) {
      return tusError(res, 400, "Content-Length required");
    }
    if (storageOffset + contentLength > record.uploadLength) {
      return tusError(res, 413, "chunk would overflow Upload-Length");
    }

    const maybeHandle = await opts.storage.reopenResource(id);
    if (!maybeHandle) {
      tusError(res, 410, "storage lost this resource");
      return;
    }
    // Alias to a definitely-non-null const so the Promise executor
    // below doesn't trip control-flow narrowing inside the closure.
    const handle = maybeHandle;

    // Stream the request body directly into storage so we never buffer
    // a multi-MB chunk in memory.
    let written = 0;
    const done = new Promise<void>((resolve, reject) => {
      const onError = (err: Error) => {
        cleanup();
        reject(err);
      };
      const onFinish = () => {
        cleanup();
        resolve();
      };
      function cleanup() {
        req.off("data", onData);
        req.off("error", onError);
        handle.appendStream.off("error", onError);
        handle.appendStream.off("finish", onFinish);
      }
      function onData(chunk: Buffer) {
        written += chunk.length;
      }
      req.on("data", onData);
      req.on("error", onError);
      handle.appendStream.on("error", onError);
      handle.appendStream.on("finish", onFinish);
      req.pipe(handle.appendStream);
    });

    try {
      await done;
    } catch (err) {
      if (!(await rollbackChunkOrFail(res, handle, storageOffset))) return;
      return tusError(res, 500, `write failed: ${(err as Error).message}`);
    }
    if (written !== contentLength) {
      if (!(await rollbackChunkOrFail(res, handle, storageOffset))) return;
      return tusError(res, 400, `short body: expected ${contentLength} got ${written}`);
    }

    const newOffset = storageOffset + written;
    const now = new Date().toISOString();
    try {
      await handle.commitChunk(newOffset);
    } catch (err) {
      if (!(await rollbackChunkOrFail(res, handle, storageOffset))) return;
      return tusError(res, 500, `commit failed: ${(err as Error).message}`);
    }
    await opts.store.setResourceOffset(id, newOffset, now);
    events.emit({
      type: "resource.progress",
      resourceId: id,
      offset: newOffset,
      uploadLength: record.uploadLength,
    });

    if (newOffset >= record.uploadLength) {
      const finalized = await handle.finalize(record.metadata, record.uploadLength);
      let manifestJson: Record<string, unknown> | undefined;
      if (record.metadata.artifact_kind === "manifest") {
        try {
          const text = await readFile(finalized.uri, "utf8");
          manifestJson = JSON.parse(text) as Record<string, unknown>;
        } catch {
          /* still record the artifact even if parse fails */
        }
      }

      // Integrity check, part 1 of 2: if the artifact we just received
      // is something the manifest already declared a SHA-256 for,
      // compare server-computed bytes-on-disk hash against the
      // client-declared hash. Mismatch → mark corrupt + log loud.
      // The common case (mp4 arriving after manifest) is fully
      // covered here; the late-manifest path (mp4 first, manifest
      // after) is handled in "part 2 of 2" just below.
      const existingSession = await opts.store.getSession(record.sessionId);
      const declared = extractDeclaredSha256(
        existingSession?.manifest,
        record.metadata.artifact_kind,
      );
      let corrupt: boolean | undefined;
      if (declared) {
        if (!finalized.sha256) {
          // Manifest expects us to verify but the storage layer was
          // configured without `computeHashes`. We CANNOT prove
          // integrity here, so fail closed rather than silently
          // letting an unverified artifact through. This is the only
          // way to keep the "media corrupt → worker skipped"
          // guarantee meaningful — otherwise a misconfigured
          // deployment looks fine until corruption silently happens.
          corrupt = true;
          // eslint-disable-next-line no-console
          console.error(
            `[ego-ingest] declared sha256 ${declared} for ${record.sessionId}/${record.metadata.artifact_kind} ` +
              `but server-side hashing is disabled — failing closed (set computeHashes:true on the storage driver)`,
          );
        } else if (declared !== finalized.sha256) {
          corrupt = true;
          // eslint-disable-next-line no-console
          console.error(
            `[ego-ingest] sha256 mismatch for ${record.sessionId}/${record.metadata.artifact_kind}: ` +
              `expected=${declared} actual=${finalized.sha256}`,
          );
        }
      }

      let session = await opts.store.upsertSessionArtifact(
        record.sessionId,
        {
          kind: record.metadata.artifact_kind,
          filename: record.metadata.filename,
          bytes: finalized.bytes,
          sha256: finalized.sha256,
          storedAt: now,
          uri: finalized.uri,
          corrupt,
          expectedSha256: declared,
        },
        manifestJson,
      );

      // Integrity check, part 2 of 2: when manifest is the artifact we
      // just received, retroactively verify every PRIOR artifact whose
      // hash the manifest now declares. This catches the rare ordering
      // where the mp4 PATCH completes before the manifest PATCH does.
      if (record.metadata.artifact_kind === "manifest" && manifestJson) {
        for (const [kind, art] of Object.entries(session.artifacts)) {
          if (kind === "manifest" || art.corrupt) continue;
          const expected = extractDeclaredSha256(manifestJson, kind);
          if (!expected) continue;
          // Symmetric to part 1: missing server-side hash is a fail-closed
          // condition when the manifest declares one.
          let reason: string | null = null;
          if (!art.sha256) {
            reason =
              `declared sha256 ${expected} but no server-computed sha256 on the stored artifact ` +
              `(computeHashes likely disabled when this artifact landed)`;
          } else if (art.sha256 !== expected) {
            reason = `expected=${expected} actual=${art.sha256}`;
          }
          if (!reason) continue;
          // eslint-disable-next-line no-console
          console.error(
            `[ego-ingest] integrity failure for ${record.sessionId}/${kind} ` +
              `(detected via late manifest): ${reason}`,
          );
          session = await opts.store.upsertSessionArtifact(record.sessionId, {
            ...art,
            corrupt: true,
            expectedSha256: expected,
          });
        }
      }

      await opts.store.deleteResource(id);
      events.emit({ type: "resource.finalized", resourceId: id, sessionId: record.sessionId });
      events.emit({ type: "session.updated", session });

      // Orphan watchdog wiring:
      //   - manifest landed, media not yet → arm the timer
      //   - media (or anything other than manifest) landed → disarm
      //   - already-expired sessions can recover: receiving media
      //     after expiration is benign because we just clear the
      //     timer and let the worker pipeline gate decide (still
      //     gated on !corrupt + manifest present)
      const kind = record.metadata.artifact_kind;
      if (kind === "manifest" && !session.artifacts["media"]) {
        scheduleOrphanTimer(record.sessionId);
      } else if (kind !== "manifest") {
        clearOrphanTimer(record.sessionId);
      }

      // Gate the worker pipeline on three conditions:
      //   (1) media artifact is on disk
      //   (2) media isn't flagged corrupt
      //   (3) manifest is present (so any declared hash got a chance
      //       to compare against the media)
      // Bullet (3) prevents the late-manifest race from kicking off
      // a preview/.rrd job against bytes we're about to mark corrupt.
      const media = session.artifacts["media"];
      const hookReady =
        !!media && !media.corrupt && !!session.manifest;
      if (opts.onSession && hookReady) {
        Promise.resolve(opts.onSession(session)).catch((err) => {
          // eslint-disable-next-line no-console
          console.error("[ego-ingest] onSession hook threw:", err);
        });
      } else if (media && media.corrupt) {
        // eslint-disable-next-line no-console
        console.warn(
          `[ego-ingest] session ${record.sessionId}: media corrupt, NOT firing onSession`,
        );
      }
    }

    res.setHeader("Upload-Offset", String(newOffset));
    res.status(204).end();
  });

  router.delete("/sessions/:sessionId", async (req, res) => {
    if (!(await runAuth(auth, req, res))) return;
    const sessionId = req.params.sessionId!;
    clearOrphanTimer(sessionId);
    const targets = await opts.store.getSessionDeletionTargets(sessionId);
    if (!targets) return res.status(404).end();
    try {
      await cleanupSessionStorage(opts, targets);
    } catch (err) {
      // eslint-disable-next-line no-console
      console.warn(`[ego-ingest] cleanupSessionStorage(${sessionId}) failed: ${(err as Error).message}`);
      return tusError(res, 500, "storage cleanup failed");
    }
    await opts.store.deleteSession(sessionId);
    events.emit({ type: "session.deleted", sessionId, userId: null });
    res.status(204).end();
  });

  router.delete("/:resourceId", async (req, res) => {
    if (!(await runAuth(auth, req, res))) return;
    const id = req.params.resourceId!;
    const record = await opts.store.getResource(id);
    if (!record) return res.status(404).end();
    const handle = await opts.storage.reopenResource(id);
    try {
      if (handle) await handle.dispose();
    } catch (err) {
      // eslint-disable-next-line no-console
      console.warn(`[ego-ingest] disposeResource(${id}) failed: ${(err as Error).message}`);
      return tusError(res, 500, "storage cleanup failed");
    }
    await opts.store.deleteResource(id);
    res.status(204).end();
  });

  return router;
}

// --- helpers ---------------------------------------------------------------

function alwaysAllow(): true {
  return true;
}

async function runAuth(auth: AuthFn, req: Request, res: Response): Promise<boolean> {
  const ok = await auth(req);
  if (!ok) {
    res.status(401).setHeader("WWW-Authenticate", "Bearer").end();
    return false;
  }
  return true;
}

async function cleanupSessionStorage(
  opts: IngestOptions,
  targets: SessionDeletionTargets,
): Promise<void> {
  const failures: string[] = [];
  for (const resourceId of targets.resourceIds) {
    try {
      const handle = await opts.storage.reopenResource(resourceId);
      if (handle) await handle.dispose();
    } catch (err) {
      failures.push(`disposeResource(${resourceId}): ${(err as Error).message}`);
    }
  }
  for (const uri of targets.artifactUris) {
    try {
      await opts.storage.deleteFinalized(uri);
    } catch (err) {
      failures.push(`deleteFinalized(${uri}): ${(err as Error).message}`);
    }
  }
  if (failures.length > 0) {
    throw new Error(failures.join("; "));
  }
}

function tusError(res: Response, status: number, message: string): void {
  res.status(status).type("text/plain").end(message + "\n");
}

async function rollbackChunkOrFail(
  res: Response,
  handle: ArtifactWriteHandle,
  committedOffset: number,
): Promise<boolean> {
  try {
    await rollbackChunk(handle, committedOffset);
    return true;
  } catch (err) {
    tusError(res, 500, `rollback failed: ${(err as Error).message}`);
    return false;
  }
}

async function rollbackChunk(handle: ArtifactWriteHandle, committedOffset: number): Promise<void> {
  if (handle.abortChunk) {
    try {
      await handle.abortChunk(committedOffset);
    } catch (err) {
      await handle.dispose().catch(() => {});
      throw err;
    }
    return;
  }
  await handle.dispose();
}

function newResourceId(): string {
  return randomBytes(12).toString("base64url");
}

function trimSlashes(s: string): string {
  return s.replace(/\/+$/, "");
}

function formatDuration(ms: number): string {
  if (ms < 60_000) return `${Math.round(ms / 1000)}s`;
  if (ms < 60 * 60_000) return `${Math.round(ms / 60_000)}m`;
  return `${(ms / (60 * 60_000)).toFixed(1)}h`;
}

/**
 * Pull a declared SHA-256 for a given artifact kind out of a parsed
 * manifest. Returns the hex string normalised to lowercase, or
 * `undefined` if the manifest didn't declare a hash for this kind.
 *
 * Manifest shape (set by xr/scripts/session_spool_writer.gd):
 *   {
 *     ...,
 *     "artifacts": {
 *       "media":    { "filename": "...", "bytes": N, "sha256": "abc…", "hash_algo": "sha256" },
 *       "manifest": { ... optional ... }
 *     }
 *   }
 *
 * We accept either uppercase or lowercase hex (the GDScript
 * `hex_encode` happens to be lowercase, but we don't bind to that),
 * and reject anything that isn't exactly 64 hex chars to avoid
 * spurious matches against random fields.
 */
function extractDeclaredSha256(
  manifest: Record<string, unknown> | undefined,
  kind: string,
): string | undefined {
  if (!manifest) return undefined;
  const artifacts = manifest["artifacts"];
  if (!artifacts || typeof artifacts !== "object") return undefined;
  const slot = (artifacts as Record<string, unknown>)[kind];
  if (!slot || typeof slot !== "object") return undefined;
  const sha = (slot as Record<string, unknown>)["sha256"];
  if (typeof sha !== "string") return undefined;
  if (!/^[a-f0-9]{64}$/i.test(sha)) return undefined;
  return sha.toLowerCase();
}

// Re-export the metadata type so consumers can import from one entry.
export type { UploadMetadata };
