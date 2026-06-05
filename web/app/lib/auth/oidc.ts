/**
 * OIDC client singleton.
 *
 * We use `openid-client` v5 (CJS-friendly, ESM via dynamic import).
 * Discovery runs once at boot — the issuer URL is the only required
 * input, the rest comes from `/.well-known/openid-configuration`.
 *
 * PKCE is mandatory. The flow:
 *
 *   /login              → state + code_verifier into the session cookie,
 *                         302 to authorization endpoint
 *   /api/auth/callback  → exchange code for tokens, pull userinfo,
 *                         findOrCreateUserBySub(), store userId in session,
 *                         302 to returnTo (or "/")
 *   /logout             → destroy session cookie, 302 to "/"
 *
 * We don't store the access/id token after callback because the app
 * never re-calls the IdP afterward — the local user row is the
 * authoritative identity.
 */
import { generators, Issuer, type Client } from "openid-client";

import type { AuthConfig } from "./config.js";

let cached: Promise<Client> | null = null;

export async function getOidcClient(config: AuthConfig): Promise<Client> {
  if (!config.oidc) {
    throw new Error("getOidcClient called in bypass mode");
  }
  if (cached) return cached;
  cached = (async () => {
    const issuer = await Issuer.discover(config.oidc!.issuer);
    return new issuer.Client({
      client_id: config.oidc!.clientId,
      client_secret: config.oidc!.clientSecret,
      redirect_uris: [`${config.baseUrl}/api/auth/callback`],
      response_types: ["code"],
    });
  })();
  return cached;
}

export function newAuthRequest(config: AuthConfig, client: Client) {
  const state = generators.state();
  const verifier = generators.codeVerifier();
  const challenge = generators.codeChallenge(verifier);
  const url = client.authorizationUrl({
    scope: config.oidc!.scopes,
    state,
    code_challenge: challenge,
    code_challenge_method: "S256",
  });
  return { url, state, verifier };
}

export async function exchangeCode(
  client: Client,
  config: AuthConfig,
  query: Record<string, string>,
  expectedState: string,
  verifier: string,
): Promise<{ sub: string; email?: string; name?: string }> {
  // `callbackParams` accepts either a Node request object or a raw
  // query string. We have the parsed query object on hand, so we pass
  // the URL form.
  const params = client.callbackParams(`/cb?${new URLSearchParams(query).toString()}`);
  const tokenSet = await client.callback(
    `${config.baseUrl}/api/auth/callback`,
    params,
    { state: expectedState, code_verifier: verifier },
  );
  const claims = tokenSet.claims();
  // Prefer id_token claims; fall back to /userinfo for IdPs that ship
  // minimal id_tokens.
  let email = typeof claims.email === "string" ? claims.email : undefined;
  let name = typeof claims.name === "string" ? claims.name : undefined;
  if ((!email || !name) && tokenSet.access_token) {
    try {
      const info = await client.userinfo(tokenSet.access_token);
      email ??= typeof info.email === "string" ? info.email : undefined;
      name ??= typeof info.name === "string" ? info.name : undefined;
    } catch {
      /* userinfo optional */
    }
  }
  return { sub: claims.sub, email, name };
}
