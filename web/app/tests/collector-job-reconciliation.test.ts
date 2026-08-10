import assert from "node:assert/strict";
import crypto from "node:crypto";
import { mkdtempSync, rmSync } from "node:fs";
import { createServer } from "node:http";
import { tmpdir } from "node:os";
import path from "node:path";
import test from "node:test";

import express from "express";

const testRoot = mkdtempSync(path.join(tmpdir(), "operator-job-reconcile-"));
process.env.DATA_ROOT = testRoot;

const { db } = await import("../lib/db.js");
const { collectorAgentRouter } = await import("../lib/collector-agents.js");

const token = "agent-secret";
const tokenHash = crypto.createHash("sha256").update(token).digest("hex");
const now = new Date().toISOString();
db.prepare(`
  INSERT INTO collector_agents
    (id, user_id, name, hostname, platform, agent_version, token_hash,
     config_json, state_json, created_at)
  VALUES (?, ?, ?, ?, ?, ?, ?, '{}', '{}', ?)
`).run("agent-1", "user-1", "test", "host", "linux", "0.1.6", tokenHash, now);
db.prepare(`
  INSERT INTO collector_jobs
    (id, agent_id, user_id, kind, payload_json, status, progress, message,
     error, created_at, updated_at)
  VALUES (?, ?, ?, 'delete_quest', '{}', 'failed', 0, '', ?, ?, ?)
`).run(
  "job-1",
  "agent-1",
  "user-1",
  "Result unknown; retry explicitly so recovery checks can run",
  now,
  now,
);

const app = express();
app.use("/api/collector-agent", collectorAgentRouter);
const server = createServer(app);
await new Promise<void>((resolve) => server.listen(0, "127.0.0.1", resolve));
const address = server.address();
if (!address || typeof address === "string") throw new Error("test server did not bind");
const endpoint = `http://127.0.0.1:${address.port}/api/collector-agent/jobs/job-1/complete`;

test.after(async () => {
  await new Promise<void>((resolve, reject) => {
    server.close((error) => error ? reject(error) : resolve());
  });
  db.close();
  rmSync(testRoot, { recursive: true, force: true });
});

test("a delayed durable completion reconciles an uncertain stale job", async () => {
  const complete = await fetch(endpoint, {
    method: "POST",
    headers: {
      Authorization: `Bearer ${token}`,
      "Content-Type": "application/json",
    },
    body: JSON.stringify({ result: { sessions: [], recovered: true } }),
  });
  assert.equal(complete.status, 200);
  const row = db.prepare("SELECT status, error FROM collector_jobs WHERE id = ?")
    .get("job-1") as { status: string; error: string | null };
  assert.deepEqual(row, { status: "completed", error: null });

  const replay = await fetch(endpoint, {
    method: "POST",
    headers: {
      Authorization: `Bearer ${token}`,
      "Content-Type": "application/json",
    },
    body: JSON.stringify({ result: { sessions: [], recovered: true } }),
  });
  assert.equal(replay.status, 200);
  assert.equal((await replay.json() as { idempotent?: boolean }).idempotent, true);
});
