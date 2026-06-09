/**
 * Auth configuration plucked from environment.
 *
 * The web tier is local-only: every install runs in bypass mode and
 * authenticates as a single fixed dev user. The previous Conductor SSO
 * branch was deleted along with the production deployment that hosted
 * it; if you ever need real multi-user auth back, re-add it here.
 *
 * Environment knobs:
 *   - AUTH_SESSION_SECRET      32+ char random string for iron-session
 *                              cookies. Falls back to a dev string
 *                              when unset.
 *   - AUTH_BASE_URL            full origin we'll receive callbacks on
 *                              (default http://localhost:<PORT>)
 *   - DEV_USER_SUB             override the fixed dev user's sub
 *                              (default "dev@localhost")
 */
export interface AuthConfig {
  bypass: true;
  sessionSecret: string;
  baseUrl: string;
  devUser: {
    sub: string;
    email: string;
    name: string;
  };
}

export function loadAuthConfig(): AuthConfig {
  const port = process.env.PORT ?? "3000";
  const baseUrl = process.env.AUTH_BASE_URL ?? `http://localhost:${port}`;

  // iron-session requires >= 32 chars. Fall back to an obviously-fake
  // dev value so the app boots zero-config.
  let sessionSecret = process.env.AUTH_SESSION_SECRET ?? "";
  if (sessionSecret.length < 32) {
    sessionSecret =
      "dev-only-insecure-iron-session-secret-replace-in-prod-XXXXXXXX";
  }

  const devUser = {
    sub: process.env.DEV_USER_SUB ?? "dev@localhost",
    email: "dev@localhost",
    name: "Dev User",
  };

  return { bypass: true, sessionSecret, baseUrl, devUser };
}
