"use client";

import { useCallback, useEffect, useRef, useState } from "react";
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
  // `removing` is the in-flight session id; we disable that one row's
  // button (instead of locking the whole list) so a user can fire two
  // deletes in parallel without one blocking the other.
  const [removing, setRemoving] = useState<string | null>(null);
  // In-place two-stage confirm: first click flips the row's button
  // from "Remove" → "Remove?", second click within the timeout window
  // actually fires the DELETE. Beats a modal popup that interrupts
  // scanning down the list. Only one row can be in this state at a
  // time — clicking a different row's button cancels the previous.
  const [confirmingId, setConfirmingId] = useState<string | null>(null);
  const confirmTimerRef = useRef<ReturnType<typeof setTimeout> | null>(null);
  const CONFIRM_WINDOW_MS = 4000;

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

  // Clear any pending confirm timer. We hand-roll the timeout
  // (vs. useEffect with a deps array) because we need to reset it on
  // every click — not just on state changes.
  const cancelConfirmTimer = useCallback(() => {
    if (confirmTimerRef.current) {
      clearTimeout(confirmTimerRef.current);
      confirmTimerRef.current = null;
    }
  }, []);

  // Unmount-safe: drop any pending timer when the list goes away.
  useEffect(() => () => cancelConfirmTimer(), [cancelConfirmTimer]);

  const doRemove = useCallback(
    async (s: SessionRecord) => {
      setRemoving(s.id);
      // Optimistic-ish: we still wait for the server's 204 before
      // dropping the row, because surface-level deletion that turns
      // into a 401/500 leaves the list in a fake state the user can't
      // recover from without a refresh.
      try {
        const resp = await fetch(
          `${apiBase}/sessions/${encodeURIComponent(s.id)}`,
          { method: "DELETE", credentials: "include" },
        );
        if (resp.status === 204) {
          setItems((prev) => prev.filter((it) => it.id !== s.id));
          setReviews((prev) => {
            if (!prev[s.id]) return prev;
            const { [s.id]: _gone, ...rest } = prev;
            return rest;
          });
        } else {
          window.alert(`Delete failed: ${resp.status} ${resp.statusText}`);
        }
      } catch (err) {
        window.alert(`Delete failed: ${(err as Error).message}`);
      } finally {
        setRemoving((cur) => (cur === s.id ? null : cur));
      }
    },
    [apiBase],
  );

  const onRemoveClick = useCallback(
    (s: SessionRecord) => {
      // Second click on the SAME row → fire the delete. Anything else
      // — first click on this row, or click on a different row while
      // another was armed — re-arms confirm on this row.
      if (confirmingId === s.id) {
        cancelConfirmTimer();
        setConfirmingId(null);
        void doRemove(s);
        return;
      }
      cancelConfirmTimer();
      setConfirmingId(s.id);
      confirmTimerRef.current = setTimeout(() => {
        setConfirmingId((cur) => (cur === s.id ? null : cur));
        confirmTimerRef.current = null;
      }, CONFIRM_WINDOW_MS);
    },
    [confirmingId, doRemove, cancelConfirmTimer],
  );

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
        const isRemoving = removing === s.id;
        const isConfirming = confirmingId === s.id;
        return (
          <li key={s.id} className="session-row">
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
            <button
              type="button"
              className={`row-remove${isConfirming ? " row-remove--confirming" : ""}`}
              onClick={() => onRemoveClick(s)}
              disabled={isRemoving}
              aria-label={
                isConfirming
                  ? `Confirm removal of ${s.id}`
                  : `Remove session ${s.id}`
              }
              title={
                isConfirming
                  ? "Click again to confirm — auto-cancels in 4s"
                  : "Remove session and all its data"
              }
            >
              {isRemoving
                ? "Removing…"
                : isConfirming
                  ? "Remove?"
                  : "Remove"}
            </button>
          </li>
        );
      })}
    </ul>
  );
}
