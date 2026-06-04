import { randomBytes } from "node:crypto";
import { readFile } from "node:fs/promises";
import type { Request, RequestHandler, Response } from "express";
import express from "express";

import { IngestEvents } from "../events.js";
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
      await handle.dispose().catch(() => {});
      return tusError(res, 500, `write failed: ${(err as Error).message}`);
    }
    if (written !== contentLength) {
      await handle.dispose().catch(() => {});
      return tusError(res, 400, `short body: expected ${contentLength} got ${written}`);
    }

    const newOffset = storageOffset + written;
    const now = new Date().toISOString();
    try {
      await handle.commitChunk(newOffset);
    } catch (err) {
      await handle.dispose().catch(() => {});
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
      const session = await opts.store.upsertSessionArtifact(
        record.sessionId,
        {
          kind: record.metadata.artifact_kind,
          filename: record.metadata.filename,
          bytes: finalized.bytes,
          sha256: finalized.sha256,
          storedAt: now,
          uri: finalized.uri,
        },
        manifestJson,
      );
      await opts.store.deleteResource(id);
      events.emit({ type: "resource.finalized", resourceId: id, sessionId: record.sessionId });
      events.emit({ type: "session.updated", session });
      if (opts.onSession && session.artifacts["media"]) {
        // Fire the user-supplied hook only once the media artifact has
        // landed; firing on every artifact would surprise pipeline code.
        Promise.resolve(opts.onSession(session)).catch((err) => {
          // eslint-disable-next-line no-console
          console.error("[ego-ingest] onSession hook threw:", err);
        });
      }
    }

    res.setHeader("Upload-Offset", String(newOffset));
    res.status(204).end();
  });

  router.delete("/:resourceId", async (req, res) => {
    if (!(await runAuth(auth, req, res))) return;
    const id = req.params.resourceId!;
    const record = await opts.store.getResource(id);
    if (!record) return res.status(404).end();
    const handle = await opts.storage.reopenResource(id);
    if (handle) await handle.dispose();
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

function tusError(res: Response, status: number, message: string): void {
  res.status(status).type("text/plain").end(message + "\n");
}

function newResourceId(): string {
  return randomBytes(12).toString("base64url");
}

function trimSlashes(s: string): string {
  return s.replace(/\/+$/, "");
}

// Re-export the metadata type so consumers can import from one entry.
export type { UploadMetadata };
