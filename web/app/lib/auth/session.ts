/**
 * iron-session wrapper.
 *
 * Cookie name `egosess`. Stores just the local `users.id` (UUID) — every
 * other field comes from a fresh DB read. That keeps the cookie small,
 * lets a forced rotation of a single field (token reset, profile rename)
 * take effect on the next request without re-issuing cookies, and means
 * a stolen cookie expires the moment the user row is deleted.
 *
 * 7-day TTL with refresh-on-each-request via `cookie.maxAge`. We don't
 * keep an explicit "issuedAt" — the cookie is sealed and tamper-proof,
 * so we trust whatever is inside until iron-session's own seal-TTL
 * check rejects it.
 */
import type { Request, Response } from "express";
import { getIronSession, type SessionOptions } from "iron-session";

const SESSION_COOKIE = "egosess";
const SESSION_TTL_SECONDS = 7 * 24 * 60 * 60;

export interface SessionData {
  userId?: string;
}

export function sessionOptions(secret: string): SessionOptions {
  return {
    password: secret,
    cookieName: SESSION_COOKIE,
    ttl: SESSION_TTL_SECONDS,
    cookieOptions: {
      httpOnly: true,
      sameSite: "lax",
      // Auto-enable Secure when the parent process knows it's behind
      // HTTPS. Local dev (http://localhost) flips this off so the
      // cookie still attaches.
      secure: process.env.NODE_ENV === "production",
      maxAge: SESSION_TTL_SECONDS,
      path: "/",
    },
  };
}

export async function readSession(
  req: Request,
  res: Response,
  secret: string,
) {
  return getIronSession<SessionData>(req, res, sessionOptions(secret));
}
