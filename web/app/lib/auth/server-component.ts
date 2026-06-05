/**
 * Server-component-friendly user lookup.
 *
 * Why this exists: the Express `browserAuthMiddleware` binds an
 * AsyncLocalStorage context around `handleNext()`, but Next 15's RSC
 * render doesn't always run inside that context (it uses its own
 * scheduling internally). So reading the user via `currentUserId()`
 * is unreliable from a server component.
 *
 * Instead we decrypt the iron-session cookie ourselves via Next's
 * `cookies()` reader. Same secret, same cookie name, just a different
 * entry path. The Express middleware is still the authoritative gate
 * (it 302s unauthenticated browsers to /login before they get here),
 * so this helper just resolves the already-authenticated user.
 */
import { cookies } from "next/headers";
import { sealData, unsealData } from "iron-session";

import { getUserById, type User } from "../users.js";
import { loadAuthConfig } from "./config.js";

const COOKIE_NAME = "egosess";

interface SessionPayload {
  userId?: string;
}

export async function getServerComponentUser(): Promise<User | null> {
  // Catch every conceivable failure mode (missing env at build time, no
  // cookie, decode error, expired seal, deleted user). The caller's
  // contract is "null means render as logged-out"; throwing here would
  // either 500 a page or break Next's static prerender of the
  // /_not-found shell.
  try {
    const cfg = loadAuthConfig();
    const store = await cookies();
    const raw = store.get(COOKIE_NAME)?.value;
    if (!raw) return null;
    const data = (await unsealData<SessionPayload>(raw, {
      password: cfg.sessionSecret,
    })) as SessionPayload;
    if (!data.userId) return null;
    return getUserById(data.userId);
  } catch {
    return null;
  }
}

// Round-trip helper used by tests; not currently called from app code.
export async function sealServerSession(userId: string): Promise<string> {
  const cfg = loadAuthConfig();
  return sealData({ userId } as SessionPayload, { password: cfg.sessionSecret });
}
