import crypto from "node:crypto";
import fs from "node:fs";
import path from "node:path";

import express, { type NextFunction, type Request, type Response } from "express";

import { currentUserId } from "./auth-context.js";
import { DATA_ROOT, db } from "./db.js";

const ENROLLMENT_TTL_MS = 10 * 60 * 1000;
const AGENT_ONLINE_MS = 30_000;
const STALE_RUNNING_JOB_MS = 2 * 60 * 60 * 1000;
const PREVIEW_ROOT = path.join(DATA_ROOT, "collector-previews");
const MAX_BATCH_UPLOAD_ITEMS = 100;
const FIXED_MODELSCOPE_REPO_ID = "chenghy666/test";
const DEFAULT_QUEST_ROOT = "/sdcard/DCIM/SpatialMP4";
const LEGACY_QUEST_ROOT = "/sdcard/Movies/SpatialMP4";

const JOB_KINDS = new Set(["scan", "start_ego", "import", "label", "upload", "preview", "delete_local"]);

db.exec(`
  CREATE TABLE IF NOT EXISTS collector_enrollments (
    id                TEXT PRIMARY KEY,
    poll_secret_hash  TEXT NOT NULL,
    hostname          TEXT NOT NULL,
    platform          TEXT NOT NULL,
    agent_version     TEXT NOT NULL,
    created_at        TEXT NOT NULL,
    expires_at        TEXT NOT NULL,
    approved_by       TEXT,
    approved_at       TEXT,
    agent_id          TEXT,
    issued_token      TEXT
  );

  CREATE TABLE IF NOT EXISTS collector_agents (
    id             TEXT PRIMARY KEY,
    user_id        TEXT NOT NULL,
    name           TEXT NOT NULL,
    hostname       TEXT NOT NULL,
    platform       TEXT NOT NULL,
    agent_version  TEXT NOT NULL,
    token_hash     TEXT UNIQUE NOT NULL,
    config_json    TEXT NOT NULL,
    state_json     TEXT NOT NULL,
    last_seen      TEXT,
    created_at     TEXT NOT NULL,
    revoked        INTEGER NOT NULL DEFAULT 0
  );
  CREATE INDEX IF NOT EXISTS idx_collector_agents_user
    ON collector_agents(user_id, created_at DESC);

  CREATE TABLE IF NOT EXISTS collector_jobs (
    id            TEXT PRIMARY KEY,
    agent_id      TEXT NOT NULL,
    user_id       TEXT NOT NULL,
    kind          TEXT NOT NULL,
    payload_json  TEXT NOT NULL,
    status        TEXT NOT NULL,
    progress      REAL NOT NULL DEFAULT 0,
    progress_json TEXT,
    message       TEXT NOT NULL DEFAULT '',
    result_json   TEXT,
    error         TEXT,
    created_at    TEXT NOT NULL,
    updated_at    TEXT NOT NULL
  );
  CREATE INDEX IF NOT EXISTS idx_collector_jobs_agent_status
    ON collector_jobs(agent_id, status, created_at);
  CREATE INDEX IF NOT EXISTS idx_collector_jobs_user
    ON collector_jobs(user_id, created_at DESC);

  CREATE TABLE IF NOT EXISTS collector_items (
    id                 TEXT PRIMARY KEY,
    agent_id           TEXT NOT NULL,
    user_id            TEXT NOT NULL,
    source_session_id  TEXT NOT NULL,
    dataset_name       TEXT NOT NULL,
    local_path         TEXT NOT NULL,
    label              TEXT NOT NULL DEFAULT '',
    status             TEXT NOT NULL,
    qc_json            TEXT NOT NULL,
    preview_uri        TEXT,
    upload_json        TEXT,
    created_at         TEXT NOT NULL,
    updated_at         TEXT NOT NULL,
    UNIQUE(agent_id, source_session_id)
  );
  CREATE INDEX IF NOT EXISTS idx_collector_items_user
    ON collector_items(user_id, created_at DESC);
`);

function ensureCollectorJobColumn(name: string, definition: string): void {
  const columns = db.prepare("PRAGMA table_info(collector_jobs)").all() as Array<{ name: string }>;
  if (columns.some((column) => column.name === name)) return;
  try {
    db.exec(`ALTER TABLE collector_jobs ADD COLUMN ${name} ${definition}`);
  } catch (error) {
    if (!String((error as Error).message).includes("duplicate column name")) throw error;
  }
}

ensureCollectorJobColumn("progress_json", "TEXT");

fs.mkdirSync(PREVIEW_ROOT, { recursive: true });

interface AgentRow {
  id: string;
  user_id: string;
  name: string;
  hostname: string;
  platform: string;
  agent_version: string;
  token_hash: string;
  config_json: string;
  state_json: string;
  last_seen: string | null;
  created_at: string;
  revoked: number;
}

interface JobRow {
  id: string;
  agent_id: string;
  user_id: string;
  kind: string;
  payload_json: string;
  status: string;
  progress: number;
  progress_json: string | null;
  message: string;
  result_json: string | null;
  error: string | null;
  created_at: string;
  updated_at: string;
}

