"use client";

import { useRouter } from "next/navigation";
import { useState, useTransition } from "react";

import { fmtDate } from "@/lib/format";
import type { Review } from "@/lib/reviews";

interface Props {
  sessionId: string;
  initial: Review;
}

/**
 * The review form. Sends PATCH /api/reviews/:id on every save and a
 * DELETE /api/ingest-read/sessions/:id on "delete session" (which the
 * read API doesn't implement yet — for v1 we just nuke the review
 * record + warn the user; full session-purge from disk is a follow-up).
 */
export function ReviewForm({ sessionId, initial }: Props) {
  const router = useRouter();
  const [reviewed, setReviewed] = useState(initial.reviewed);
  const [flagged, setFlagged] = useState(initial.flagged);
  const [notes, setNotes] = useState(initial.notes);
  const [status, setStatus] = useState<string>(initial.updatedAt ? `Last saved ${fmtDate(initial.updatedAt)}` : "");
  const [pending, startTransition] = useTransition();

  async function save() {
    setStatus("Saving…");
    const r = await fetch(`/api/reviews/${encodeURIComponent(sessionId)}`, {
      method: "PATCH",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify({ reviewed, flagged, notes }),
    });
    if (!r.ok) {
      setStatus(`Save failed: HTTP ${r.status}`);
      return;
    }
    const updated = (await r.json()) as Review;
    setStatus(`Saved ${fmtDate(updated.updatedAt)}`);
    startTransition(() => router.refresh());
  }

  async function clearReview() {
    if (!confirm("Clear review state? This only deletes the notes/flags — the recording stays.")) return;
    const r = await fetch(`/api/reviews/${encodeURIComponent(sessionId)}`, { method: "DELETE" });
    if (!r.ok) {
      setStatus(`Delete failed: HTTP ${r.status}`);
      return;
    }
    setReviewed(false);
    setFlagged(false);
    setNotes("");
    setStatus("Review cleared.");
    startTransition(() => router.refresh());
  }

  return (
    <div style={{ display: "grid", gap: 12 }}>
      <div style={{ display: "flex", gap: 16, flexWrap: "wrap" }}>
        <label style={{ display: "flex", alignItems: "center", gap: 6 }}>
          <input
            type="checkbox"
            checked={reviewed}
            onChange={(e) => setReviewed(e.target.checked)}
            style={{ width: "auto" }}
          />
          <span>Reviewed</span>
        </label>
        <label style={{ display: "flex", alignItems: "center", gap: 6 }}>
          <input
            type="checkbox"
            checked={flagged}
            onChange={(e) => setFlagged(e.target.checked)}
            style={{ width: "auto" }}
          />
          <span>Flagged</span>
        </label>
      </div>

      <label style={{ display: "grid", gap: 4 }}>
        <span style={{ fontSize: 12, color: "var(--muted)" }}>Notes</span>
        <textarea
          value={notes}
          onChange={(e) => setNotes(e.target.value)}
          placeholder="What went wrong / right? What downstream pipeline should pick this up?"
        />
      </label>

      <div className="button-row">
        <button type="button" className="primary" onClick={save} disabled={pending}>
          Save
        </button>
        <button type="button" className="danger" onClick={clearReview} disabled={pending}>
          Clear review
        </button>
        <span style={{ alignSelf: "center", fontSize: 12, color: "var(--muted)" }}>{status}</span>
      </div>
    </div>
  );
}
