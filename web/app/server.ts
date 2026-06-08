/**
 * Custom Express + Next.js server.
 *
 * Why custom: the TUS upload protocol (PATCH with a streaming body,
 * HEAD for resume, OPTIONS for capabilities) doesn't fit cleanly into
 * Next.js Route Handlers — they expect a single Request/Response per
 * call and don't expose the underlying req pipe we need to stream a
 * 10 GB MP4 chunk straight into storage.
 *
 * Routing model:
 *
 *   POST/PATCH/HEAD /api/ingest         ← per-user bearer token (headset)
 *   GET             /api/ingest/ack     ← QR handshake (unauthenticated;
 *                                          carries its own HMAC signature)
 *   GET             /api/ingest-read/*  ← browser cookie auth
 *   /api/reviews/*                       ← browser cookie auth
 *   /login, /api/auth/callback, /logout ← auth flow
 *   everything else                      ← Next.js (cookie auth except
 *                                          /login itself)
 */

// Set the process title BEFORE any other code runs so `ps`, `pgrep`,
// and pkill-by-title see a name distinct from conductor's sibling
// `tsx server.ts` process on the same box. (See web/deploy/README.md.)
process.title = "operator-web";

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

import {
  authRoutes,
  browserAuthMiddleware,
  describeAuth,
} from "./lib/auth/index.js";
import { runAsSystem, runAsUser } from "./lib/auth-context.js";
import { verifyConnectTicket } from "./lib/connect-ticket.js";
import { ingest } from "./lib/ingest.js";
import { deleteReview, reviewsRouter } from "./lib/reviews.js";
import { getUserById, getUserByUploadToken } from "./lib/users.js";
import { runPostIngestWorkers } from "./lib/workers/index.js";

const PORT = Number(process.env.PORT ?? 3000);
const dev = process.env.NODE_ENV !== "production";