interface ItemRow {
  id: string;
  agent_id: string;
  user_id: string;
  source_session_id: string;
  dataset_name: string;
  local_path: string;
  label: string;
  status: string;
  qc_json: string;
  preview_uri: string | null;
  upload_json: string | null;
  created_at: string;
  updated_at: string;
}

const stmts = {
  createEnrollment: db.prepare(`
    INSERT INTO collector_enrollments
      (id, poll_secret_hash, hostname, platform, agent_version, created_at, expires_at)
    VALUES (?, ?, ?, ?, ?, ?, ?)
  `),
  getEnrollment: db.prepare<[string], Record<string, unknown>>(
    `SELECT * FROM collector_enrollments WHERE id = ?`,
  ),
  approveEnrollment: db.prepare(`
    UPDATE collector_enrollments
    SET approved_by = ?, approved_at = ?, agent_id = ?, issued_token = ?
    WHERE id = ? AND approved_at IS NULL
  `),
  clearEnrollmentToken: db.prepare(`
    UPDATE collector_enrollments SET issued_token = NULL WHERE agent_id = ?
  `),
  createAgent: db.prepare(`
    INSERT INTO collector_agents
      (id, user_id, name, hostname, platform, agent_version, token_hash,
       config_json, state_json, created_at)
    VALUES (?, ?, ?, ?, ?, ?, ?, ?, '{}', ?)
  `),
  getAgentByTokenHash: db.prepare<[string], AgentRow>(
    `SELECT * FROM collector_agents WHERE token_hash = ? AND revoked = 0`,
  ),
  getAgentScoped: db.prepare<[string, string], AgentRow>(
    `SELECT * FROM collector_agents WHERE id = ? AND user_id = ? AND revoked = 0`,
  ),
  listAgents: db.prepare<[string], AgentRow>(`
    SELECT * FROM collector_agents WHERE user_id = ? AND revoked = 0
    ORDER BY created_at DESC
  `),
  updateHeartbeat: db.prepare(`
    UPDATE collector_agents
    SET hostname = ?, platform = ?, agent_version = ?, state_json = ?, last_seen = ?
    WHERE id = ?
  `),
  updateAgentConfig: db.prepare(`
    UPDATE collector_agents SET name = ?, config_json = ? WHERE id = ? AND user_id = ?
  `),
  revokeAgent: db.prepare(`
    UPDATE collector_agents SET revoked = 1 WHERE id = ? AND user_id = ?
  `),
  createJob: db.prepare(`
    INSERT INTO collector_jobs
      (id, agent_id, user_id, kind, payload_json, status, created_at, updated_at)
    VALUES (?, ?, ?, ?, ?, 'queued', ?, ?)
  `),
  nextJob: db.prepare<[string], JobRow>(`
    SELECT * FROM collector_jobs
    WHERE agent_id = ? AND status = 'queued'
    ORDER BY created_at ASC LIMIT 1
  `),
  requeueStaleJobs: db.prepare(`
    UPDATE collector_jobs
    SET status = 'queued', message = 'Agent reconnected; resuming from cache', updated_at = ?
    WHERE agent_id = ? AND status = 'running' AND updated_at < ?
  `),
  claimJob: db.prepare(`
    UPDATE collector_jobs
    SET status = 'running', updated_at = ?
    WHERE id = ? AND status = 'queued'
  `),
  getJobForAgent: db.prepare<[string, string], JobRow>(`
    SELECT * FROM collector_jobs WHERE id = ? AND agent_id = ?
  `),
  updateJobProgress: db.prepare(`
    UPDATE collector_jobs
    SET status = 'running', progress = ?, progress_json = ?, message = ?, updated_at = ?
    WHERE id = ? AND agent_id = ?
  `),
  completeJob: db.prepare(`
    UPDATE collector_jobs
    SET status = 'completed', progress = 1, message = ?, result_json = ?,
        error = NULL, updated_at = ?
    WHERE id = ? AND agent_id = ?
  `),
  failJob: db.prepare(`
    UPDATE collector_jobs
    SET status = 'failed', message = ?, error = ?, updated_at = ?
    WHERE id = ? AND agent_id = ?
  `),
  listJobs: db.prepare<[string], JobRow>(`
    SELECT * FROM collector_jobs WHERE user_id = ?
    ORDER BY created_at DESC LIMIT 3
  `),
  listUploadJobs: db.prepare<[string], JobRow>(`
    SELECT * FROM collector_jobs WHERE user_id = ? AND kind = 'upload'
    ORDER BY
      CASE status WHEN 'running' THEN 0 WHEN 'queued' THEN 1 ELSE 2 END,
      created_at DESC
    LIMIT 200
  `),
  findActiveUploadForItem: db.prepare<[string, string], JobRow>(`
    SELECT * FROM collector_jobs
    WHERE user_id = ? AND kind = 'upload' AND status IN ('queued', 'running')
      AND json_extract(payload_json, '$.item_id') = ?
    ORDER BY created_at DESC LIMIT 1
  `),
  upsertItem: db.prepare(`
    INSERT INTO collector_items
      (id, agent_id, user_id, source_session_id, dataset_name, local_path,
       label, status, qc_json, created_at, updated_at)
    VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
    ON CONFLICT(agent_id, source_session_id) DO UPDATE SET
      dataset_name = excluded.dataset_name,
      local_path = excluded.local_path,
      label = excluded.label,
      status = excluded.status,
      qc_json = excluded.qc_json,
      updated_at = excluded.updated_at
  `),
  getItemScoped: db.prepare<[string, string], ItemRow>(`
    SELECT * FROM collector_items WHERE id = ? AND user_id = ?
  `),
  getItemForAgentBySource: db.prepare<[string, string], ItemRow>(`
    SELECT * FROM collector_items WHERE agent_id = ? AND source_session_id = ?
  `),
  updateItemLabel: db.prepare(`
    UPDATE collector_items
    SET dataset_name = ?, local_path = ?, label = ?, status = ?, updated_at = ?
    WHERE id = ?
  `),
  updateItemUpload: db.prepare(`
    UPDATE collector_items SET status = ?, upload_json = ?, updated_at = ? WHERE id = ?
  `),
  updateItemPreview: db.prepare(`
    UPDATE collector_items SET preview_uri = ?, updated_at = ? WHERE id = ?
  `),
  deleteItem: db.prepare(`
    DELETE FROM collector_items WHERE id = ? AND user_id = ?
  `),
  listItems: db.prepare<[string], ItemRow>(`
    SELECT * FROM collector_items WHERE user_id = ?
    ORDER BY created_at DESC
  `),
};

