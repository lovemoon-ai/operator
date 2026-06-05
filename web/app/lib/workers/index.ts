/**
 * Post-ingest worker orchestrator.
 *
 * Triggered by the ingest middleware via the `onSession` hook once a
 * session has its `media` artifact on disk. Each worker derives a new
 * artifact next to the source (preview.mp4, session.rrd, …) and
 * registers it with the session store so the UI picks it up on the
 * next render — no schema migrations, no separate index.
 *
 * Ordering:
 *   1. preview  — ~1 s remux, gives the browser an inline-playable
 *                 RGB MP4 immediately
 *   2. rerun    — can be tens of seconds for a multi-minute capture;
 *                 runs after preview so quick scans of the dashboard
 *                 aren't blocked by the heavier job
 *
 * Both run sequentially because they touch the same on-disk session
 * directory and the same MemoryStore — sequencing keeps the persisted
 * index simple. If a worker grows expensive enough to need
 * parallelism, fan out with `Promise.allSettled` and add a simple
 * per-session mutex around the store updates.
 */
import type { SessionRecord } from "@love-moon/ego-ingest";

import { runPreviewWorker, type PreviewWorkerResult } from "./preview.js";
import { runRerunWorker, type RerunWorkerResult } from "./rerun.js";

export interface PostIngestReport {
  preview: PreviewWorkerResult;
  rerun: RerunWorkerResult;
}

export async function runPostIngestWorkers(
  session: SessionRecord,
): Promise<PostIngestReport> {
  const preview = await runPreviewWorker(session);
  logResult("preview", session.id, preview);

  // Re-read the session so the rerun worker sees the preview artifact
  // we just wrote. Cheap because MemoryStore reads are sync-ish.
  const rerun = await runRerunWorker(session);
  logResult("rerun  ", session.id, rerun);

  return { preview, rerun };
}

function logResult(
  name: string,
  sessionId: string,
  result: { status: string; reason?: string; durationMs?: number },
): void {
  const reason = result.reason ? ` · ${result.reason}` : "";
  const dur = typeof result.durationMs === "number" ? ` · ${result.durationMs}ms` : "";
  // eslint-disable-next-line no-console
  console.log(`[workers] ${name} ${sessionId}: ${result.status}${dur}${reason}`);
}

export { runPreviewWorker, runRerunWorker };
export type { PreviewWorkerResult, RerunWorkerResult };
