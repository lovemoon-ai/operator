/**
 * Conductor SSO client.
 *
 * Conductor exposes a custom OAuth-style authorization-code flow — NOT
 * standard OIDC (no /.well-known/openid-configuration, no id_token).
 * Spec: claw/developer/add-new-sso-client.md in the conductor repo.
 *
 * Two interactions:
 *   1. GET <baseUrl>/oauth/authorize?client_id=...&redirect_uri=...&
 *          state=...&response_type=code
 *      → user signs in on conductor, browser 302s back to our callback
 *        with `?code=...&state=...`
 *
 *   2. POST <baseUrl>/api/oauth/token   (server-to-server, JSON body)
 *      { grant_type, client_id, client_secret, code, redirect_uri }
 *      → { access_token, token_type, user: { id, email, phone, name },
 *          conductor_base_url }
 *
 * `redirect_uri` MUST be byte-identical between the two calls or
 * conductor returns `invalid_grant`. We compute it once per request.
 */
import { randomBytes } from "node:crypto";

import type { AuthConfig } from "./config.js";

export interface AuthorizeRequest {
  url: string;
  state: string;
}

export function buildAuthorizeUrl(cfg: AuthConfig): AuthorizeRequest {
  if (!cfg.conductor) throw new Error("buildAuthorizeUrl called without conductor config");
  const state = randomBytes(16).toString("hex");
  const url = new URL(`${cfg.conductor.baseUrl}/oauth/authorize`);
  url.searchParams.set("client_id", cfg.conductor.clientId);
  url.searchParams.set("redirect_uri", redirectUri(cfg));
  url.searchParams.set("response_type", "code");
  url.searchParams.set("state", state);
  return { url: url.toString(), state };
}

export interface ConductorUser {
  id: string;
  email?: string | null;
  phone?: string | null;
  name?: string | null;
}

export interface TokenResponse {
  access_token: string;
  token_type: "Bearer";
  user: ConductorUser;
  conductor_base_url: string;
}

export async function exchangeCode(
  cfg: AuthConfig,
  code: string,
): Promise<TokenResponse> {
  if (!cfg.conductor) throw new Error("exchangeCode called without conductor config");
  const body = {
    grant_type: "authorization_code",
    client_id: cfg.conductor.clientId,
    client_secret: cfg.conductor.clientSecret,
    code,
    redirect_uri: redirectUri(cfg),
  };
  const r = await fetch(`${cfg.conductor.baseUrl}/api/oauth/token`, {
    method: "POST",
    headers: { "Content-Type": "application/json" },
    body: JSON.stringify(body),
  });
  if (!r.ok) {
    let detail: string;
    try {
      detail = JSON.stringify(await r.json());
    } catch {
      detail = await r.text();
    }
    throw new Error(`conductor token exchange ${r.status}: ${detail}`);
  }
  return (await r.json()) as TokenResponse;
}

function redirectUri(cfg: AuthConfig): string {
  return `${cfg.baseUrl}/api/auth/callback`;
}