const claimNextJob = db.transaction((agentId: string): JobRow | null => {
  const row = stmts.nextJob.get(agentId);
  if (!row) return null;
  const now = new Date().toISOString();
  const result = stmts.claimJob.run(now, row.id);
  if (result.changes !== 1) return null;
  return { ...row, status: "running", updated_at: now };
});

function hashSecret(value: string): string {
  return crypto.createHash("sha256").update(value).digest("hex");
}

function randomToken(bytes = 32): string {
  return crypto.randomBytes(bytes).toString("base64url");
}

function safeJson(value: string | null | undefined): unknown {
  if (!value) return null;
  try {
    return JSON.parse(value) as unknown;
  } catch {
    return null;
  }
}

function migrateLegacyQuestRoots(): void {
  const rows = db.prepare("SELECT id, config_json FROM collector_agents").all() as Array<{
    id: string;
    config_json: string;
  }>;
  const update = db.prepare("UPDATE collector_agents SET config_json = ? WHERE id = ?");
  const migrate = db.transaction(() => {
    for (const row of rows) {
      const parsed = safeJson(row.config_json);
      if (!parsed || typeof parsed !== "object" || Array.isArray(parsed)) continue;
      const config = parsed as Record<string, unknown>;
      if (config.quest_root !== LEGACY_QUEST_ROOT) continue;
      config.quest_root = DEFAULT_QUEST_ROOT;
      update.run(JSON.stringify(config), row.id);
    }
  });
  migrate();
}

migrateLegacyQuestRoots();

function bodyString(value: unknown, max = 256): string {
  return typeof value === "string" ? value.trim().slice(0, max) : "";
}

function progressMetrics(value: unknown): Record<string, unknown> | null {
  if (!value || typeof value !== "object" || Array.isArray(value)) return null;
  const source = value as Record<string, unknown>;
  const metrics: Record<string, unknown> = {};
  for (const key of [
    "transferredBytes",
    "totalBytes",
    "bytesPerSecond",
    "etaSeconds",
    "filesTotal",
    "workers",
  ]) {
    const numberValue = Number(source[key]);
    if (Number.isFinite(numberValue)) {
      metrics[key] = Math.max(0, Math.min(Number.MAX_SAFE_INTEGER, numberValue));
    }
  }
  const phase = bodyString(source.phase, 32);
  if (phase) metrics.phase = phase;
  if (typeof source.resumable === "boolean") metrics.resumable = source.resumable;
  return Object.keys(metrics).length > 0 ? metrics : null;
}

function requireBrowserUser(res: Response): string | null {
  const userId = currentUserId();
  if (!userId) {
    res.status(401).json({ error: "auth required" });
    return null;
  }
  return userId;
}

type AgentRequest = Request & { collectorAgent?: AgentRow };

function agentAuth(req: AgentRequest, res: Response, next: NextFunction): void {
  const header = req.header("Authorization") ?? "";
  const token = header.startsWith("Bearer ") ? header.slice(7) : "";
  if (!token) {
    res.status(401).json({ error: "agent token required" });
    return;
  }
  const agent = stmts.getAgentByTokenHash.get(hashSecret(token));
  if (!agent) {
    res.status(401).json({ error: "invalid agent token" });
    return;
  }
  req.collectorAgent = agent;
  next();
}

function publicAgent(row: AgentRow) {
  const lastSeenMs = row.last_seen ? Date.parse(row.last_seen) : 0;
  return {
    id: row.id,
    name: row.name,
    hostname: row.hostname,
    platform: row.platform,
    agentVersion: row.agent_version,
    config: safeJson(row.config_json) ?? {},
    state: safeJson(row.state_json) ?? {},
    lastSeen: row.last_seen,
    online: Date.now() - lastSeenMs < AGENT_ONLINE_MS,
    createdAt: row.created_at,
  };
}

