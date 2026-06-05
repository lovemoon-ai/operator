/**
 * Custom Express + Next.js server.
 *
 * Why custom: the TUS upload protocol (PATCH with a streaming body,
 * HEAD for resume, OPTIONS for capabilities) doesn't fit cleanly into
 * Next.js Route Handlers — Route Handlers expect a single Request/
 * Response per call and don't expose the underlying req pipe we need
 * to stream a 10 GB MP4 chunk straight into storage.
 *
 * Architecture:
 *
 *   Browser → Next.js pages              ── handled by next() ──┐
 *   XR client → POST/PATCH /api/ingest   ── ego-ingest mw    ──┤
 *   Browser → GET /api/ingest/api/...    ── ego-ingest mw    ──┤   one Express
 *   Browser → review actions on /api/reviews ── our routes   ──┤   process
 *                                                              ┘
 *
 * The shared store / storage / events bus is created once in
 * `lib/ingest.ts` and imported by both the ingest middleware (here)
 * and by the React pages (server components fetch directly).
 */

import { createServer } from "node:http";
import path from "node:path";

import express from "express";
import next from "next";

import {
  createIngestMiddleware,
  createReadApi,
  SCHEMA_VERSION,
  TUS_VERSION,
} from "@love-moon/ego-ingest";

import { verifyConnectTicket } from "./lib/connect-ticket.js";
import { ingest } from "./lib/ingest.js";
import { reviewsRouter } from "./lib/reviews.js";
import { runPostIngestWorkers } from "./lib/workers/index.js";

const PORT = Number(process.env.PORT ?? 3000);
const dev = process.env.NODE_ENV !== "production";
const BEARER_TOKEN = process.env.INGEST_TOKEN ?? null;

async function main() {
  const nextApp = next({ dev, hostname: "0.0.0.0", port: PORT });
  await nextApp.prepare();
  const handleNext = nextApp.getRequestHandler();

  const app = express();
  app.disable("x-powered-by");

  // --- /api/ingest/ack — QR handshake ------------------------------------ //
  // The QR code on /connect points here, not directly at the TUS endpoint.
  // It is signed and expires after 5 minutes. A successful ack returns the
  // stable upload URL plus the optional bearer token so the headset no longer
  // needs a visible token input field.
  app.get("/api/ingest/ack", (req, res) => {
    const uploadUrl = singleQuery(req.query.u);
    const expiresAt = Number(singleQuery(req.query.exp));
    const signature = singleQuery(req.query.sig);
    const verified = verifyConnectTicket(uploadUrl, expiresAt, signature);
    if (!verified.ok) {
      const status = verified.error === "expired" ? 410 : 400;
      return res.status(status).json({ ok: false, error: verified.error ?? "invalid" });
    }
    return res.json({
      ok: true,
      uploadUrl,
      uploadToken: BEARER_TOKEN ?? "",
      expiresAt,
      serverTime: Date.now(),
      tusVersion: TUS_VERSION,
    });
  });

  // --- /api/ingest — TUS upload endpoint --------------------------------- //
  // This is where the XR client (xr/scripts/ego_uploader.gd) sends data.
  // Mounted under the `/api` namespace so it sits behind whatever reverse
  // proxy / auth layer the rest of the app uses.
  app.use(
    "/api/ingest",
    createIngestMiddleware({
      store: ingest.store,
      storage: ingest.storage,
      events: ingest.events,
      auth: BEARER_TOKEN
        ? (req) => req.header("Authorization") === `Bearer ${BEARER_TOKEN}`
        : undefined,
      acceptedSchemas: [SCHEMA_VERSION],
      maxUploadSizeBytes: Number(process.env.MAX_BYTES ?? 100 * 1024 ** 3),
      // Manifest-only sessions get marked `expired` after this long.
      // Default 15min; the env var accepts ms for tests
      // (`ORPHAN_TIMEOUT_MS=5000` to validate the watchdog without
      // waiting). Set to 0 to disable.
      orphanTimeoutMs: process.env.ORPHAN_TIMEOUT_MS
        ? Number(process.env.ORPHAN_TIMEOUT_MS)
        : undefined,
      onSession: async (session) => {
        // eslint-disable-next-line no-console
        console.log(
          `[ingest] session ${session.id} complete · ${session.totalBytes} bytes`,
        );
        // Kick the post-ingest pipeline: preview.mp4 (browser-playable
        // RGB) first, then session.rrd (Rerun web viewer). Both derive
        // new artifacts on disk and register them with the same store
        // so the UI picks them up on its next render. Errors are
        // logged but never bubble up — the raw upload is still safe
        // on disk and re-runnable manually.
        try {
          await runPostIngestWorkers(session);
        } catch (err) {
          // eslint-disable-next-line no-console
          console.error(`[workers] orchestrator threw for ${session.id}:`, err);
        }
      },
    }),
  );

  // --- /api/ingest-read — read-only API used by the UI ------------------- //
  // Mounted under a SEPARATE path from /api/ingest so the TUS prefix
  // routing stays simple. The pages and React components consume this.
  app.use("/api/ingest-read", createReadApi(ingest));

  // --- /api/reviews — per-session review state (this app's own data) ----- //
  app.use("/api/reviews", reviewsRouter);

  // --- everything else → Next.js ----------------------------------------- //
  app.all("*", (req, res) => handleNext(req, res));

  createServer(app).listen(PORT, () => {
    // eslint-disable-next-line no-console
    console.log(`[ego-app] http://localhost:${PORT}/`);
    console.log(`[ego-app] ingest at  http://localhost:${PORT}/api/ingest`);
    console.log(`[ego-app] files at   ${path.resolve(ingest.dataRoot)}`);
    console.log(`[ego-app] auth       ${BEARER_TOKEN ? "ON (Bearer)" : "OFF"}`);
  });
}

function singleQuery(value: unknown): string {
  if (Array.isArray(value)) return String(value[0] ?? "");
  return typeof value === "string" ? value : "";
}

main().catch((err) => {
  // eslint-disable-next-line no-console
  console.error(err);
  process.exit(1);
});
