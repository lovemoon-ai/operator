import type { Request, RequestHandler, Response } from "express";
import express from "express";

import type { IngestEvents } from "./events.js";
import type { StorageDriver } from "./storage/index.js";
import type { SessionStore } from "./store/index.js";

export interface ReadApiOptions {
  store: SessionStore;
  storage: StorageDriver;
  events: IngestEvents;
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
    const limit = parseIntParam(req.query.limit, 50);
    const cursor = typeof req.query.cursor === "string" ? req.query.cursor : undefined;
    const order = req.query.order === "asc" ? "asc" : "desc";
    const page = await opts.store.listSessions({ limit, cursor, order });
    res.json(page);
  });

  router.get("/sessions/:id", async (req, res) => {
    const session = await opts.store.getSession(req.params.id!);
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
    const session = await opts.store.getSession(req.params.id!);
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

  router.get("/stats", async (_req, res) => {
    res.json(await opts.store.stats());
  });

  router.get("/events", (req: Request, res: Response) => {
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
    const unsubscribe = opts.events.subscribe((event) => {
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
