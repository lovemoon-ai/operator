"use client";

import { useRouter } from "next/navigation";
import { useEffect } from "react";

interface Props {
  sessionId: string;
  /** SSE endpoint base, default `/api/ingest-read`. */
  apiBase?: string;
}

/**
 * Subscribes to the ingest SSE stream and triggers `router.refresh()`
 * whenever the session we're viewing gets an update — so the page
 * picks up new artifacts (preview.mp4 → session.rrd → …) as soon as
 * each post-ingest worker finishes, without the user having to F5.
 *
 * The stream emits four event types (see ego-ingest/src/events.ts):
 *   resource.created / resource.progress / resource.finalized / session.updated
 *
 * Only `session.updated` actually changes what the page would render
 * (new artifact in the map), so that's the only one we react to. The
 * other three fire ~once per artifact PATCH and we'd just thrash
 * Next's cache for no visible change.
 *
 * EventSource auto-reconnects on transport errors, so a brief server
 * restart doesn't leave the page stuck — the next reconnect will
 * deliver any session.updated emitted while we were disconnected.
 */
export function SessionLiveRefresh({
  sessionId,
  apiBase = "/api/ingest-read",
}: Props) {
  const router = useRouter();

  useEffect(() => {
    const es = new EventSource(`${apiBase}/events`);

    const onSessionUpdated = (raw: MessageEvent) => {
      try {
        const evt = JSON.parse(raw.data) as { session?: { id?: string } };
        if (evt.session?.id === sessionId) {
          router.refresh();
        }
      } catch {
        /* malformed event payload — ignore */
      }
    };

    es.addEventListener("session.updated", onSessionUpdated);
    return () => {
      es.removeEventListener("session.updated", onSessionUpdated);
      es.close();
    };
  }, [sessionId, apiBase, router]);

  return null;
}
