import assert from "node:assert/strict";
import { mkdtempSync, rmSync } from "node:fs";
import { tmpdir } from "node:os";
import path from "node:path";
import test from "node:test";

const testRoot = mkdtempSync(path.join(tmpdir(), "operator-ingest-tenancy-"));
process.env.DATA_ROOT = testRoot;

const { runAsUser } = await import("../lib/auth-context.js");
const { db } = await import("../lib/db.js");
const {
  ActiveArtifactUploadConflictError,
  SessionOwnershipConflictError,
  SqliteStore,
} = await import("../lib/sqlite-store.js");

const store = new SqliteStore();
const resource = {
  id: "resource-a",
  sessionId: "20260807_120000",
  artifactKind: "media",
  uploadLength: 100,
  offset: 0,
  metadata: {
    session_id: "20260807_120000",
    artifact_kind: "media",
    filename: "capture.mp4",
    extra: {},
  },
  createdAt: "2026-08-07T12:00:00Z",
};

test.after(() => {
  db.close();
  rmSync(testRoot, { recursive: true, force: true });
});

test("in-flight resources are readable and mutable only by their owner", async () => {
  await runAsUser("user-a", () => store.createResource(resource));

  assert.equal(await runAsUser("user-b", () => store.getResource(resource.id)), null);
  await runAsUser("user-b", () =>
    store.setResourceOffset(resource.id, 90, "2026-08-07T12:01:00Z"),
  );
  const owned = await runAsUser("user-a", () => store.getResource(resource.id));
  assert.equal(owned?.offset, 0);

  await assert.rejects(
    runAsUser("user-a", () => store.createResource({ ...resource, id: "resource-duplicate" })),
    ActiveArtifactUploadConflictError,
  );
});

test("a session id cannot be claimed or overwritten by another user", async () => {
  await assert.rejects(
    runAsUser("user-b", () =>
      store.createResource({ ...resource, id: "resource-b", artifactKind: "manifest" }),
    ),
    SessionOwnershipConflictError,
  );

  await runAsUser("user-a", () =>
    store.upsertSessionArtifact("20260807_130000", {
      kind: "media",
      filename: "a.mp4",
      bytes: 10,
      storedAt: "2026-08-07T13:00:00Z",
      uri: "disk://user-a",
    }),
  );
  await assert.rejects(
    runAsUser("user-b", () =>
      store.upsertSessionArtifact("20260807_130000", {
        kind: "media",
        filename: "b.mp4",
        bytes: 20,
        storedAt: "2026-08-07T13:00:01Z",
        uri: "disk://user-b",
      }),
    ),
    SessionOwnershipConflictError,
  );
  const original = await store.getSession("20260807_130000", { userId: "user-a" });
  assert.equal(original?.artifacts.media?.uri, "disk://user-a");
  assert.equal(await store.getSession("20260807_130000", { userId: "user-b" }), null);
});