function publicJob(row: JobRow) {
  return {
    id: row.id,
    agentId: row.agent_id,
    kind: row.kind,
    payload: safeJson(row.payload_json) ?? {},
    status: row.status,
    progress: row.progress,
    metrics: safeJson(row.progress_json) ?? {},
    message: row.message,
    result: safeJson(row.result_json),
    error: row.error,
    createdAt: row.created_at,
    updatedAt: row.updated_at,
  };
}

function publicItem(row: ItemRow) {
  const imagePreviews = previewPaths(row.preview_uri);
  const legacyVideoPreview = !!row.preview_uri && imagePreviews.length === 0;
  return {
    id: row.id,
    agentId: row.agent_id,
    sourceSessionId: row.source_session_id,
    datasetName: row.dataset_name,
    localPath: row.local_path,
    label: row.label,
    status: row.status,
    qc: safeJson(row.qc_json) ?? {},
    hasPreview: imagePreviews.length > 0 || legacyVideoPreview,
    previewCount: imagePreviews.length || (legacyVideoPreview ? 1 : 0),
    previewKind: imagePreviews.length > 0 ? "images" : (legacyVideoPreview ? "video" : "none"),
    upload: safeJson(row.upload_json),
    createdAt: row.created_at,
    updatedAt: row.updated_at,
  };
}

function previewPaths(value: string | null): string[] {
  if (!value?.startsWith("[")) return [];
  try {
    const parsed = JSON.parse(value) as unknown;
    return Array.isArray(parsed)
      ? parsed.filter((entry): entry is string => typeof entry === "string")
      : [];
  } catch {
    return [];
  }
}

function removePreviewArtifacts(itemId: string): void {
  fs.rmSync(path.join(PREVIEW_ROOT, itemId), { recursive: true, force: true });
  fs.rmSync(path.join(PREVIEW_ROOT, `${itemId}.mp4`), { force: true });
}

function createJob(agent: AgentRow, kind: string, payload: unknown): JobRow {
  if (!JOB_KINDS.has(kind)) throw new Error(`unsupported job kind: ${kind}`);
  const id = crypto.randomUUID();
  const now = new Date().toISOString();
  stmts.createJob.run(
    id,
    agent.id,
    agent.user_id,
    kind,
    JSON.stringify(payload ?? {}),
    now,
    now,
  );
  return {
    id,
    agent_id: agent.id,
    user_id: agent.user_id,
    kind,
    payload_json: JSON.stringify(payload ?? {}),
    status: "queued",
    progress: 0,
    progress_json: null,
    message: "",
    result_json: null,
    error: null,
    created_at: now,
    updated_at: now,
  };
}

function applyJobResult(agent: AgentRow, job: JobRow, result: Record<string, unknown>) {
  const now = new Date().toISOString();
  if (job.kind === "scan") {
    const state = (safeJson(agent.state_json) ?? {}) as Record<string, unknown>;
    const source = result.source === "local" ? "local" : "quest";
    const key = source === "local" ? "scannedLocalSessions" : "scannedQuestSessions";
    state[key] = Array.isArray(result.sessions) ? result.sessions : [];
    state[source === "local" ? "lastLocalScanAt" : "lastQuestScanAt"] = now;
    stmts.updateHeartbeat.run(
      agent.hostname,
      agent.platform,
      agent.agent_version,
      JSON.stringify(state),
      now,
      agent.id,
    );
    return null;
  }

  if (job.kind === "import") {
    const sourceSessionId = bodyString(result.source_session_id, 128);
    const localPath = bodyString(result.local_path, 4096);
    if (!sourceSessionId || !localPath) return null;
    const existing = stmts.getItemForAgentBySource.get(agent.id, sourceSessionId);
    const id = existing?.id ?? crypto.randomUUID();
    const datasetName = bodyString(result.dataset_name, 256) || sourceSessionId;
    const label = bodyString(result.label, 64);
    const qc = result.qc && typeof result.qc === "object" ? result.qc : {};
    stmts.upsertItem.run(
      id,
      agent.id,
      agent.user_id,
      sourceSessionId,
      datasetName,
      localPath,
      label,
      "imported",
      JSON.stringify(qc),
      existing?.created_at ?? now,
      now,
    );
    return id;
  }

  if (job.kind === "label") {
    const itemId = bodyString(result.item_id, 128);
    const item = itemId ? stmts.getItemScoped.get(itemId, agent.user_id) : undefined;
    if (!item || item.agent_id !== agent.id) return null;
    stmts.updateItemLabel.run(
      bodyString(result.dataset_name, 256) || item.dataset_name,
      bodyString(result.local_path, 4096) || item.local_path,
      bodyString(result.label, 64),
      "reviewed",
      now,
      item.id,
    );
    return item.id;
  }

  if (job.kind === "upload") {
    const itemId = bodyString(result.item_id, 128);
    const item = itemId ? stmts.getItemScoped.get(itemId, agent.user_id) : undefined;
    if (!item || item.agent_id !== agent.id) return null;
    stmts.updateItemUpload.run("uploaded", JSON.stringify(result), now, item.id);
    return item.id;
  }

  if (job.kind === "preview") {
    const itemId = bodyString(result.item_id, 128);
    const item = itemId ? stmts.getItemScoped.get(itemId, agent.user_id) : undefined;
    if (!item || item.agent_id !== agent.id) return null;
    return item.id;
  }

  if (job.kind === "delete_local") {
    const itemId = bodyString(result.item_id, 128);
    const item = itemId ? stmts.getItemScoped.get(itemId, agent.user_id) : undefined;
    if (!item || item.agent_id !== agent.id) return null;
    removePreviewArtifacts(item.id);
    stmts.deleteItem.run(item.id, agent.user_id);
    return null;
  }

  return null;
}

