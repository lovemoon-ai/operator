import type { Request, RequestHandler, Response } from "express";
import express from "express";

import type { IngestEvents } from "./events.js";
import type { StorageDriver } from "./storage/index.js";
import type { SessionStore } from "./store/index.js";

export interface ReadApiOptions {
  store: SessionStore;
  storage: StorageDriver;
  events: IngestEvents;
  /**
   * App-layer hook for scoping reads to the requesting user. Wired by
   * the app's auth middleware (e.g. AsyncLocalStorage lookup, or
   * `req.user.id`). Stores that don't carry a user dimension simply
   * receive `undefined` and behave as before.
   *
   * Returning `null` means "authenticated but no rows match" — the
   * handler short-circuits with an empty list / 404, avoiding the
   * "logged-out user sees everyone's sessions" failure mode if the
   * upstream auth middleware is missing.
   */
  userIdFromReq?: (req: Request) => string | null | undefined;
  /**
   * Optional callback fired after a session's metadata + bytes have
   * been removed. The app uses this to clear satellite tables that
   * ego-ingest doesn't know about (per-session reviews, audit logs,
   * …). Errors are caught + logged so a satellite failure can't
   * prevent the DELETE from returning 204.
   */
  onSessionDeleted?: (sessionId: string) => void | Promise<void>;
}

/**
 * Read-only HTTP API consumed by the dashboard UI and by any custom
 * React/Vue embeds.
 *
 *   GET  /sessions               list w/ pagination
 *   GET  /sessions/:id           single session
 *   GET  /sessions/:id/artifacts/:kind   stream the bytes
 *   GET  /stats                  aggregate counters
 *   GET  /events                 server-sent events (live updates)
 *
 * Mount under whatever path you want — typically `/ingest/api`.
 */
