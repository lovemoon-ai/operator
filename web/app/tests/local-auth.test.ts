import assert from "node:assert/strict";
import { mkdtempSync, rmSync } from "node:fs";
import { tmpdir } from "node:os";
import path from "node:path";
import test from "node:test";

const testRoot = mkdtempSync(path.join(tmpdir(), "operator-local-auth-"));
process.env.DATA_ROOT = testRoot;

const users = await import("../lib/users.js");
const { db } = await import("../lib/db.js");

test.after(() => {
  db.close();
  rmSync(testRoot, { recursive: true, force: true });
});

test("creates a collector account and authenticates the same ID case-insensitively", () => {
  const created = users.authenticateOrCreateCollector("Alice_01", "123456");
  assert.equal(created.created, true);
  assert.equal(created.user.collectorId, "alice_01");

  const authenticated = users.authenticateOrCreateCollector("ALICE_01", "123456");
  assert.equal(authenticated.created, false);
  assert.equal(authenticated.user.id, created.user.id);
});

test("stores a salted scrypt hash instead of the PIN", () => {
  const row = db.prepare(
    "SELECT pin_hash FROM users WHERE collector_id = ?",
  ).get("alice_01") as { pin_hash: string };
  assert.match(row.pin_hash, /^scrypt-v1\$/);
  assert.equal(row.pin_hash.includes("123456"), false);
});

test("rejects a wrong PIN and malformed credentials", () => {
  assert.throws(
    () => users.authenticateOrCreateCollector("alice_01", "999999"),
    (error: unknown) => error instanceof users.CollectorAuthError
      && error.code === "invalid_credentials",
  );
  assert.throws(
    () => users.authenticateOrCreateCollector("x", "123456"),
    (error: unknown) => error instanceof users.CollectorAuthError
      && error.code === "invalid_id",
  );
  assert.throws(
    () => users.authenticateOrCreateCollector("bob_02", "12345"),
    (error: unknown) => error instanceof users.CollectorAuthError
      && error.code === "invalid_pin",
  );
});
