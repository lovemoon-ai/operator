import { useCallback, useEffect, useState } from "react";

import type { SessionRecord } from "../../types.js";
import { fmtBytes, fmtDate } from "./format.js";
import { useIngestEvents } from "./useIngestEvents.js";

export interface SessionListProps {
  apiBase: string;
  /** Initial page size. Defaults to 50. */
  pageSize?: number;
  /** Called when the user picks a session. Pair with <SessionDetail/>. */
  onSelect?: (id: string) => void;
  /** Highlight this session id with the `data-active="true"` attribute. */
  activeId?: string;
  /** Custom className applied to the root <ul>. Inline styles still apply. */
  className?: string;
}

/**
 * Newest-first paginated list of received sessions. Refreshes on every
 * `session.updated` event from the ingest server's SSE stream.
 *
 * The component is headless — no CSS opinions beyond inline structural
 * styles. Wire your own design system by targeting `.ego-session-list`
 * and `.ego-session-row` (or by passing className).
 */
export function SessionList(props: SessionListProps) {
  const { apiBase, pageSize = 50, onSelect, activeId, className } = props;
  const [items, setItems] = useState<SessionRecord[]>([]);
  const [loading, setLoading] = useState(true);

  const refresh = useCallback(async () => {
    try {
      const r = await fetch(`${apiBase.replace(/\/+$/, "")}/sessions?limit=${pageSize}`);
      if (!r.ok) throw new Error(`HTTP ${r.status}`);
      const page = (await r.json()) as { items: SessionRecord[] };
      setItems(page.items);
    } catch {
      /* leave previous items in place on error */
    } finally {
      setLoading(false);
    }
  }, [apiBase, pageSize]);

  useEffect(() => {
    refresh();
  }, [refresh]);

  useIngestEvents(apiBase, (ev) => {
    if (ev.type === "session.updated") refresh();
  });

  if (loading && items.length === 0) {
    return <div className="ego-session-list ego-empty">Loading…</div>;
  }
  if (items.length === 0) {
    return <div className="ego-session-list ego-empty">No sessions yet.</div>;
  }

  return (
    <ul className={className ?? "ego-session-list"} style={{ listStyle: "none", margin: 0, padding: 0 }}>
      {items.map((s) => {
        const isActive = s.id === activeId;
        return (
          <li
            key={s.id}
            className="ego-session-row"
            data-active={isActive ? "true" : "false"}
            onClick={() => onSelect?.(s.id)}
            style={{
              padding: "8px 12px",
              borderBottom: "1px solid rgba(255,255,255,0.06)",
              cursor: onSelect ? "pointer" : "default",
              background: isActive ? "rgba(88,166,255,0.12)" : "transparent",
            }}
          >
            <div style={{ fontFamily: "ui-monospace, monospace", fontSize: 12 }}>{s.id}</div>
            <div style={{ fontSize: 11, opacity: 0.7, display: "flex", gap: 12 }}>
              <span>{fmtDate(s.receivedAt)}</span>
              <span>{fmtBytes(s.totalBytes)}</span>
              <span>{Object.keys(s.artifacts).length} artifact(s)</span>
            </div>
          </li>
        );
      })}
    </ul>
  );
}
