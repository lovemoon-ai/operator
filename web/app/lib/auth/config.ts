/**
 * Local Station authentication configuration.
 *
 * Station intentionally uses collector ID + PIN authentication. The browser
 * stores only a signed session cookie; each collector maps to a separate user
 * row and therefore sees only their own agents and datasets.
 */
export interface AuthConfig {
  sessionSecret: string;
  baseUrl: string;
}

export function loadAuthConfig(): AuthConfig {
  const port = process.env.PORT ?? "3000";
  const baseUrl = process.env.AUTH_BASE_URL ?? `http://localhost:${port}`;

  let sessionSecret = process.env.AUTH_SESSION_SECRET ?? "";
  if (sessionSecret.length < 32) {
    if (process.env.NODE_ENV === "production") {
      throw new Error(
        "AUTH_SESSION_SECRET is required in production (32+ chars).",
      );
    }
    sessionSecret =
      "dev-only-insecure-iron-session-secret-replace-in-prod-XXXXXXXX";
  }

  return { sessionSecret, baseUrl };
}
