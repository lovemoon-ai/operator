/**
 * Short-lived signed ticket used by the QR-code connect flow.
 *
 * The QR encodes an `/api/ingest/ack?u=<uploadUrl>&uid=<userId>&exp=...&sig=...`
 * URL. The headset scans it, hits the ack endpoint, and the server
 * verifies the signature before handing back the upload URL + the
 * user's permanent upload token.
 *
 * The `uid` field binds the QR to a specific dashboard user — the ack
 * endpoint uses it to mint the per-user bearer token. Signing covers
 * uploadUrl + uid + expiresAt so a captured ticket can't be replayed
 * against a different user.
 */
import { createHmac, timingSafeEqual } from "node:crypto";

export const CONNECT_TICKET_TTL_MS = 5 * 60 * 1000;

export interface ConnectTicket {
  uploadUrl: string;
  ackUrl: string;
  expiresAt: number;
}

export interface VerifyResult {
  ok: boolean;
  error?: "missing" | "expired" | "bad_signature";
}

export function buildConnectTicket(
  uploadUrl: string,
  userId: string,
  now = Date.now(),
): ConnectTicket {
  const normalized = trimTrailingSlash(uploadUrl);
  const expiresAt = now + CONNECT_TICKET_TTL_MS;
  const signature = sign(normalized, userId, expiresAt);
  const ackUrl = `${normalized}/ack?${new URLSearchParams({
    u: normalized,
    uid: userId,
    exp: String(expiresAt),
    sig: signature,
  }).toString()}`;
  return { uploadUrl: normalized, ackUrl, expiresAt };
}

export function verifyConnectTicket(
  uploadUrl: string,
  userId: string,
  expiresAt: number,
  signature: string,
  now = Date.now(),
): VerifyResult {
  if (!uploadUrl || !userId || !expiresAt || !signature) {
    return { ok: false, error: "missing" };
  }
  if (now > expiresAt) return { ok: false, error: "expired" };

  const expected = sign(trimTrailingSlash(uploadUrl), userId, expiresAt);
  const expectedBuf = Buffer.from(expected);
  const actualBuf = Buffer.from(signature);
  if (actualBuf.length !== expectedBuf.length || !timingSafeEqual(actualBuf, expectedBuf)) {
    return { ok: false, error: "bad_signature" };
  }
  return { ok: true };
}

function sign(uploadUrl: string, userId: string, expiresAt: number): string {
  return createHmac("sha256", connectSecret())
    .update(uploadUrl)
    .update("\n")
    .update(userId)
    .update("\n")
    .update(String(expiresAt))
    .digest("base64url");
}

function connectSecret(): string {
  return (
    process.env.INGEST_CONNECT_SECRET ??
    process.env.AUTH_SESSION_SECRET ??
    "operator-local-connect-ticket-v1"
  );
}

function trimTrailingSlash(url: string): string {
  return url.replace(/\/+$/, "");
}