export const collectorAgentRouter = express.Router();

collectorAgentRouter.post("/bootstrap", express.json({ limit: "64kb" }), (req, res) => {
  const hostname = bodyString(req.body?.hostname, 128) || "unknown";
  const platform = bodyString(req.body?.platform, 64) || "unknown";
  const agentVersion = bodyString(req.body?.agentVersion, 64) || "unknown";
  const id = crypto.randomUUID();
  const secret = randomToken();
  const createdAt = new Date();
  const expiresAt = new Date(createdAt.getTime() + ENROLLMENT_TTL_MS);
  stmts.createEnrollment.run(
    id,
    hashSecret(secret),
    hostname,
    platform,
    agentVersion,
    createdAt.toISOString(),
    expiresAt.toISOString(),
  );
  res.status(201).json({
    enrollmentId: id,
    pollSecret: secret,
    enrollmentPath: `/collectors/enroll/${encodeURIComponent(id)}`,
    expiresAt: expiresAt.toISOString(),
  });
});

collectorAgentRouter.get("/bootstrap/:id", (req, res) => {
  const row = stmts.getEnrollment.get(req.params.id!);
  if (!row) return res.status(404).json({ error: "enrollment not found" });
  const supplied = req.header("X-Enrollment-Secret") ?? "";
  if (!supplied || hashSecret(supplied) !== row.poll_secret_hash) {
    return res.status(401).json({ error: "invalid enrollment secret" });
  }
  if (Date.parse(String(row.expires_at)) < Date.now()) {
    return res.status(410).json({ error: "enrollment expired" });
  }
  if (!row.approved_at) return res.json({ status: "pending" });
  const agent = stmts.getAgentScoped.get(String(row.agent_id), String(row.approved_by));
  if (!agent || !row.issued_token) {
    return res.status(409).json({ error: "enrollment already delivered; reset agent to retry" });
  }
  return res.json({
    status: "approved",
    agentId: agent.id,
    token: row.issued_token,
    config: safeJson(agent.config_json) ?? {},
  });
});

collectorAgentRouter.post(
  "/heartbeat",
  agentAuth,
  express.json({ limit: "256kb" }),
  (req: AgentRequest, res) => {
    const agent = req.collectorAgent!;
    const now = new Date().toISOString();
    const state = req.body?.state && typeof req.body.state === "object" ? req.body.state : {};
    stmts.updateHeartbeat.run(
      bodyString(req.body?.hostname, 128) || agent.hostname,
      bodyString(req.body?.platform, 64) || agent.platform,
      bodyString(req.body?.agentVersion, 64) || agent.agent_version,
      JSON.stringify(state),
      now,
      agent.id,
    );
    stmts.clearEnrollmentToken.run(agent.id);
    const fresh = stmts.getAgentScoped.get(agent.id, agent.user_id)!;
    const provisionedToken = (process.env.OPERATOR_MODELSCOPE_TOKEN ?? "").trim();
    res.json({
      ok: true,
      config: safeJson(fresh.config_json) ?? {},
      uploadCredentials: provisionedToken
        ? { repoId: FIXED_MODELSCOPE_REPO_ID, token: provisionedToken }
        : { repoId: FIXED_MODELSCOPE_REPO_ID },
    });
  },
);

collectorAgentRouter.post("/jobs/next", agentAuth, (req: AgentRequest, res) => {
  const now = new Date();
  stmts.requeueStaleJobs.run(
    now.toISOString(),
    req.collectorAgent!.id,
    new Date(now.getTime() - STALE_RUNNING_JOB_MS).toISOString(),
  );
  const row = claimNextJob(req.collectorAgent!.id);
  if (!row) return res.status(204).end();
  res.json(publicJob(row));
});

collectorAgentRouter.post(
  "/jobs/:id/progress",
  agentAuth,
  express.json({ limit: "64kb" }),
  (req: AgentRequest, res) => {
    const agent = req.collectorAgent!;
    const job = stmts.getJobForAgent.get(req.params.id!, agent.id);
    if (!job) return res.status(404).json({ error: "job not found" });
    const progress = Math.max(0, Math.min(1, Number(req.body?.progress ?? 0)));
    const message = bodyString(req.body?.message, 512);
    const metrics = progressMetrics(req.body?.metrics);
    stmts.updateJobProgress.run(
      progress,
      metrics ? JSON.stringify(metrics) : null,
      message,
      new Date().toISOString(),
      job.id,
      agent.id,
    );
    res.json({ ok: true });
  },
);

