"use client";

import { useCallback, useEffect, useState } from "react";
import type { SessionRecord } from "@love-moon/ego-ingest";

import { fmtBytes, fmtRelative } from "@/lib/format";
import type { Review } from "@/lib/reviews";

interface Props {
  apiBase: string;
  reviewsBase: string;
}

interface ListPage { items: SessionRecord[]; nextCursor: string | null }

/**
 * Live-refreshing session list. Calls the read API on mount, then
 * re-fetches whenever the layout's LiveIndicator broadcasts an
 * "ego:refresh" event (which it does on every `session.updated` SSE).
 */
export function SessionList({ apiBase, reviewsBase }: Props) {
  const [items, setItems] = useState<SessionRecord[]>([]);
  const [reviews, setReviews] = useState<Record<string, Review>>({});
  const [loading, setLoading] = useState(true);

  const refresh = useCallback(async () => {
    try {
      const [sessRes, revRes] = await Promise.all([
        fetch(`${apiBase}/sessions?limit=200`),
        fetch(reviewsBase),
      ]);
      if (sessRes.ok) {
        const page = (await sessRes.json()) as ListPage;
        setItems(page.items);
      }
      if (revRes.ok) {
        setReviews((await revRes.json()) as Record<string, Review>);
      }
    } catch {
      /* leave previous data on transient error */
    } finally {
      setLoading(false);
    }
  }, [apiBase, reviewsBase]);

  useEffect(() => {
    refresh();
    const onTick = () => refresh();
    window.addEventListener("ego:refresh", onTick);
    return () => window.removeEventListener("ego:refresh", onTick);
  }, [refresh]);

  if (loading) {
    return <div className="empty-state">Loading sessions…</div>;
  }
  if (items.length === 0) {
    return (
      <div className="empty-state">
        No recordings yet.<br /><br />
        Point your XR headset's Upload URL at <code>/api/ingest</code>.
      </div>
    );
  }

  return (
    <ul className="session-list">
      {items.map((s) => {
        const review = reviews[s.id];
        const isNew = !review;
        return (
          <li key={s.id}>
            <a className="row-link" href={`/sessions/${encodeURIComponent(s.id)}`}>
              <div style={{ display: "flex", alignItems: "center", gap: 8 }}>
                <span className="id">{s.id}</span>
                {isNew && <span className="badge new">new</span>}
                {review?.reviewed && <span className="badge reviewed">reviewed</span>}
                {review?.flagged && <span className="badge flagged">flagged</span>}
              </div>
              <div className="meta">
                <span>{fmtRelative(s.receivedAt)}</span>
                <span>{fmtBytes(s.totalBytes)}</span>
                <span>{Object.keys(s.artifacts).length} artifact{Object.keys(s.artifacts).length === 1 ? "" : "s"}</span>
              </div>
            </a>
          </li>
        );
      })}
    </ul>
  );
}
