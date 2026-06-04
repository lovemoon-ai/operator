import { useCallback, useEffect, useState } from "react";

import type { SessionRecord } from "../../types.js";
import { fmtBytes, fmtDate } from "./format.js";
import { useIngestEvents } from "./useIngestEvents.js";

export interface SessionDetailProps {
  apiBase: string;
  sessionId: string | null | undefined;
  /** Renders this when sessionId is null. */
  emptyState?: React.ReactNode;
}

/**
 * Inspect a single session: metadata, artifacts (with download links),
 * and parsed manifest. Refreshes when SSE reports the active session
 * has been updated (e.g. after the media artifact finalizes following
 * the manifest).
 */
export function SessionDetail(props: SessionDetailProps) {
  const { apiBase, sessionId, emptyState } = props;
  const [session, setSession] = useState<SessionRecord | null>(null);
  const [error, setError] = useState<string | null>(null);

  const refresh = useCallback(async () => {
    if (!sessionId) {
      setSession(null);
      return;
    }
    try {
      const r = await fetch(`${apiBase.replace(/\/+$/, "")}/sessions/${encodeURIComponent(sessionId)}`);
      if (r.status === 404) {
        setSession(null);
        setError("Session not found.");
        return;
      }
      if (!r.ok) throw new Error(`HTTP ${r.status}`);
      setSession((await r.json()) as SessionRecord);
      setError(null);
    } catch (err) {
      setError(String(err));
    }
  }, [apiBase, sessionId]);

  useEffect(() => {
    refresh();
  }, [refresh]);

  useIngestEvents(apiBase, (ev) => {
    if (ev.type === "session.updated" && ev.session.id === sessionId) refresh();
  });

  if (!sessionId) {
    return <>{emptyState ?? <div className="ego-empty">Select a session.</div>}</>;
  }
  if (error) {
    return <div className="ego-error">{error}</div>;
  }
  if (!session) {
    return <div className="ego-empty">Loading…</div>;
  }

  const artifacts = Object.entries(session.artifacts);

  return (
    <div className="ego-session-detail">
      <dl style={{ display: "grid", gridTemplateColumns: "140px 1fr", gap: "4px 16px", margin: 0 }}>
        <dt style={{ opacity: 0.7 }}>Session ID</dt>
        <dd style={{ margin: 0, fontFamily: "ui-monospace, monospace", fontSize: 12 }}>{session.id}</dd>
        <dt style={{ opacity: 0.7 }}>Received</dt>
        <dd style={{ margin: 0, fontSize: 12 }}>{fmtDate(session.receivedAt)}</dd>
        <dt style={{ opacity: 0.7 }}>Total size</dt>
        <dd style={{ margin: 0, fontSize: 12 }}>{fmtBytes(session.totalBytes)}</dd>
      </dl>

      <h3 style={{ fontSize: 12, textTransform: "uppercase", letterSpacing: "0.04em", opacity: 0.7, margin: "16px 0 8px" }}>
        Artifacts
      </h3>
      <ul className="ego-artifact-list" style={{ listStyle: "none", margin: 0, padding: 0, display: "flex", flexDirection: "column", gap: 6 }}>
        {artifacts.map(([kind, a]) => {
          const href = `${apiBase.replace(/\/+$/, "")}/sessions/${encodeURIComponent(session.id)}/artifacts/${encodeURIComponent(kind)}`;
          return (
            <li
              key={kind}
              className="ego-artifact"
              style={{ display: "flex", alignItems: "center", gap: 12, padding: "8px 10px", background: "rgba(255,255,255,0.04)", borderRadius: 6 }}
            >
              <strong style={{ minWidth: 80, fontSize: 12 }}>{kind}</strong>
              <span style={{ flex: 1, fontFamily: "ui-monospace, monospace", fontSize: 11, opacity: 0.7, overflow: "hidden", textOverflow: "ellipsis", whiteSpace: "nowrap" }}>
                {a.filename || "(unnamed)"}
              </span>
              <span style={{ fontSize: 11, opacity: 0.7 }}>{fmtBytes(a.bytes)}</span>
              <a href={href} style={{ fontSize: 12 }}>download</a>
            </li>
          );
        })}
      </ul>

      {session.manifest ? (
        <details style={{ marginTop: 16 }}>
          <summary style={{ cursor: "pointer", fontSize: 12, opacity: 0.7, textTransform: "uppercase", letterSpacing: "0.04em" }}>
            manifest.json
          </summary>
          <pre style={{ background: "rgba(255,255,255,0.04)", borderRadius: 6, padding: 10, fontSize: 11, overflow: "auto", maxHeight: 240, marginTop: 8 }}>
            {JSON.stringify(session.manifest, null, 2)}
          </pre>
        </details>
      ) : null}
    </div>
  );
}
