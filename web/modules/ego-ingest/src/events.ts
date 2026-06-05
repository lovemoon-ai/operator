import { EventEmitter } from "node:events";

import type { ResourceRecord, SessionRecord } from "./types.js";

export type IngestEvent =
  | { type: "resource.created"; resource: ResourceRecord }
  | { type: "resource.progress"; resourceId: string; offset: number; uploadLength: number }
  | { type: "resource.finalized"; resourceId: string; sessionId: string }
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
