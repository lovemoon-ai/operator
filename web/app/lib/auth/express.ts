/**
 * Express middleware + auth routes used by server.ts.
 *
 *   POST /auth/local             → collector ID + PIN login / first-use create
 *   GET  /auth/start             → return to the local login form
 *   GET|POST /auth/logout        → clear cookie
 *
 *   browserAuthMiddleware()      → for every browser-facing route, looks
 *                                  up the user from the iron-session
 *                                  cookie and binds an AsyncLocalStorage
 *                                  context so the SqliteStore + reviews
 *                                  router can pick it up. Unauthenticated
 *                                  requests get a 302 to /login (HTML
 *                                  navigations) or 401 (XHR / fetch).
 */
import type { Request, RequestHandler, Response } from "express";
import express from "express";

import { runAsUser } from "../auth-context.js";
import {
  authenticateOrCreateCollector,
  CollectorAuthError,
  getUserById,
  type User,
} from "../users.js";
import { verifyArtifactToken } from "./artifact-token.js";
import { loadAuthConfig, type AuthConfig } from "./config.js";
import { readSession } from "./session.js";

declare module "express-serve-static-core" {
  interface Request {
    /** Set by `browserAuthMiddleware` after successful cookie auth. */
    user?: User;
  }
}

let cachedConfig: AuthConfig | null = null;
const loginFailures = new Map<string, { count: number; blockedUntil: number }>();
const LOGIN_FAILURE_LIMIT = 5;
const LOGIN_BLOCK_MS = 15 * 60 * 1000;
function config(): AuthConfig {
  cachedConfig ??= loadAuthConfig();
  return cachedConfig;
}

// --- /auth/start ----------------------------------------------------------

/**
 * Return to the ID + PIN form while preserving a safe in-app destination.
 */
function loginHandler(): RequestHandler {
  return async (req: Request, res: Response) => {
    const returnTo =
      typeof req.query.returnTo === "string" ? req.query.returnTo : "/";
    return res.redirect(`/login?returnTo=${encodeURIComponent(safeReturnTo(returnTo))}`);
  };
}

function localLoginHandler(): RequestHandler {
  return async (req: Request, res: Response) => {
    const cfg = config();
    const collectorId = typeof req.body?.collectorId === "string"
      ? req.body.collectorId.trim()
      : "";
    const pin = typeof req.body?.pin === "string" ? req.body.pin : "";
    const returnTo = safeReturnTo(
      typeof req.body?.returnTo === "string" ? req.body.returnTo : "/collectors",
    );
    const failureKey = `${req.ip}:${collectorId.toLowerCase()}`;
    const previous = loginFailures.get(failureKey);
    if (previous && previous.blockedUntil > Date.now()) {
      return redirectLoginError(res, "locked", collectorId, returnTo);
    }

    try {
      const { user } = authenticateOrCreateCollector(collectorId, pin);
      loginFailures.delete(failureKey);
      const session = await readSession(req, res, cfg.sessionSecret);
      session.userId = user.id;
      await session.save();
      return res.redirect(returnTo);
    } catch (error) {
      if (!(error instanceof CollectorAuthError)) {
        // eslint-disable-next-line no-console
        console.error("[auth] local login failed:", error);
        return res.status(500).type("text/plain").send("login service unavailable");
      }
      const code = error.code;
      if (code === "invalid_credentials") {
        const count = (previous?.count ?? 0) + 1;
        loginFailures.set(failureKey, {
          count,
          blockedUntil: count >= LOGIN_FAILURE_LIMIT ? Date.now() + LOGIN_BLOCK_MS : 0,
        });
      }
      return redirectLoginError(res, code, collectorId, returnTo);
    }
  };
}

// --- /logout --------------------------------------------------------------

function logoutHandler(): RequestHandler {
  return async (req: Request, res: Response) => {
    const cfg = config();
    const session = await readSession(req, res, cfg.sessionSecret);
    session.destroy();
    res.redirect("/login");
  };
}

// --- Browser auth gate ----------------------------------------------------

