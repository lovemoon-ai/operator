/**
 * Users table CRUD.
 *
 * Two kinds of identity:
 *
 *   - Browser identity comes from OIDC (`oidc_sub` is the issuer's
 *     subject claim). Server.ts looks the user up by `oidc_sub` on
 *     each request, mints a new row on first sight.
 *
 *   - Headset identity comes from `upload_token` (a long random
 *     string). The TUS middleware's auth predicate looks the user up
 *     by token; the token is shown to the operator on /settings and
 *     embedded in the QR code on /connect so the device never has to
 *     type it.
 */
import { randomBytes, randomUUID, scryptSync, timingSafeEqual } from "node:crypto";

import { db } from "./db.js";

export interface User {
  id: string;
  oidcSub: string | null;
  collectorId: string | null;
  email: string | null;
  name: string | null;
  uploadToken: string;
  createdAt: string;
  seeded: boolean;
}

interface UserRow {
  id: string;
  oidc_sub: string | null;
  collector_id: string | null;
  pin_hash: string | null;
  email: string | null;
  name: string | null;
  upload_token: string;
  created_at: string;
  seeded: number;
}

function rowToUser(row: UserRow): User {
  return {
    id: row.id,
    oidcSub: row.oidc_sub,
    collectorId: row.collector_id,
    email: row.email,
    name: row.name,
    uploadToken: row.upload_token,
    createdAt: row.created_at,
    seeded: !!row.seeded,
  };
}

const stmts = {
  bySub: db.prepare<[string], UserRow>(`SELECT * FROM users WHERE oidc_sub = ?`),
  byCollectorId: db.prepare<[string], UserRow>(
    `SELECT * FROM users WHERE collector_id = ? COLLATE NOCASE`,
  ),
  byId: db.prepare<[string], UserRow>(`SELECT * FROM users WHERE id = ?`),
  byToken: db.prepare<[string], UserRow>(`SELECT * FROM users WHERE upload_token = ?`),
  insert: db.prepare<[string, string | null, string | null, string | null, string, string]>(`
    INSERT INTO users (id, oidc_sub, email, name, upload_token, created_at)
    VALUES (?, ?, ?, ?, ?, ?)
  `),
  insertCollector: db.prepare<[string, string, string, string, string, string]>(`
    INSERT INTO users
      (id, collector_id, pin_hash, name, upload_token, created_at)
    VALUES (?, ?, ?, ?, ?, ?)
  `),
  setProfile: db.prepare<[string | null, string | null, string]>(`
    UPDATE users SET email = ?, name = ? WHERE id = ?
  `),
  rotateToken: db.prepare<[string, string]>(`
    UPDATE users SET upload_token = ? WHERE id = ?
  `),
  markSeeded: db.prepare<[string]>(`UPDATE users SET seeded = 1 WHERE id = ?`),
};

const COLLECTOR_ID_RE = /^[a-z0-9][a-z0-9_-]{2,31}$/;
const PIN_RE = /^\d{6}$/;
const PIN_KEY_BYTES = 32;

export type CollectorAuthErrorCode =
  | "invalid_id"
  | "invalid_pin"
  | "invalid_credentials";

export class CollectorAuthError extends Error {
  constructor(public readonly code: CollectorAuthErrorCode) {
    super(code);
    this.name = "CollectorAuthError";
  }
}

function normalizeCollectorId(value: string): string {
  return value.trim().toLowerCase();
}

function hashPin(pin: string, salt = randomBytes(16)): string {
  const derived = scryptSync(pin, salt, PIN_KEY_BYTES, { maxmem: 64 * 1024 * 1024 });
  return `scrypt-v1$${salt.toString("base64url")}$${derived.toString("base64url")}`;
}

function verifyPin(pin: string, encoded: string): boolean {
  const [scheme, saltText, hashText] = encoded.split("$");
  if (scheme !== "scrypt-v1" || !saltText || !hashText) return false;
  try {
    const salt = Buffer.from(saltText, "base64url");
    const expected = Buffer.from(hashText, "base64url");
    const actual = scryptSync(pin, salt, expected.length, { maxmem: 64 * 1024 * 1024 });
    return expected.length === actual.length && timingSafeEqual(expected, actual);
  } catch {
    return false;
  }
}

export function authenticateOrCreateCollector(
  rawCollectorId: string,
  pin: string,
): { user: User; created: boolean } {
  const collectorId = normalizeCollectorId(rawCollectorId);
  if (!COLLECTOR_ID_RE.test(collectorId)) throw new CollectorAuthError("invalid_id");
  if (!PIN_RE.test(pin)) throw new CollectorAuthError("invalid_pin");

  const existing = stmts.byCollectorId.get(collectorId);
  if (existing) {
    if (!existing.pin_hash || !verifyPin(pin, existing.pin_hash)) {
      throw new CollectorAuthError("invalid_credentials");
    }
    return { user: rowToUser(existing), created: false };
  }

  const id = randomUUID();
  try {
    stmts.insertCollector.run(
      id,
      collectorId,
      hashPin(pin),
      collectorId,
      newUploadToken(),
      new Date().toISOString(),
    );
  } catch (error) {
    // Resolve a simultaneous first login for the same ID without ever
    // accepting the other request's PIN.
    if ((error as { code?: string }).code !== "SQLITE_CONSTRAINT_UNIQUE") throw error;
    const raced = stmts.byCollectorId.get(collectorId);
    if (!raced?.pin_hash || !verifyPin(pin, raced.pin_hash)) {
      throw new CollectorAuthError("invalid_credentials");
    }
    return { user: rowToUser(raced), created: false };
  }
  return { user: rowToUser(stmts.byId.get(id)!), created: true };
}

export function newUploadToken(): string {
  // 32 random bytes → 43-char base64url. Long enough that brute-force is
  // pointless even without rate limiting.
  return randomBytes(32).toString("base64url");
}

/**
 * Look up a user by their OIDC `sub`, creating a fresh row (with a new
 * upload token) on first sight. Email + name are refreshed on every
 * call so a renamed account stays in sync.
 */
export function findOrCreateUserBySub(
  sub: string,
  profile: { email?: string | null; name?: string | null } = {},
): User {
  const existing = stmts.bySub.get(sub);
  if (existing) {
    if (profile.email !== undefined || profile.name !== undefined) {
      stmts.setProfile.run(
        profile.email ?? existing.email,
        profile.name ?? existing.name,
        existing.id,
      );
    }
    return rowToUser(stmts.byId.get(existing.id)!);
  }
  const id = randomUUID();
  stmts.insert.run(
    id,
    sub,
    profile.email ?? null,
    profile.name ?? null,
    newUploadToken(),
    new Date().toISOString(),
  );
  return rowToUser(stmts.byId.get(id)!);
}

export function getUserById(id: string): User | null {
  const row = stmts.byId.get(id);
  return row ? rowToUser(row) : null;
}

export function getUserByUploadToken(token: string): User | null {
  if (!token) return null;
  const row = stmts.byToken.get(token);
  return row ? rowToUser(row) : null;
}

export function rotateUploadToken(userId: string): string {
  const tok = newUploadToken();
  stmts.rotateToken.run(tok, userId);
  return tok;
}

export function markSeeded(userId: string): void {
  stmts.markSeeded.run(userId);
}
