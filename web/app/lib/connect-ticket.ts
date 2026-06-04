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

export function buildConnectTicket(uploadUrl: string, now = Date.now()): ConnectTicket {
  const normalized = trimTrailingSlash(uploadUrl);
  const expiresAt = now + CONNECT_TICKET_TTL_MS;
  const signature = sign(normalized, expiresAt);
  const ackUrl = `${normalized}/ack?${new URLSearchParams({
    u: normalized,
    exp: String(expiresAt),
    sig: signature,
  }).toString()}`;
  return { uploadUrl: normalized, ackUrl, expiresAt };
}

export function verifyConnectTicket(uploadUrl: string, expiresAt: number, signature: string, now = Date.now()): VerifyResult {
  if (!uploadUrl || !expiresAt || !signature) return { ok: false, error: "missing" };
  if (now > expiresAt) return { ok: false, error: "expired" };

  const expected = sign(trimTrailingSlash(uploadUrl), expiresAt);
  const expectedBuf = Buffer.from(expected);
  const actualBuf = Buffer.from(signature);
  if (actualBuf.length !== expectedBuf.length || !timingSafeEqual(actualBuf, expectedBuf)) {
    return { ok: false, error: "bad_signature" };
  }
  return { ok: true };
}

function sign(uploadUrl: string, expiresAt: number): string {
  return createHmac("sha256", connectSecret())
    .update(uploadUrl)
    .update("\n")
    .update(String(expiresAt))
    .digest("base64url");
}

function connectSecret(): string {
  return (
    process.env.INGEST_CONNECT_SECRET ??
    process.env.INGEST_TOKEN ??
    "operator-local-connect-ticket-v1"
  );
}

function trimTrailingSlash(url: string): string {
  return url.replace(/\/+$/, "");
}
