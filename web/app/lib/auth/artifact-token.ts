/**
 * Short-lived HMAC token for artifact URLs that the WASM Rerun viewer
 * embeds in its own fetch.
 *
 * Background: `@rerun-io/web-viewer`'s wasm bundles a Rust `reqwest`
 * client. On `viewer.start(url)`, that client issues an HTTP GET — but
 * it does NOT carry browser cookies (default `credentials: 'omit'`),
 * even on same-origin requests. So our cookie-gated `/api/ingest-read/*`
 * artifact route always 401s the wasm fetch, even though the user is
 * authenticated in the parent page.
 *
 * The cleanest workaround that keeps the wasm's streaming/progressive
 * decode path intact (vs. pre-buffering the whole 100+ MB rrd into a
 * JS Blob) is a signed query token: the server component renders the
 * rrd URL with `?u=<userId>&e=<expiryMs>&t=<hmac>` appended, the auth
 * middleware accepts that token as a fallback when the cookie is
 * missing.
 *
 * Token = first 32 hex chars of HMAC-SHA256(secret, `${path}|${userId}|${expiry}`).
 *
 * Path is included so a token signed for one artifact can't be replayed
 * against another. UserId is included so the read API still scopes
 * session lookup correctly (the artifact handler runs
 * `store.getSession(id, { userId })`).
 *
 * Default TTL is 6 hours — long enough that a user can leave the
 * session page open and come back, short enough that a leaked URL
 * doesn't become a permanent backdoor.
 */
import crypto from "node:crypto";

const DEFAULT_TTL_MS = 6 * 60 * 60 * 1000;
const TOKEN_HEX_LEN = 32;

export function signArtifactToken(
  secret: string,
  path: string,
  userId: string,
  opts: { ttlMs?: number; now?: number } = {},
): { token: string; expiry: number; query: string } {
  const now = opts.now ?? Date.now();
  const expiry = now + (opts.ttlMs ?? DEFAULT_TTL_MS);
  const token = crypto
    .createHmac("sha256", secret)
    .update(`${path}|${userId}|${expiry}`)
    .digest("hex")
    .slice(0, TOKEN_HEX_LEN);
  const query = `u=${encodeURIComponent(userId)}&e=${expiry}&t=${token}`;
  return { token, expiry, query };
}

export function verifyArtifactToken(
  secret: string,
  path: string,
  query: Record<string, unknown>,
  opts: { now?: number } = {},
): string | null {
  const u = typeof query.u === "string" ? query.u : "";
  const eStr = typeof query.e === "string" ? query.e : "";
  const t = typeof query.t === "string" ? query.t : "";
  if (!u || !eStr || !t) return null;
  const expiry = Number.parseInt(eStr, 10);
  if (!Number.isFinite(expiry)) return null;
  const now = opts.now ?? Date.now();
  if (expiry < now) return null;
  const expected = crypto
    .createHmac("sha256", secret)
    .update(`${path}|${u}|${expiry}`)
    .digest("hex")
    .slice(0, TOKEN_HEX_LEN);
  if (t.length !== expected.length) return null;
  let ok = false;
  try {
    ok = crypto.timingSafeEqual(Buffer.from(t), Buffer.from(expected));
  } catch {
    return null;
  }
  return ok ? u : null;
}
