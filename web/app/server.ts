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

import {
  createServer as createHttpServer,
  request as createHttpRequest,
} from "node:http";
import { createServer as createNetServer } from "node:net";
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
import {
  collectorAgentRouter,
  collectorBrowserRouter,
} from "./lib/collector-agents.js";
import { ingest } from "./lib/ingest.js";
import { deleteReview, reviewsRouter } from "./lib/reviews.js";
import { getUserById, getUserByUploadToken } from "./lib/users.js";
import { runPostIngestWorkers } from "./lib/workers/index.js";

const DEFAULT_PORT = Number(process.env.PORT ?? 3000);
const PORT_EXPLICITLY_SET = Boolean(process.env.PORT);
const dev = process.env.NODE_ENV !== "production";
const MEMWORLD_GATEWAY_HOST = process.env.MEMWORLD_GATEWAY_HOST ?? "127.0.0.1";
const MEMWORLD_WEBSOCKET_PORT = Number(
  process.env.MEMWORLD_GATEWAY_PORT ?? 63920,
);
const MEMWORLD_DASHBOARD_PORT = Number(
  process.env.MEMWORLD_DASHBOARD_PORT ?? 63921,
);

const MEMWORLD_HTTP_ROUTES = new Map<string, string>([
  ["/api/memworld/status", "/status.json"],
  ["/api/memworld/model.jpg", "/model.jpg"],
  ["/api/memworld/skeleton.jpg", "/skeleton.jpg"],
]);

