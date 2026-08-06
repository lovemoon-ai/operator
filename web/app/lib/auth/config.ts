/**
 * Auth configuration plucked from environment.
 *
 * Required for prod:
 *   - AUTH_SESSION_SECRET      32+ char random string (iron-session)
 *   - CONDUCTOR_BASE_URL       e.g. https://conductor-ai.top
 *   - CONDUCTOR_CLIENT_ID      client_id registered in conductor's
 *                              CONDUCTOR_SSO_CLIENTS_JSON
 *   - CONDUCTOR_CLIENT_SECRET  matching plaintext shared secret
 *
 * Optional:
 *   - AUTH_BASE_URL            full origin we'll receive callbacks on,
 *                              e.g. https://operator.conductor-ai.top
 *                              (default http://localhost:<PORT>)
 *   - AUTH_BYPASS=1            use local collector ID + PIN authentication
 *                              instead of Conductor SSO
 *
 * In bypass mode every env var above except SESSION_SECRET is optional.
 *
 * Why "conductor" instead of "oidc": conductor's SSO is a custom
 * OAuth-style flow, not OIDC. See lib/auth/conductor.ts.
 */
export interface AuthConfig {
  bypass: boolean;
  sessionSecret: string;
  baseUrl: string;
  conductor: {
    baseUrl: string;
    clientId: string;
    clientSecret: string;
  } | null;
}

export function loadAuthConfig(): AuthConfig {
  const explicitBypass = process.env.AUTH_BYPASS === "1";
  const port = process.env.PORT ?? "3000";
  const baseUrl = process.env.AUTH_BASE_URL ?? `http://localhost:${port}`;
  const conductorBase = process.env.CONDUCTOR_BASE_URL ?? "";
  const clientId = process.env.CONDUCTOR_CLIENT_ID ?? "";
  const clientSecret = process.env.CONDUCTOR_CLIENT_SECRET ?? "";
  const hasConductorConfig = Boolean(conductorBase || clientId || clientSecret);
  const bypass =
    explicitBypass ||
    (process.env.NODE_ENV !== "production" && !hasConductorConfig);

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

  if (bypass) {
    return { bypass, sessionSecret, baseUrl, conductor: null };
  }

  if (!conductorBase || !clientId || !clientSecret) {
    throw new Error(
      "Conductor SSO config missing. Set CONDUCTOR_BASE_URL + " +
        "CONDUCTOR_CLIENT_ID + CONDUCTOR_CLIENT_SECRET, or AUTH_BYPASS=1 " +
        "for local dev.",
    );
  }

  return {
    bypass: false,
    sessionSecret,
    baseUrl,
    conductor: {
      baseUrl: conductorBase.replace(/\/+$/, ""),
      clientId,
      clientSecret,
    },
  };
}