collectorAgentRouter.post(
  "/jobs/:id/complete",
  agentAuth,
  express.json({ limit: "2mb" }),
  (req: AgentRequest, res) => {
    const agent = req.collectorAgent!;
    const job = stmts.getJobForAgent.get(req.params.id!, agent.id);
    if (!job) return res.status(404).json({ error: "job not found" });
    const result = req.body?.result && typeof req.body.result === "object"
      ? req.body.result as Record<string, unknown>
      : {};
    const now = new Date().toISOString();
    const message = bodyString(req.body?.message, 512) || "completed";
    stmts.completeJob.run(message, JSON.stringify(result), now, job.id, agent.id);
    const itemId = applyJobResult(agent, job, result);
    res.json({ ok: true, itemId });
  },
);

collectorAgentRouter.post(
  "/jobs/:id/fail",
  agentAuth,
  express.json({ limit: "256kb" }),
  (req: AgentRequest, res) => {
    const agent = req.collectorAgent!;
    const job = stmts.getJobForAgent.get(req.params.id!, agent.id);
    if (!job) return res.status(404).json({ error: "job not found" });
    const error = bodyString(req.body?.error, 4000) || "unknown agent error";
    const message = bodyString(req.body?.message, 512) || "failed";
    stmts.failJob.run(message, error, new Date().toISOString(), job.id, agent.id);
    res.json({ ok: true });
  },
);

collectorAgentRouter.put(
  "/items/:id/preview",
  agentAuth,
  express.raw({ type: ["video/mp4", "application/octet-stream"], limit: "256mb" }),
  (req: AgentRequest, res) => {
    const agent = req.collectorAgent!;
    const item = stmts.getItemScoped.get(req.params.id!, agent.user_id);
    if (!item || item.agent_id !== agent.id) {
      return res.status(404).json({ error: "item not found" });
    }
    if (!Buffer.isBuffer(req.body) || req.body.length === 0) {
      return res.status(400).json({ error: "preview body required" });
    }
    const target = path.join(PREVIEW_ROOT, `${item.id}.mp4`);
    fs.writeFileSync(target, req.body, { mode: 0o600 });
    stmts.updateItemPreview.run(target, new Date().toISOString(), item.id);
    res.json({ ok: true, bytes: req.body.length });
  },
);

collectorAgentRouter.put(
  "/items/:id/previews/:index",
  agentAuth,
  express.raw({ type: ["image/jpeg", "application/octet-stream"], limit: "10mb" }),
  (req: AgentRequest, res) => {
    const agent = req.collectorAgent!;
    const item = stmts.getItemScoped.get(req.params.id!, agent.user_id);
    if (!item || item.agent_id !== agent.id) {
      return res.status(404).json({ error: "item not found" });
    }
    const index = Number(req.params.index);
    if (!Number.isInteger(index) || index < 0 || index >= 6) {
      return res.status(400).json({ error: "preview index must be between 0 and 5" });
    }
    if (!Buffer.isBuffer(req.body) || req.body.length === 0) {
      return res.status(400).json({ error: "preview image body required" });
    }

    const targetDir = path.join(PREVIEW_ROOT, item.id);
    let paths = previewPaths(item.preview_uri);
    if (index === 0) {
      fs.rmSync(targetDir, { recursive: true, force: true });
      fs.rmSync(path.join(PREVIEW_ROOT, `${item.id}.mp4`), { force: true });
      paths = [];
    }
    fs.mkdirSync(targetDir, { recursive: true, mode: 0o700 });
    const target = path.join(targetDir, `${String(index).padStart(2, "0")}.jpg`);
    fs.writeFileSync(target, req.body, { mode: 0o600 });
    paths[index] = target;
    const normalized = paths.filter((entry): entry is string => !!entry);
    stmts.updateItemPreview.run(JSON.stringify(normalized), new Date().toISOString(), item.id);
    res.json({ ok: true, index, bytes: req.body.length });
  },
);

export const collectorBrowserRouter = express.Router();
collectorBrowserRouter.use(express.json({ limit: "512kb" }));

collectorBrowserRouter.get("/overview", (_req, res) => {
  const userId = requireBrowserUser(res);
  if (!userId) return;
  res.json({
    agents: stmts.listAgents.all(userId).map(publicAgent),
    jobs: stmts.listJobs.all(userId).map(publicJob),
    uploads: stmts.listUploadJobs.all(userId).map(publicJob),
    items: stmts.listItems.all(userId).map(publicItem),
  });
});

collectorBrowserRouter.get("/enrollments/:id", (req, res) => {
  const userId = requireBrowserUser(res);
  if (!userId) return;
  const row = stmts.getEnrollment.get(req.params.id!);
  if (!row) return res.status(404).json({ error: "enrollment not found" });
  res.json({
    id: row.id,
    hostname: row.hostname,
    platform: row.platform,
    agentVersion: row.agent_version,
    expiresAt: row.expires_at,
    expired: Date.parse(String(row.expires_at)) < Date.now(),
    approved: !!row.approved_at,
    approvedByCurrentUser: row.approved_by === userId,
  });
});

