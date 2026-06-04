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

  router.get("/sessions/:id/artifacts/:kind", async (req, res) => {
    const session = await opts.store.getSession(req.params.id!);
    if (!session) return res.status(404).end();
    const artifact = session.artifacts[req.params.kind!];
    if (!artifact) return res.status(404).end();
    const stream = await opts.storage.openFinalized(artifact.uri);
    if (!stream) return res.status(410).end();
    res.setHeader("Content-Length", String(artifact.bytes));
    res.setHeader("Content-Disposition", `attachment; filename="${safeFilename(artifact.filename)}"`);
    res.setHeader("Content-Type", contentTypeFor(artifact.kind, artifact.filename));
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
  if (ext === "mp4" || kind === "media") return "video/mp4";
  if (ext === "tar") return "application/x-tar";
  if (ext === "zip") return "application/zip";
  return "application/octet-stream";
}
