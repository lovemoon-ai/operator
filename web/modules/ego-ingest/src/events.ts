import { EventEmitter } from "node:events";

import type { ResourceRecord, SessionRecord } from "./types.js";

export type IngestEvent =
  | { type: "resource.created"; resource: ResourceRecord; userId?: string }
  | { type: "resource.progress"; resourceId: string; offset: number; uploadLength: number; userId?: string }
  | { type: "resource.finalized"; resourceId: string; sessionId: string; userId?: string }
  | { type: "session.updated"; session: SessionRecord }
  | {
      /**
       * Fired by the orphan watchdog when a session has had a
       * manifest artifact for longer than the configured timeout
       * without media following it. The session is left in-place
       * (artifacts still on disk) but workers never fire.
       */
      type: "session.expired";
      sessionId: string;
      reason: string;
    }
  | {
      /**
       * Fired after the DELETE /sessions/:id route has removed the
       * session row, its artifacts, and the on-disk bytes. The SSE
       * filter uses `userId` to deliver only to subscribers who
       * previously had access — the session is gone from the store by
       * the time the event fires, so we can't re-check ownership
       * against it.
       */
      type: "session.deleted";
      sessionId: string;
      userId: string | null;
    };

/**
 * Tiny typed wrapper around node:events. The dashboard's SSE endpoint
 * subscribes to this and forwards events to all connected browsers.
 *
 * We don't buffer — late subscribers do not get historical events.
 * Persistent recovery is the SessionStore's job (the dashboard queries
 * /sessions to repopulate on connect, then listens for live updates).
 */
export class IngestEvents {
  private readonly emitter = new EventEmitter({ captureRejections: false });

  constructor() {
    // Each SSE connection is one listener. 50 dashboards on one server
    // is unusual but not insane; bump the limit so we don't get noisy
    // "MaxListenersExceededWarning".
    this.emitter.setMaxListeners(64);
  }

  emit(event: IngestEvent): void {
    this.emitter.emit("event", event);
  }

  subscribe(handler: (event: IngestEvent) => void): () => void {
    this.emitter.on("event", handler);
    return () => this.emitter.off("event", handler);
  }
}