collectorBrowserRouter.post("/enrollments/:id/approve", (req, res) => {
  const userId = requireBrowserUser(res);
  if (!userId) return;
  const row = stmts.getEnrollment.get(req.params.id!);
  if (!row) return res.status(404).json({ error: "enrollment not found" });
  if (Date.parse(String(row.expires_at)) < Date.now()) {
    return res.status(410).json({ error: "enrollment expired" });
  }
  if (row.approved_at) return res.status(409).json({ error: "already approved" });

  const agentId = crypto.randomUUID();
  const token = randomToken(36);
  const now = new Date().toISOString();
  const name = bodyString(req.body?.name, 128) || String(row.hostname);
  const config = {
    data_root: "",
    local_source_root: "",
    quest_root: DEFAULT_QUEST_ROOT,
    delete_after_import_default: false,
    preview_enabled: true,
    modelscope_revision: "master",
  };
  const transaction = db.transaction(() => {
    stmts.createAgent.run(
      agentId,
      userId,
      name,
      row.hostname,
      row.platform,
      row.agent_version,
      hashSecret(token),
      JSON.stringify(config),
      now,
    );
    const update = stmts.approveEnrollment.run(userId, now, agentId, token, row.id);
    if (update.changes !== 1) throw new Error("enrollment approval race");
  });
  transaction();
  res.status(201).json({ ok: true, agentId });
});

collectorBrowserRouter.patch("/agents/:id", (req, res) => {
  const userId = requireBrowserUser(res);
  if (!userId) return;
  const agent = stmts.getAgentScoped.get(req.params.id!, userId);
  if (!agent) return res.status(404).json({ error: "agent not found" });
  const prev = (safeJson(agent.config_json) ?? {}) as Record<string, unknown>;
  const incoming = req.body?.config && typeof req.body.config === "object"
    ? req.body.config as Record<string, unknown>
    : {};
  const allowed = [
    "data_root",
    "local_source_root",
    "quest_root",
    "delete_after_import_default",
    "preview_enabled",
    "modelscope_revision",
    "fixture_root",
    "adb_path",
    "ffmpeg_path",
  ];
  for (const key of allowed) {
    if (Object.prototype.hasOwnProperty.call(incoming, key)) prev[key] = incoming[key];
  }
  const name = bodyString(req.body?.name, 128) || agent.name;
  stmts.updateAgentConfig.run(name, JSON.stringify(prev), agent.id, userId);
  res.json({ ok: true });
});

collectorBrowserRouter.delete("/agents/:id", (req, res) => {
  const userId = requireBrowserUser(res);
  if (!userId) return;
  const result = stmts.revokeAgent.run(req.params.id!, userId);
  if (result.changes !== 1) return res.status(404).end();
  res.status(204).end();
});

collectorBrowserRouter.post("/agents/:id/jobs", (req, res) => {
  const userId = requireBrowserUser(res);
  if (!userId) return;
  const agent = stmts.getAgentScoped.get(req.params.id!, userId);
  if (!agent) return res.status(404).json({ error: "agent not found" });
  const kind = bodyString(req.body?.kind, 64);
  if (!JOB_KINDS.has(kind)) return res.status(400).json({ error: "unsupported job kind" });
  const payload = req.body?.payload && typeof req.body.payload === "object"
    ? req.body.payload as Record<string, unknown>
    : {};
  if (kind === "import") {
    const sourceSessionId = bodyString(payload.session_id, 128);
    const existing = sourceSessionId
      ? stmts.getItemForAgentBySource.get(agent.id, sourceSessionId)
      : undefined;
    if (existing) {
      return res.status(409).json({ error: "这条数据已经读取，无需重复导入" });
    }
  }
  const job = createJob(agent, kind, payload);
  res.status(201).json(publicJob(job));
});

collectorBrowserRouter.post("/items/:id/label", (req, res) => {
  const userId = requireBrowserUser(res);
  if (!userId) return;
  const item = stmts.getItemScoped.get(req.params.id!, userId);
  if (!item) return res.status(404).json({ error: "item not found" });
  const label = bodyString(req.body?.label, 64).toLowerCase();
  if (!/^[a-z0-9][a-z0-9_-]{0,63}$/.test(label)) {
    return res.status(400).json({ error: "label must use a-z, 0-9, _ or -" });
  }
  const agent = stmts.getAgentScoped.get(item.agent_id, userId);
  if (!agent) return res.status(409).json({ error: "agent unavailable" });
  const job = createJob(agent, "label", {
    item_id: item.id,
    source_session_id: item.source_session_id,
    local_path: item.local_path,
    label,
  });
  res.status(201).json(publicJob(job));
});

