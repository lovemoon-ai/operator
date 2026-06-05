/**
 * Express middleware + auth routes used by server.ts.
 *
 *   GET  /login                  → start OIDC flow (or stamp dev cookie)
 *   GET  /api/auth/callback      → finish OIDC flow
 *   POST /logout                 → clear cookie
 *
 *   browserAuthMiddleware()      → for every browser-facing route, looks
 *                                  up the user from the iron-session
 *                                  cookie and binds an AsyncLocalStorage
 *                                  context so the SqliteStore + reviews
 *                                  router can pick it up. Unauthenticated
 *                                  requests get a 302 to /login (HTML
 *                                  navigations) or 401 (XHR / fetch).
 */
import type { NextFunction, Request, RequestHandler, Response } from "express";
import express from "express";

import { runAsUser } from "../auth-context.js";
import { findOrCreateUserBySub, getUserById, type User } from "../users.js";
import { seedDemoForUser } from "../seed.js";
import { loadAuthConfig, type AuthConfig } from "./config.js";
import { exchangeCode, getOidcClient, newAuthRequest } from "./oidc.js";
import { readSession } from "./session.js";

declare module "express-serve-static-core" {
  interface Request {
    /** Set by `browserAuthMiddleware` after successful cookie auth. */
    user?: User;
  }
}

let cachedConfig: AuthConfig | null = null;
function config(): AuthConfig {
  cachedConfig ??= loadAuthConfig();
  return cachedConfig;
}

// --- /login ---------------------------------------------------------------

/**
 * Bypass mode shortcut: stamp a session for the fixed dev user and
 * redirect home. In OIDC mode: capture state + verifier in the session,
 * 302 to the authorization endpoint.
 */
function loginHandler(): RequestHandler {
  return async (req: Request, res: Response) => {
    const cfg = config();
    const session = await readSession(req, res, cfg.sessionSecret);
    const returnTo =
      typeof req.query.returnTo === "string" ? req.query.returnTo : "/";

    if (cfg.bypass) {
      const user = findOrCreateUserBySub(cfg.devUser.sub, {
        email: cfg.devUser.email,
        name: cfg.devUser.name,
      });
      session.userId = user.id;
      await session.save();
      await seedDemoForUser(user).catch((err) => {
        // eslint-disable-next-line no-console
        console.error("[auth] seed failed:", err);
      });
      return res.redirect(safeReturnTo(returnTo));
    }

    const client = await getOidcClient(cfg);
    const { url, state, verifier } = newAuthRequest(cfg, client);
    session.oauthState = state;
    session.pkceVerifier = verifier;
    session.returnTo = safeReturnTo(returnTo);
    await session.save();
    res.redirect(url);
  };
}

// --- /api/auth/callback ---------------------------------------------------

function callbackHandler(): RequestHandler {
  return async (req: Request, res: Response) => {
    const cfg = config();
    if (cfg.bypass) return res.redirect("/");

    const session = await readSession(req, res, cfg.sessionSecret);
    const expectedState = session.oauthState;
    const verifier = session.pkceVerifier;
    const returnTo = session.returnTo ?? "/";
    if (!expectedState || !verifier) {
      return res.status(400).type("text/plain").send("missing oauth state");
    }
    // Single-use: clear before we attempt the exchange so a retry can't
    // reuse a captured state value.
    session.oauthState = undefined;
    session.pkceVerifier = undefined;
    session.returnTo = undefined;
    await session.save();

    try {
      const client = await getOidcClient(cfg);
      const query: Record<string, string> = {};
      for (const [k, v] of Object.entries(req.query)) {
        if (typeof v === "string") query[k] = v;
      }
      const profile = await exchangeCode(client, cfg, query, expectedState, verifier);
      const user = findOrCreateUserBySub(profile.sub, {
        email: profile.email ?? null,
        name: profile.name ?? null,
      });
      session.userId = user.id;
      await session.save();
      await seedDemoForUser(user).catch((err) => {
        // eslint-disable-next-line no-console
        console.error("[auth] seed failed:", err);
      });
      res.redirect(safeReturnTo(returnTo));
    } catch (err) {
      // eslint-disable-next-line no-console
      console.error("[auth] callback failed:", err);
      res.status(401).type("text/plain").send(`callback failed: ${(err as Error).message}`);
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
    if (!session.userId) return failAuth(req, res);
    const user = getUserById(session.userId);
    if (!user) {
      session.destroy();
      return failAuth(req, res);
    }
    req.user = user;
    runAsUser(user.id, () => next());
  };
}

function failAuth(req: Request, res: Response): void {
  const wantsJson =
    req.xhr ||
    req.path.startsWith("/api/") ||
    (req.headers.accept ?? "").includes("application/json");
  if (wantsJson) {
    res.status(401).json({ error: "auth required" });
    return;
  }
  const returnTo = encodeURIComponent(req.originalUrl || "/");
  // Surface the marketing/login page rather than redirecting straight
  // into the IdP — gives the user a chance to read what they're about
  // to authorize against.
  res.redirect(`/login?returnTo=${returnTo}`);
}

// --- Router + helpers -----------------------------------------------------

export function authRoutes(): express.Router {
  const r = express.Router();
  // `/auth/start` kicks off the flow (so the Next.js page at `/login`
  // can render the marketing copy + "Continue" button without clashing
  // with the redirect handler).
  r.get("/auth/start", loginHandler());
  r.get("/api/auth/callback", callbackHandler());
  r.post("/auth/logout", logoutHandler());
  // Also accept GET so a plain <a> link works without a form.
  r.get("/auth/logout", logoutHandler());
  return r;
}

/** Surface the loaded config so server.ts can log status at boot. */
export function describeAuth(): { mode: "bypass" | "oidc"; baseUrl: string; issuer?: string } {
  const cfg = config();
  return cfg.bypass
    ? { mode: "bypass", baseUrl: cfg.baseUrl }
    : { mode: "oidc", baseUrl: cfg.baseUrl, issuer: cfg.oidc!.issuer };
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