export function createReadApi(opts: ReadApiOptions): RequestHandler {
  const router = express.Router();

  router.get("/sessions", async (req, res) => {
    const userId = opts.userIdFromReq?.(req);
    if (userId === null) return res.json({ items: [], nextCursor: null });
    const limit = parseIntParam(req.query.limit, 50);
    const cursor = typeof req.query.cursor === "string" ? req.query.cursor : undefined;
    const order = req.query.order === "asc" ? "asc" : "desc";
    const page = await opts.store.listSessions({ limit, cursor, order, userId: userId ?? undefined });
    res.json(page);
  });

  router.get("/sessions/:id", async (req, res) => {
    const userId = opts.userIdFromReq?.(req);
    if (userId === null) return res.status(404).json({ error: "not found" });
    const session = await opts.store.getSession(req.params.id!, { userId: userId ?? undefined });
    if (!session) return res.status(404).json({ error: "not found" });
    res.json(session);
  });

  // The trailing `:filename?` is intentionally permissive — Rerun
  // 0.33's URL categorizer (Rust `url` crate inside the WASM viewer)
  // refuses to load a recording unless the path ends in `.rrd`,
  // even when the response is served with the right content-type.
  // So the viewer hits `.../artifacts/rrd/session.rrd` while the
  // dashboard's "download" link sticks with `.../artifacts/rrd`. We
  // serve both off the same handler — the filename segment is purely
  // cosmetic to satisfy the extension check.
  router.get("/sessions/:id/artifacts/:kind/:filename?", async (req, res) => {
    const userId = opts.userIdFromReq?.(req);
    if (userId === null) return res.status(404).end();
    const session = await opts.store.getSession(req.params.id!, { userId: userId ?? undefined });
    if (!session) return res.status(404).end();
    const artifact = session.artifacts[req.params.kind!];
    if (!artifact) return res.status(404).end();

    const contentType = contentTypeFor(artifact.kind, artifact.filename);
    // "Inline" kinds are the ones a browser is expected to render in
    // place (a <video> tag, the Rerun WASM viewer, …) — these need
    // Range support so seeking and Safari/iOS playback work, and they
    // must NOT carry Content-Disposition: attachment (which forces a
    // download). Anything else (the raw SpatialMP4 archive, the
    // manifest JSON, controller dumps, …) keeps the attachment
    // disposition so a "download" link still feels like a download.
    const inlineKind = isInlineKind(artifact.kind, artifact.filename);

    // Always advertise Range capability so the browser knows it can
    // issue Range requests on the next round-trip.
    res.setHeader("Accept-Ranges", "bytes");
    res.setHeader("Content-Type", contentType);

    const rangeHeader = req.headers.range;
    if (inlineKind && typeof rangeHeader === "string") {
      const parsed = parseRange(rangeHeader, artifact.bytes);
      if (parsed === "invalid") {
        res.setHeader("Content-Range", `bytes */${artifact.bytes}`);
        return res.status(416).end();
      }
      if (parsed) {
        const { start, end } = parsed;
        const stream = await opts.storage.openFinalized(artifact.uri, { start, end });
        if (!stream) return res.status(410).end();
        res.status(206);
        res.setHeader("Content-Length", String(end - start + 1));
        res.setHeader("Content-Range", `bytes ${start}-${end}/${artifact.bytes}`);
        res.setHeader(
          "Content-Disposition",
          `inline; filename="${safeFilename(artifact.filename)}"`,
        );
        return stream.pipe(res);
      }
      // Header present but empty match → fall through to a full 200.
    }

    const stream = await opts.storage.openFinalized(artifact.uri);
    if (!stream) return res.status(410).end();
    res.setHeader("Content-Length", String(artifact.bytes));
    res.setHeader(
      "Content-Disposition",
      `${inlineKind ? "inline" : "attachment"}; filename="${safeFilename(artifact.filename)}"`,
    );
    stream.pipe(res);
  });

  // Hard-delete a session. Powers the "Remove" button in the dashboard.
  //
  // Ordering matters: store first, storage second. If we deleted the
  // bytes first and then the store row delete failed, we'd be left with
  // a metadata row pointing at vapor — every subsequent GET would 410.
  // The other way around just leaves orphaned byte files, which a
  // future cleanup pass can sweep by diffing disk against the
  // artifacts table.
  router.delete("/sessions/:id", async (req, res) => {
    const userId = opts.userIdFromReq?.(req);
    if (userId === null) return res.status(404).end();
    const sessionId = req.params.id!;
    const result = await opts.store.deleteSession(sessionId, {
      userId: userId ?? undefined,
    });
    if (!result) return res.status(404).end();
    for (const uri of result.artifactUris) {
      try {
        await opts.storage.deleteFinalized(uri);
      } catch (err) {
        // eslint-disable-next-line no-console
        console.warn(
          `[ingest] deleteFinalized(${uri}) failed: ${(err as Error).message}`,
        );
      }
    }
    if (opts.onSessionDeleted) {
      try {
        await opts.onSessionDeleted(sessionId);
      } catch (err) {
        // eslint-disable-next-line no-console
        console.warn(
          `[ingest] onSessionDeleted(${sessionId}) hook threw: ${(err as Error).message}`,
        );
      }
    }
    opts.events.emit({
      type: "session.deleted",
      sessionId,
      userId: userId ?? null,
    });
    res.status(204).end();
  });

  router.get("/stats", async (req, res) => {
    const userId = opts.userIdFromReq?.(req);
    if (userId === null) return res.json({ sessionCount: 0, totalBytes: 0, perDay: {} });
    res.json(await opts.store.stats({ userId: userId ?? undefined }));
  });

  router.get("/events", (req: Request, res: Response) => {
    const userId = opts.userIdFromReq?.(req);
    // Unauthenticated stream still gets the handshake so EventSource
    // doesn't enter its retry loop hammering us, but it receives only
    // heartbeats — no payloads at all.
    const muted = userId === null;
    // SSE handshake.
    res.status(200);
    res.setHeader("Content-Type", "text/event-stream");
    res.setHeader("Cache-Control", "no-cache, no-transform");
    res.setHeader("Connection", "keep-alive");
    res.flushHeaders?.();
    // Tell the EventSource client to back off to 15s reconnects on
    // disconnect (default is 3s, which would thunder-herd the server
    // on restart when every open dashboard tab reconnects at once).
    res.write("retry: 15000\n\n");
    // Heartbeat every 25 s to keep proxies from idling out the socket.
    const heartbeat = setInterval(() => res.write(": ping\n\n"), 25_000);
    const unsubscribe = muted
      ? () => {}
      : opts.events.subscribe(async (event) => {
          // Per-event user-scope filter: only deliver this row to the
          // subscriber if the underlying session belongs to them. We
          // look the session up against the store with the same userId
          // filter; a miss means "not ours, drop".
          if (userId) {
            // session.deleted is special: the row is gone by the time
            // this fires, so we can't getSession-check ownership. The
            // event itself carries the userId recorded at delete-time;
            // a mismatch means "another user's deletion", drop.
            if (event.type === "session.deleted") {
              if (event.userId !== userId) return;
            } else {
              const sid =
                event.type === "session.updated"
                  ? event.session.id
                  : event.type === "session.expired"
                  ? event.sessionId
                  : event.type === "resource.finalized"
                  ? event.sessionId
                  : null;
              if (sid) {
                const s = await opts.store.getSession(sid, { userId });
                if (!s) return;
              }
              // resource.created / resource.progress carry no sessionId
              // visible to other users — they're scoped by upload token
              // upstream, so it's fine to forward as-is to the owner.
            }
          }
          res.write(`event: ${event.type}\n`);
          res.write(`data: ${JSON.stringify(event)}\n\n`);
        });
    req.on("close", () => {
      clearInterval(heartbeat);
      unsubscribe();
    });
  });

  return router;
}