collectorBrowserRouter.post("/items/:id/upload", (req, res) => {
  const userId = requireBrowserUser(res);
  if (!userId) return;
  const item = stmts.getItemScoped.get(req.params.id!, userId);
  if (!item) return res.status(404).json({ error: "item not found" });
  if (!item.label) return res.status(409).json({ error: "label item before upload" });
  const active = stmts.findActiveUploadForItem.get(userId, item.id);
  if (active) return res.status(409).json({ error: "该数据已在上传队列中" });
  const agent = stmts.getAgentScoped.get(item.agent_id, userId);
  if (!agent) return res.status(409).json({ error: "agent unavailable" });
  const config = (safeJson(agent.config_json) ?? {}) as Record<string, unknown>;
  const revision = bodyString(req.body?.revision, 128)
    || bodyString(config.modelscope_revision, 128)
    || "master";
  const job = createJob(agent, "upload", {
    item_id: item.id,
    local_path: item.local_path,
    dataset_name: item.dataset_name,
    revision,
  });
  res.status(201).json(publicJob(job));
});

collectorBrowserRouter.post("/agents/:id/uploads", (req, res) => {
  const userId = requireBrowserUser(res);
  if (!userId) return;
  const agent = stmts.getAgentScoped.get(req.params.id!, userId);
  if (!agent) return res.status(404).json({ error: "agent not found" });

  const rawIds: unknown[] = Array.isArray(req.body?.item_ids) ? req.body.item_ids : [];
  const normalizedIds = rawIds
    .map((value) => bodyString(value, 128))
    .filter((value) => value.length > 0);
  const itemIds = Array.from(new Set<string>(normalizedIds));
  if (itemIds.length === 0) return res.status(400).json({ error: "请至少选择一条数据" });
  if (itemIds.length > MAX_BATCH_UPLOAD_ITEMS) {
    return res.status(400).json({ error: `一次最多上传 ${MAX_BATCH_UPLOAD_ITEMS} 条数据` });
  }

  const config = (safeJson(agent.config_json) ?? {}) as Record<string, unknown>;
  const revision = bodyString(req.body?.revision, 128)
    || bodyString(config.modelscope_revision, 128)
    || "master";

  const items = itemIds.map((itemId) => stmts.getItemScoped.get(itemId, userId));
  if (items.some((item) => !item || item.agent_id !== agent.id)) {
    return res.status(404).json({ error: "部分数据不存在或不属于这台工作站" });
  }
  if (items.some((item) => !item!.label)) {
    return res.status(409).json({ error: "所选数据中仍有未保存标签的条目" });
  }
  if (items.some((item) => stmts.findActiveUploadForItem.get(userId, item!.id))) {
    return res.status(409).json({ error: "所选数据中已有条目在上传队列中" });
  }

  const createBatch = db.transaction(() => items.map((item) => createJob(agent, "upload", {
    item_id: item!.id,
    local_path: item!.local_path,
    dataset_name: item!.dataset_name,
    revision,
  })));
  const jobs = createBatch();
  res.status(201).json({
    count: jobs.length,
    repoId: FIXED_MODELSCOPE_REPO_ID,
    privateRepository: true,
    jobs: jobs.map(publicJob),
  });
});

collectorBrowserRouter.post("/items/:id/preview", (req, res) => {
  const userId = requireBrowserUser(res);
  if (!userId) return;
  const item = stmts.getItemScoped.get(req.params.id!, userId);
  if (!item) return res.status(404).json({ error: "item not found" });
  const agent = stmts.getAgentScoped.get(item.agent_id, userId);
  if (!agent) return res.status(409).json({ error: "agent unavailable" });
  const job = createJob(agent, "preview", {
    item_id: item.id,
    local_path: item.local_path,
  });
  res.status(201).json(publicJob(job));
});

collectorBrowserRouter.delete("/items/:id", (req, res) => {
  const userId = requireBrowserUser(res);
  if (!userId) return;
  const item = stmts.getItemScoped.get(req.params.id!, userId);
  if (!item) return res.status(404).json({ error: "item not found" });
  const agent = stmts.getAgentScoped.get(item.agent_id, userId);
  if (!agent) return res.status(409).json({ error: "agent unavailable" });
  const job = createJob(agent, "delete_local", {
    item_id: item.id,
    local_path: item.local_path,
  });
  res.status(202).json(publicJob(job));
});

collectorBrowserRouter.get("/items/:id/preview", (req, res) => {
  const userId = requireBrowserUser(res);
  if (!userId) return;
  const item = stmts.getItemScoped.get(req.params.id!, userId);
  if (!item?.preview_uri || !fs.existsSync(item.preview_uri)) {
    return res.status(404).json({ error: "preview not found" });
  }
  res.type("video/mp4");
  res.sendFile(path.resolve(item.preview_uri));
});

collectorBrowserRouter.get("/items/:id/previews/:index", (req, res) => {
  const userId = requireBrowserUser(res);
  if (!userId) return;
  const item = stmts.getItemScoped.get(req.params.id!, userId);
  const index = Number(req.params.index);
  const paths = previewPaths(item?.preview_uri ?? null);
  const preview = Number.isInteger(index) ? paths[index] : undefined;
  if (!item || !preview || !fs.existsSync(preview)) {
    return res.status(404).json({ error: "preview image not found" });
  }
  res.setHeader("Cache-Control", "private, max-age=3600");
  res.type("image/jpeg");
  res.sendFile(path.resolve(preview));
});
