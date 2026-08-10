import assert from "node:assert/strict";
import { existsSync, mkdtempSync, rmSync } from "node:fs";
import { createServer } from "node:http";
import { tmpdir } from "node:os";
import path from "node:path";
import test from "node:test";
import { setTimeout as delay } from "node:timers/promises";

import express from "express";
import type {
  ArtifactWriteHandle,
  StorageDriver,
  UploadMetadata,
} from "@love-moon/ego-ingest";

const testRoot = mkdtempSync(path.join(tmpdir(), "operator-ingest-concurrency-"));
process.env.DATA_ROOT = testRoot;

const { db } = await import("../lib/db.js");
const { SqliteStore } = await import("../lib/sqlite-store.js");
const { createIngestMiddleware, DiskStorage, TUS_VERSION } = await import(
  "@love-moon/ego-ingest"
);

const app = express();
const store = new SqliteStore();
const storageRoot = path.join(testRoot, "ingest");
const diskStorage = new DiskStorage({ root: storageRoot });
let mediaFinalizeGate: {
  entered: Promise<void>;
  markEntered: () => void;
  proceed: Promise<void>;
  release: () => void;
} | null = null;

function wrapHandle(handle: ArtifactWriteHandle): ArtifactWriteHandle {
  return {
    ...handle,
    finalize: async (metadata: UploadMetadata, totalBytes: number) => {
      const finalized = await handle.finalize(metadata, totalBytes);
      const gate = mediaFinalizeGate;
      if (gate && metadata.artifact_kind === "media") {
        gate.markEntered();
        await gate.proceed;
      }
      return finalized;
    },
  };
}

const storage: StorageDriver = {
  openResource: async (resourceId, options) =>
    wrapHandle(await diskStorage.openResource(resourceId, options)),
  reopenResource: async (resourceId) => {
    const handle = await diskStorage.reopenResource(resourceId);
    return handle ? wrapHandle(handle) : null;
  },
  resourceOffset: (resourceId) => diskStorage.resourceOffset(resourceId),
  openFinalized: (uri, range) => diskStorage.openFinalized(uri, range),
  deleteFinalized: (uri) => diskStorage.deleteFinalized(uri),
};
app.use("/api/ingest", createIngestMiddleware({
  store,
  storage,
  auth: () => true,
  userIdFromReq: () => "user-a",
}));
const server = createServer(app);
await new Promise<void>((resolve) => server.listen(0, "127.0.0.1", resolve));
const address = server.address();
if (!address || typeof address === "string") throw new Error("test server did not bind");
const baseUrl = `http://127.0.0.1:${address.port}/api/ingest`;

test.after(async () => {
  await new Promise<void>((resolve, reject) => {
    server.close((error) => error ? reject(error) : resolve());
  });
  db.close();
  rmSync(testRoot, { recursive: true, force: true });
});

function metadataValue(value: string): string {
  return Buffer.from(value, "utf8").toString("base64");
}

async function createUpload(
  sessionId: string,
  artifactKind: string,
  filename: string,
  length: number,
): Promise<string> {
  const created = await fetch(baseUrl, {
    method: "POST",
    headers: {
      "Tus-Resumable": TUS_VERSION,
      "Upload-Length": String(length),
      "Upload-Metadata": [
        `session_id ${metadataValue(sessionId)}`,
        `artifact_kind ${metadataValue(artifactKind)}`,
        `filename ${metadataValue(filename)}`,
      ].join(","),
    },
  });
  assert.equal(created.status, 201);
  const location = created.headers.get("location");
  assert.ok(location);
  return new URL(location, baseUrl).toString();
}

function patchUpload(uploadUrl: string, offset: number, body: Buffer): Promise<Response> {
  return fetch(uploadUrl, {
    method: "PATCH",
    headers: {
      "Tus-Resumable": TUS_VERSION,
      "Upload-Offset": String(offset),
      "Content-Type": "application/offset+octet-stream",
      "Content-Length": String(body.length),
    },
    body,
  });
}

function createFinalizeGate() {
  let markEntered!: () => void;
  let release!: () => void;
  return {
    entered: new Promise<void>((resolve) => {
      markEntered = resolve;
    }),
    markEntered: () => markEntered(),
    proceed: new Promise<void>((resolve) => {
      release = resolve;
    }),
    release: () => release(),
  };
}

test("concurrent PATCH requests cannot append from the same offset twice", async () => {
  const uploadUrl = await createUpload(
    "20260809_120000_lock",
    "media",
    "capture.mp4",
    4,
  );
  const patch = () => patchUpload(uploadUrl, 0, Buffer.from("aa"));
  const responses = await Promise.all([patch(), patch()]);
  assert.deepEqual(responses.map((response) => response.status).sort(), [204, 409]);

  const head = await fetch(uploadUrl, { method: "HEAD" });
  assert.equal(head.status, 200);
  assert.equal(head.headers.get("upload-offset"), "2");
});

test("session DELETE waits for finalization and leaves no orphan files or rows", async () => {
  const sessionId = "20260809_120100_delete";
  const manifestUrl = await createUpload(sessionId, "manifest", "manifest.json", 2);
  assert.equal((await patchUpload(manifestUrl, 0, Buffer.from("{}"))).status, 204);
  const mediaUrl = await createUpload(sessionId, "media", "capture.mp4", 2);
  const mediaResourceId = new URL(mediaUrl).pathname.split("/").pop()!;

  mediaFinalizeGate = createFinalizeGate();
  const mediaPatch = patchUpload(mediaUrl, 0, Buffer.from("aa"));
  await mediaFinalizeGate.entered;
  const deletion = fetch(`${baseUrl}/sessions/${sessionId}`, { method: "DELETE" });
  const earlyDelete = await Promise.race([
    deletion.then(() => "finished"),
    delay(30).then(() => "waiting"),
  ]);
  assert.equal(earlyDelete, "waiting");
  mediaFinalizeGate.release();

  const [patchResponse, deleteResponse] = await Promise.all([mediaPatch, deletion]);
  mediaFinalizeGate = null;
  assert.equal(patchResponse.status, 204);
  assert.equal(deleteResponse.status, 204);
  assert.equal(await store.getSession(sessionId, { userId: "user-a" }), null);
  const resourceCount = db.prepare(
    "SELECT count(*) count FROM resources WHERE session_id = ?",
  ).get(sessionId) as { count: number };
  const artifactCount = db.prepare(
    "SELECT count(*) count FROM artifacts WHERE session_id = ?",
  ).get(sessionId) as { count: number };
  assert.equal(resourceCount.count, 0);
  assert.equal(artifactCount.count, 0);
  assert.equal(existsSync(path.join(storageRoot, ".partial", mediaResourceId)), false);
  assert.equal(existsSync(path.join(storageRoot, "user-a", sessionId)), false);
});