async function main() {
  const nextApp = next({ dev, hostname: "0.0.0.0", port: PORT });
  await nextApp.prepare();
  const handleNext = nextApp.getRequestHandler();

  const app = express();
  app.disable("x-powered-by");

  // --- auth flow (no auth required to hit these) ------------------------- //
  app.use(authRoutes());

  // --- /api/ingest/ack — QR handshake ------------------------------------ //
  // Verifies the short-lived HMAC ticket, looks up the user named by the
  // QR, and hands the headset their permanent upload token. No browser
  // cookie required — the signature replaces auth here.
  app.get("/api/ingest/ack", (req, res) => {
    const uploadUrl = singleQuery(req.query.u);
    const userId = singleQuery(req.query.uid);
    const expiresAt = Number(singleQuery(req.query.exp));
    const signature = singleQuery(req.query.sig);
    const verified = verifyConnectTicket(uploadUrl, userId, expiresAt, signature);
    if (!verified.ok) {
      const status = verified.error === "expired" ? 410 : 400;
      return res.status(status).json({ ok: false, error: verified.error ?? "invalid" });
    }
    const user = getUserById(userId);
    if (!user) return res.status(404).json({ ok: false, error: "user_not_found" });
    return res.json({
      ok: true,
      uploadUrl,
      uploadToken: user.uploadToken,
      expiresAt,
      serverTime: Date.now(),
      tusVersion: TUS_VERSION,
    });
  });

  // --- /api/ingest — TUS upload endpoint --------------------------------- //
  // Each request needs `Authorization: Bearer <upload_token>` matching
  // exactly one users row. We wrap the TUS middleware in an outer
  // middleware that:
  //   (1) looks the user up,
  //   (2) rejects with 401 if no match,
  //   (3) binds the userId to AsyncLocalStorage so SqliteStore's
  //       createResource / first upsertSessionArtifact can attach it
  //       to the new rows.
  //
  // We pass `auth: () => true` to the TUS middleware itself — we've
  // already verified upstream; doing it twice would just duplicate the
  // DB hit.
  const tusMiddleware = createIngestMiddleware({
    store: ingest.store,
    storage: ingest.storage,
    events: ingest.events,
    acceptedSchemas: [SCHEMA_VERSION],
    maxUploadSizeBytes: Number(process.env.MAX_BYTES ?? 100 * 1024 ** 3),
    orphanTimeoutMs: process.env.ORPHAN_TIMEOUT_MS
      ? Number(process.env.ORPHAN_TIMEOUT_MS)
      : undefined,
    auth: () => true,
    onSession: async (session) => {
      // eslint-disable-next-line no-console
      console.log(
        `[ingest] session ${session.id} complete · ${session.totalBytes} bytes`,
      );
      // Workers fire OUTSIDE any HTTP request, so they don't have a
      // user context. The session row already has user_id from the
      // first artifact insert; UPDATEs by the workers preserve it.
      // We run the workers as system so any defensive listSessions /
      // getSession calls inside future workers don't get scoped out.
      runAsSystem(async () => {
        try {
          await runPostIngestWorkers(session);
        } catch (err) {
          // eslint-disable-next-line no-console
          console.error(`[workers] orchestrator threw for ${session.id}:`, err);
        }
      });
    },
  });

  app.use("/api/ingest", (req, res, next) => {
    // TUS OPTIONS is a *discovery* endpoint — clients use it to read
    // back capability headers (Tus-Version, Tus-Extension, Tus-Max-Size)
    // BEFORE they have a token. Quoting the TUS spec §3:
    //   "An OPTIONS request MAY be used to gather information about the
    //    Server's current configuration. […] The Server MUST respond to
    //    OPTIONS requests with a 204 No Content or 200 OK status."
    // Auth-gating OPTIONS breaks two real flows:
    //   1. The XR client's panel-open health probe (`OPTIONS /api/ingest`
    //      with no token yet) goes amber-401 → user can't tell whether
    //      the endpoint is alive.
    //   2. CORS preflights from a browser-hosted TUS client never see the
    //      Tus-Version reply and abort the actual PATCH/POST.
    // We let OPTIONS through to the TUS middleware (it answers with the
    // capability headers and a 204) and keep Bearer-token gating on the
    // request methods that actually move bytes (POST/PATCH/HEAD/DELETE).
    if (req.method === "OPTIONS") {
      return tusMiddleware(req, res, next);
    }
    const header = req.header("Authorization") ?? "";
    const token = header.startsWith("Bearer ") ? header.slice(7) : "";
    const user = getUserByUploadToken(token);
    if (!user) {
      res.status(401).setHeader("WWW-Authenticate", "Bearer").end();
      return;
    }
    runAsUser(user.id, () => tusMiddleware(req, res, next));
  });

  // --- /api/ingest-read — browser cookie auth + per-user scope ----------- //
  // We pull the user from the iron-session cookie that
  // `browserAuthMiddleware` validates and stashes on `req.user`. The
  // read API uses that to filter sessions/getSession/stats/SSE.
  app.use(
    "/api/ingest-read",
    browserAuthMiddleware(),
    createReadApi({
      ...ingest,
      userIdFromReq: (req) => req.user?.id ?? null,
      // The reviews table lives in this app, not in ego-ingest. After
      // ego-ingest finishes wiping the session it calls back here so
      // we can drop the matching review row — otherwise the home
      // dashboard would keep showing a "reviewed/flagged" badge
      // pointing at a session that no longer exists.
      onSessionDeleted: (sessionId) => {
        try {
          deleteReview(sessionId);
        } catch (err) {
          // eslint-disable-next-line no-console
          console.warn(
            `[server] deleteReview(${sessionId}) failed: ${(err as Error).message}`,
          );
        }
      },
    }),
  );

  // --- /api/reviews — per-session review state --------------------------- //
  app.use("/api/reviews", browserAuthMiddleware(), reviewsRouter);

  // --- Next.js pages: cookie auth except the public ones ----------------- //
  // /login is the unauthenticated entry point. Everything else is gated.
  // Top-level static assets under `public/` (logo, favicon, robots.txt, …)
  // need to load on the login page itself, so they're allowlisted by
  // extension here — the rule matches `/foo.ext` but never `/foo/bar.ext`,
  // so nothing inside Next's app routes can leak through.
  const PUBLIC_STATIC_RE = /^\/[^/]+\.(?:png|jpg|jpeg|svg|webp|gif|ico|txt|webmanifest)$/i;
  app.all("*", (req, res) => {
    const p = req.path;
    if (
      p === "/login" ||
      p.startsWith("/_next/") ||
      p === "/favicon.ico" ||
      p === "/api/auth/callback" ||
      PUBLIC_STATIC_RE.test(p)
    ) {
      return handleNext(req, res);
    }
    browserAuthMiddleware()(req, res, () => handleNext(req, res));
  });

  createServer(app).listen(PORT, () => {
    const auth = describeAuth();
    // eslint-disable-next-line no-console
    console.log(`[ego-app] http://localhost:${PORT}/`);
    console.log(`[ego-app] ingest at  http://localhost:${PORT}/api/ingest`);
    console.log(`[ego-app] files at   ${path.resolve(ingest.dataRoot)}`);
    console.log(
      `[ego-app] auth       ${auth.mode === "bypass" ? "BYPASS (dev)" : `Conductor SSO ${auth.conductor}`}`,
    );
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
