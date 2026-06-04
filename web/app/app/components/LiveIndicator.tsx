"use client";

import { useEffect, useState } from "react";

/**
 * Tiny header indicator that turns green while the ingest SSE stream
 * is connected. The same EventSource also drives router refresh on
 * `session.updated` so server components re-render when new uploads
 * arrive without the user pressing reload.
 */
export function LiveIndicator({ apiBase }: { apiBase: string }) {
  const [connected, setConnected] = useState(false);

  useEffect(() => {
    let es: EventSource | null = null;
    let cancelled = false;
    let backoff = 1000;
    const open = () => {
      if (cancelled) return;
      es = new EventSource(`${apiBase.replace(/\/+$/, "")}/events`);
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
      es.addEventListener("session.updated", () => {
        // Cheap, app-wide refresh. With many concurrent uploads this
        // would thrash — for v1 a single uploading headset, it's fine.
        // Swap for a per-route mutate() call if you scale up.
        window.dispatchEvent(new CustomEvent("ego:refresh"));
      });
    };
    open();
    return () => {
      cancelled = true;
      es?.close();
    };
  }, [apiBase]);

  return (
    <span className="live" data-connected={connected ? "true" : "false"}>
      {connected ? "live" : "offline"}
    </span>
  );
}