async function main() {
  const port = await resolveListenPort(DEFAULT_PORT);
  process.env.PORT = String(port);

  const nextApp = next({ dev, hostname: "0.0.0.0", port });
  await nextApp.prepare();
  const handleNext = nextApp.getRequestHandler();
  const handleNextUpgrade = nextApp.getUpgradeHandler();

  const app = express();
  app.disable("x-powered-by");

  // Public, intentionally minimal liveness endpoint for the local systemd
  // watchdog. Reaching this handler proves that the Node event loop and
  // Express router are responsive without exposing collector state.
  app.get("/healthz", (_req, res) => {
    res.setHeader("Cache-Control", "no-store");
    res.status(200).json({ ok: true, service: "operator-station" });
  });

  // --- auth flow (no auth required to hit these) ------------------------- //
  app.use(authRoutes());

  // The Station deployment exposes a single operator-facing workspace.
  // Keep legacy data-review pages available in source, but remove their web
  // entry points so old bookmarks land on the collector workflow.
  app.get(
    ["/connect", "/memworld", "/sessions", "/sessions/:id"],
    browserAuthMiddleware(),
    (_req, res) => res.redirect(302, "/collectors"),
  );

  // --- collector workstation agents ------------------------------------- //
  // Native agents authenticate with their own bearer token. Bootstrap is
  // intentionally public but produces only a short-lived enrollment that a
  // signed-in browser user must approve before any workstation can run jobs.
  app.use("/api/collector-agent", collectorAgentRouter);

  // --- /api/memworld/* — same-origin view of the live gateway ----------- //
  // The model worker protocol stays behind the Python gateway. The web app
  // only forwards the gateway's read-only dashboard resources so the new
  // dashboard can render live output without exposing a second web origin.
  for (const [route, upstreamPath] of MEMWORLD_HTTP_ROUTES) {
    app.get(route, browserAuthMiddleware(), (req, res) => {
      const upstream = createHttpRequest(
        {
          hostname: MEMWORLD_GATEWAY_HOST,
          port: MEMWORLD_DASHBOARD_PORT,
          method: "GET",
          path: upstreamPath,
          headers: {
            accept: req.header("accept") ?? "*/*",
          },
        },
        (upstreamResponse) => {
          res.status(upstreamResponse.statusCode ?? 502);
          for (const name of ["content-type", "content-length", "cache-control"]) {
            const value = upstreamResponse.headers[name];
            if (value !== undefined) res.setHeader(name, value);
          }
          upstreamResponse.pipe(res);
        },
      );
      upstream.setTimeout(5_000, () => {
        upstream.destroy(new Error("MemWorld dashboard timeout"));
      });
      upstream.on("error", (error) => {
        if (!res.headersSent) {
          res.status(502).json({
            ok: false,
            error: "memworld_gateway_unavailable",
            detail: error.message,
          });
        } else {
          res.destroy(error);
        }
      });
      upstream.end();
    });
  }

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

  // --- /api/collectors — browser control plane for workstation agents ---- //
  app.use(
    "/api/collectors",
    browserAuthMiddleware(),
    collectorBrowserRouter,
  );

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

  const httpServer = createHttpServer(app);

  // Keep the existing operator.memworld.v1 WebSocket unchanged. This is a
  // byte-for-byte upgrade proxy that only gives it the web app's public
  // origin; authentication remains the MemWorld hello token downstream.
  httpServer.on("upgrade", (req, clientSocket, clientHead) => {
    const pathname = new URL(
      req.url ?? "/",
      "http://operator.local",
    ).pathname;
    if (pathname !== "/memworld") {
      void handleNextUpgrade(req, clientSocket, clientHead);
      return;
    }

    const proxyRequest = createHttpRequest({
      hostname: MEMWORLD_GATEWAY_HOST,
      port: MEMWORLD_WEBSOCKET_PORT,
      method: req.method ?? "GET",
      path: req.url ?? "/memworld",
      headers: req.headers,
    });

    proxyRequest.on("upgrade", (upstreamResponse, upstreamSocket, upstreamHead) => {
      const statusCode = upstreamResponse.statusCode ?? 101;
      const statusMessage = upstreamResponse.statusMessage ?? "Switching Protocols";
      clientSocket.write(`HTTP/1.1 ${statusCode} ${statusMessage}\r\n`);
      for (let index = 0; index < upstreamResponse.rawHeaders.length; index += 2) {
        clientSocket.write(
          `${upstreamResponse.rawHeaders[index]}: ${upstreamResponse.rawHeaders[index + 1]}\r\n`,
        );
      }
      clientSocket.write("\r\n");
      if (upstreamHead.length > 0) clientSocket.write(upstreamHead);
      if (clientHead.length > 0) upstreamSocket.write(clientHead);
      upstreamSocket.pipe(clientSocket);
      clientSocket.pipe(upstreamSocket);
    });
    proxyRequest.on("response", (upstreamResponse) => {
      upstreamResponse.resume();
      clientSocket.destroy(
        new Error(`MemWorld upgrade rejected: ${upstreamResponse.statusCode}`),
      );
    });
    proxyRequest.on("error", (error) => clientSocket.destroy(error));
    proxyRequest.end();
  });

  httpServer.listen(port, () => {
    const auth = describeAuth();
    // eslint-disable-next-line no-console
    console.log(`[ego-app] http://localhost:${port}/`);
    console.log(`[ego-app] ingest at  http://localhost:${port}/api/ingest`);
    console.log(`[ego-app] files at   ${path.resolve(ingest.dataRoot)}`);
    console.log(
      `[ego-app] auth       ${auth.mode === "local" ? "collector ID + PIN" : `Conductor SSO ${auth.conductor}`}`,
    );
  });
}

async function resolveListenPort(port: number): Promise<number> {
  if (!Number.isInteger(port) || port < 0 || port > 65535) {
    throw new Error(`Invalid PORT: ${process.env.PORT}`);
  }
  if (!dev || PORT_EXPLICITLY_SET) return port;

  for (let candidate = port; candidate < port + 20; candidate += 1) {
    if (await canListen(candidate)) {
      if (candidate !== port) {
        // eslint-disable-next-line no-console
        console.warn(
          `[ego-app] port ${port} is in use; using ${candidate} instead`,
        );
      }
      return candidate;
    }
  }

  throw new Error(`No available dev port found from ${port} to ${port + 19}.`);
}

function canListen(port: number): Promise<boolean> {
  return new Promise((resolve) => {
    const probe = createNetServer();
    probe.unref();
    probe.once("error", () => resolve(false));
    probe.once("listening", () => {
      probe.close(() => resolve(true));
    });
    probe.listen(port);
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
