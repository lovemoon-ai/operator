/**
 * Auth configuration plucked from environment.
 *
 * Required for prod:
 *   - AUTH_SESSION_SECRET      32+ char random string (iron-session)
 *   - OIDC_ISSUER              e.g. https://auth.example.com/realms/main
 *   - OIDC_CLIENT_ID
 *   - OIDC_CLIENT_SECRET
 *
 * Optional:
 *   - AUTH_BASE_URL            full origin we'll receive callbacks on,
 *                              e.g. https://demo.example.com (default
 *                              http://localhost:<PORT>)
 *   - OIDC_SCOPES              default "openid profile email"
 *   - AUTH_BYPASS=1            skip OIDC entirely, use a fixed dev user
 *                              (intended for local dev only)
 *   - DEV_USER_SUB             override the fixed dev user's sub
 *                              (default "dev@localhost")
 *
 * In bypass mode every env var above except SESSION_SECRET is optional
 * — we synthesize a sensible default so `npm run dev` works zero-config.
 */
export interface AuthConfig {
  bypass: boolean;
  sessionSecret: string;
  baseUrl: string;
  oidc: {
    issuer: string;
    clientId: string;
    clientSecret: string;
    scopes: string;
  } | null;
  devUser: {
    sub: string;
    email: string;
    name: string;
  };
}

export function loadAuthConfig(): AuthConfig {
  const bypass = process.env.AUTH_BYPASS === "1";
  const port = process.env.PORT ?? "3000";
  const baseUrl = process.env.AUTH_BASE_URL ?? `http://localhost:${port}`;

  // iron-session requires >= 32 chars. Fall back to an obviously-fake
  // dev value so the app boots zero-config, but warn so prod misuse is
  // visible in logs.
  let sessionSecret = process.env.AUTH_SESSION_SECRET ?? "";
  if (sessionSecret.length < 32) {
    if (bypass || process.env.NODE_ENV !== "production") {
      sessionSecret =
        "dev-only-insecure-iron-session-secret-replace-in-prod-XXXXXXXX";
      // eslint-disable-next-line no-console
      if (process.env.NODE_ENV === "production") {
        console.warn(
          "[auth] AUTH_SESSION_SECRET missing or too short; using a dev fallback. " +
            "Set AUTH_SESSION_SECRET to a 32+ char random string for production.",
        );
      }
    } else {
      throw new Error(
        "AUTH_SESSION_SECRET is required in production (32+ chars).",
      );
    }
  }

  const devUser = {
    sub: process.env.DEV_USER_SUB ?? "dev@localhost",
    email: "dev@localhost",
    name: "Dev User",
  };

  if (bypass) {
    return { bypass, sessionSecret, baseUrl, oidc: null, devUser };
  }

  const issuer = process.env.OIDC_ISSUER ?? "";
  const clientId = process.env.OIDC_CLIENT_ID ?? "";
  const clientSecret = process.env.OIDC_CLIENT_SECRET ?? "";
  if (!issuer || !clientId || !clientSecret) {
    throw new Error(
      "OIDC config missing. Set OIDC_ISSUER + OIDC_CLIENT_ID + OIDC_CLIENT_SECRET, " +
        "or AUTH_BYPASS=1 for local dev.",
    );
  }

  return {
    bypass: false,
    sessionSecret,
    baseUrl,
    oidc: {
      issuer,
      clientId,
      clientSecret,
      scopes: process.env.OIDC_SCOPES ?? "openid profile email",
    },
    devUser,
  };
}