/**
 * Cookie-based auth for browser-facing routes (pages + JSON APIs).
 *
 * On success, populates `req.user` and runs the rest of the chain inside
 * `runAsUser(userId, …)` so the SqliteStore picks up the right user_id
 * for any writes.
 *
 * On failure: HTML navigations get a 302 to /login?returnTo=<path>,
 * everything else gets 401 JSON.
 */
export function browserAuthMiddleware(): RequestHandler {
  return async (req, res, next) => {
    const cfg = config();
    const session = await readSession(req, res, cfg.sessionSecret);
    if (session.userId) {
      const user = getUserById(session.userId);
      if (user) {
        // AUTH_BYPASS historically stamped every browser as Dev User. Reject
        // those shared sessions after local collector login is enabled so no
        // browser can continue seeing the legacy shared workspace.
        if (!user.collectorId) {
          session.destroy();
          return failAuth(req, res);
        }
        req.user = user;
        return runAsUser(user.id, () => next());
      }
      session.destroy();
    }
    // Fallback: signed token in query for GETs on the rrd artifact —
    // the Rerun WASM viewer's internal reqwest fetch can't carry the
    // browser cookie, so we sign a short-lived HMAC into the URL the
    // page hands to the viewer. Scoped to the rrd path to keep the
    // bypass tightly narrow; everything else still requires cookie.
    if (req.method === "GET" && /\/artifacts\/rrd\//.test(req.path)) {
      // The token was signed against the absolute request path. Inside
      // `app.use("/api/ingest-read", mw)` Express strips the mount, so
      // `req.path` is `/sessions/.../rrd/...` — we need the full path
      // including the mount, which we recover from `originalUrl`.
      const signedPath = ((req.originalUrl || req.url || req.path).split("?")[0]) || req.path;
      const tokUser = verifyArtifactToken(
        cfg.sessionSecret,
        signedPath,
        req.query as Record<string, unknown>,
      );
      if (tokUser) {
        const user = getUserById(tokUser);
        if (user) {
          req.user = user;
          return runAsUser(user.id, () => next());
        }
      }
    }
    return failAuth(req, res);
  };
}

function failAuth(req: Request, res: Response): void {
  // Use originalUrl, not req.path — inside an `app.use("/api/...", mw)`
  // mount, req.path has the mount prefix stripped (`/sessions` instead
  // of `/api/ingest-read/sessions`), so checking req.path.startsWith
  // "/api/" misclassifies JSON endpoints as HTML navigations and
  // 302s them into the login page (which EventSource / fetch can't
  // follow).
  const url = req.originalUrl || req.path || "/";
  const wantsJson =
    req.xhr ||
    url.startsWith("/api/") ||
    (req.headers.accept ?? "").includes("application/json");
  if (wantsJson) {
    res.status(401).json({ error: "auth required" });
    return;
  }
  const returnTo = encodeURIComponent(url);
  res.redirect(`/login?returnTo=${returnTo}`);
}

// --- Router + helpers -----------------------------------------------------

export function authRoutes(): express.Router {
  const r = express.Router();
  r.use(express.urlencoded({ extended: false, limit: "4kb" }));
  // `/auth/start` kicks off the flow so the static /login page can show
  // marketing copy + a "Continue" button without clashing with this
  // redirect handler.
  r.get("/auth/start", loginHandler());
  r.post("/auth/local", localLoginHandler());
  r.post("/auth/logout", logoutHandler());
  r.get("/auth/logout", logoutHandler());
  return r;
}

/** Surface the loaded config so server.ts can log status at boot. */
export function describeAuth(): { mode: "local"; baseUrl: string } {
  const cfg = config();
  return { mode: "local", baseUrl: cfg.baseUrl };
}

function redirectLoginError(
  res: Response,
  code: string,
  collectorId: string,
  returnTo: string,
): void {
  const query = new URLSearchParams({ error: code, returnTo });
  if (collectorId) query.set("collectorId", collectorId.slice(0, 32));
  res.redirect(303, `/login?${query.toString()}`);
}

/**
 * Only allow returnTo values that look like in-app paths, so a
 * crafted `/login?returnTo=https://evil.com` can't open-redirect
 * after the cookie's stamped.
 */
function safeReturnTo(raw: string): string {
  if (!raw.startsWith("/") || raw.startsWith("//")) return "/";
  return raw;
}