// --- helpers --------------------------------------------------------------

function parseIntParam(raw: unknown, fallback: number): number {
  if (typeof raw !== "string") return fallback;
  const n = Number.parseInt(raw, 10);
  return Number.isFinite(n) ? n : fallback;
}

function safeFilename(name: string): string {
  // Restrict to a conservative ASCII subset; the browser does its own
  // sanitization on Content-Disposition but we still want to avoid
  // smuggling newlines / quotes through this header.
  return (name || "artifact").replace(/[^A-Za-z0-9_.\-]/g, "_").slice(0, 240);
}

function contentTypeFor(kind: string, filename: string): string {
  const ext = filename.includes(".") ? filename.split(".").pop()!.toLowerCase() : "";
  if (ext === "json" || kind === "manifest") return "application/json";
  if (ext === "mp4" || kind === "media" || kind === "preview") return "video/mp4";
  // Rerun web-viewer dispatches purely on the URL's `.rrd` suffix —
  // it never reads Content-Type. `application/vnd.rerun.rrd` would be
  // the "spec-correct" MIME but isn't registered with IANA, and some
  // strict corporate proxies bounce unknown vendor MIMEs. Plain
  // octet-stream is safer and doesn't change viewer behavior.
  if (ext === "rrd" || kind === "rrd") return "application/octet-stream";
  if (ext === "tar") return "application/x-tar";
  if (ext === "zip") return "application/zip";
  return "application/octet-stream";
}

// Anything we expect a browser to render in place. Everything else is
// treated as a download. We key off both `kind` (set by the producer)
// and the file extension so adding new derived artifacts only needs
// updates here.
function isInlineKind(kind: string, filename: string): boolean {
  if (kind === "media" || kind === "preview" || kind === "rrd") return true;
  const ext = filename.includes(".") ? filename.split(".").pop()!.toLowerCase() : "";
  return ext === "mp4" || ext === "rrd";
}

/**
 * Parse a single-range `Range: bytes=start-end` header. We deliberately
 * do not support multipart byte ranges — `<video>` and Rerun's loader
 * only ever issue single ranges, and 2-byte tail probes for
 * `bytes=-N` are normalized into `[bytes - N, bytes - 1]`.
 *
 * Returns:
 *   - `{ start, end }`   when the header parsed and is satisfiable
 *   - `"invalid"`        when the header is malformed or out of range
 *   - `null`             when the header isn't a `bytes=…` range at all
 */
function parseRange(
  header: string,
  totalBytes: number,
): { start: number; end: number } | "invalid" | null {
  const match = /^bytes=(\d*)-(\d*)$/.exec(header.trim());
  if (!match) return null;
  const rawStart = match[1] ?? "";
  const rawEnd = match[2] ?? "";
  if (rawStart === "" && rawEnd === "") return "invalid";

  let start: number;
  let end: number;
  if (rawStart === "") {
    // Suffix form: last N bytes.
    const suffix = Number.parseInt(rawEnd, 10);
    if (!Number.isFinite(suffix) || suffix <= 0) return "invalid";
    start = Math.max(0, totalBytes - suffix);
    end = totalBytes - 1;
  } else {
    start = Number.parseInt(rawStart, 10);
    if (!Number.isFinite(start) || start < 0) return "invalid";
    if (rawEnd === "") {
      end = totalBytes - 1;
    } else {
      end = Number.parseInt(rawEnd, 10);
      if (!Number.isFinite(end) || end < start) return "invalid";
      // Cap to file size — RFC 7233 §4.1 says servers may do this.
      if (end >= totalBytes) end = totalBytes - 1;
    }
  }
  if (start >= totalBytes) return "invalid";
  return { start, end };
}
