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
import { randomBytes, randomUUID } from "node:crypto";

import { db } from "./db.js";

export interface User {
  id: string;
  oidcSub: string | null;
  email: string | null;
  name: string | null;
  uploadToken: string;
  createdAt: string;
  seeded: boolean;
}

interface UserRow {
  id: string;
  oidc_sub: string | null;
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
    email: row.email,
    name: row.name,
    uploadToken: row.upload_token,
    createdAt: row.created_at,
    seeded: !!row.seeded,
  };
}

const stmts = {
  bySub: db.prepare<[string], UserRow>(`SELECT * FROM users WHERE oidc_sub = ?`),
  byId: db.prepare<[string], UserRow>(`SELECT * FROM users WHERE id = ?`),
  byToken: db.prepare<[string], UserRow>(`SELECT * FROM users WHERE upload_token = ?`),
  insert: db.prepare<[string, string | null, string | null, string | null, string, string]>(`
    INSERT INTO users (id, oidc_sub, email, name, upload_token, created_at)
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
