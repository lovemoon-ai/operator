import { useEffect, useRef, useState } from "react";

import type { IngestEvent } from "../../events.js";

/**
 * Subscribe to live ingest events. The hook owns one EventSource
 * connection regardless of how many components mount it — but each
 * mount gets its own callback fan-out, so two `<SessionList />` in
 * the same tree both refresh on `session.updated`.
 *
 * Returns the connection status so the caller can render a "live"
 * dot, and the most recent event for components that just want to
 * pulse on every update.
 */
export function useIngestEvents(
  apiBase: string,
  handler?: (event: IngestEvent) => void,
): { connected: boolean; lastEvent: IngestEvent | null } {
  const [connected, setConnected] = useState(false);
  const [lastEvent, setLastEvent] = useState<IngestEvent | null>(null);
  // Stash handler in a ref so the EventSource doesn't reconnect every
  // render when the caller passes an inline arrow function.
  const handlerRef = useRef(handler);
  useEffect(() => {
    handlerRef.current = handler;
  }, [handler]);

  useEffect(() => {
    let es: EventSource | null = null;
    let backoff = 1000;
    let cancelled = false;
    const open = () => {
      if (cancelled) return;
      es = new EventSource(apiBase.replace(/\/+$/, "") + "/events");
      es.onopen = () => {
        backoff = 1000;
        setConnected(true);
      };
      es.onerror = () => {
        setConnected(false);
        es?.close();
        if (!cancelled) setTimeout(open, backoff);
        backoff = Math.min(backoff * 2, 30_000);
      };
      const dispatch = (ev: MessageEvent) => {
        try {
          const payload = JSON.parse(ev.data) as IngestEvent;
          setLastEvent(payload);
          handlerRef.current?.(payload);
        } catch {
          /* swallow parse errors — server is the source of truth */
        }
      };
      for (const t of ["resource.created", "resource.progress", "resource.finalized", "session.updated"]) {
        es.addEventListener(t, dispatch as EventListener);
      }
    };
    open();
    return () => {
      cancelled = true;
      es?.close();
    };
  }, [apiBase]);

  return { connected, lastEvent };
}
