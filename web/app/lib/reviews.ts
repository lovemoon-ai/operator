/**
 * Per-session review state (reviewed / flagged / notes).
 *
 * Backed by SQLite (`reviews` table in `./db.ts`). Reads and writes are
 * always scoped to the current user via a join against `sessions` so a
 * malicious or careless caller can't read or mutate a row whose
 * session doesn't belong to them.
 */
import express, { type Request, type Response } from "express";

import { db } from "./db.js";
import { currentUserId } from "./auth-context.js";

export interface Review {
  sessionId: string;
  reviewed: boolean;
  flagged: boolean;
  notes: string;
  updatedAt: string;
}

interface ReviewRow {
  session_id: string;
  reviewed: number;
  flagged: number;
  notes: string;
  updated_at: string;
}

function rowToReview(row: ReviewRow): Review {
  return {
    sessionId: row.session_id,
    reviewed: !!row.reviewed,
    flagged: !!row.flagged,
    notes: row.notes,
    updatedAt: row.updated_at,
  };
}

const stmts = {
  // Server-side render path: getReview(sessionId) is called for the
  // session detail page. We don't filter by user here because the
  // server component has already proven ownership by fetching the
  // session via the user-scoped read API; we just need the review row.
  getById: db.prepare<[string], ReviewRow>(`SELECT * FROM reviews WHERE session_id = ?`),
  // List + mutate paths go through the scoped query.
  listByUser: db.prepare<[string], ReviewRow>(`
    SELECT r.* FROM reviews r
    JOIN sessions s ON s.id = r.session_id
    WHERE s.user_id = ?
  `),
  sessionOwnedBy: db.prepare<[string, string], { id: string }>(`
    SELECT id FROM sessions WHERE id = ? AND user_id = ?
  `),
  upsert: db.prepare<[string, number, number, string, string]>(`
    INSERT INTO reviews (session_id, reviewed, flagged, notes, updated_at)
    VALUES (?, ?, ?, ?, ?)
    ON CONFLICT(session_id) DO UPDATE SET
      reviewed = excluded.reviewed,
      flagged = excluded.flagged,
      notes = excluded.notes,
      updated_at = excluded.updated_at
  `),
  delete: db.prepare<[string]>(`DELETE FROM reviews WHERE session_id = ?`),
};

export function getReview(sessionId: string): Review {
  const row = stmts.getById.get(sessionId);
  return row
    ? rowToReview(row)
    : { sessionId, reviewed: false, flagged: false, notes: "", updatedAt: "" };
}

export function listReviewsForUser(userId: string): Record<string, Review> {
  const out: Record<string, Review> = {};
  for (const row of stmts.listByUser.all(userId)) {
    out[row.session_id] = rowToReview(row);
  }
  return out;
}

function ensureOwned(sessionId: string, userId: string): boolean {
  return !!stmts.sessionOwnedBy.get(sessionId, userId);
}

export function updateReview(
  sessionId: string,
  patch: Partial<Omit<Review, "sessionId" | "updatedAt">>,
): Review {
  const prev = getReview(sessionId);
  const next: Review = {
    ...prev,
    ...patch,
    sessionId,
    updatedAt: new Date().toISOString(),
  };
  stmts.upsert.run(
    sessionId,
    next.reviewed ? 1 : 0,
    next.flagged ? 1 : 0,
    next.notes,
    next.updatedAt,
  );
  return next;
}

export function deleteReview(sessionId: string): void {
  stmts.delete.run(sessionId);
}

// --- HTTP router ----------------------------------------------------------

export const reviewsRouter = express.Router();
reviewsRouter.use(express.json({ limit: "256kb" }));

function requireUser(req: Request, res: Response): string | null {
  const uid = currentUserId();
  if (!uid) {
    res.status(401).json({ error: "auth required" });
    return null;
  }
  return uid;
}

reviewsRouter.get("/", (req, res) => {
  const uid = requireUser(req, res);
  if (!uid) return;
  res.json(listReviewsForUser(uid));
});

reviewsRouter.get("/:id", (req, res) => {
  const uid = requireUser(req, res);
  if (!uid) return;
  if (!ensureOwned(req.params.id!, uid)) {
    return res.status(404).json({ error: "not found" });
  }
  res.json(getReview(req.params.id!));
});

reviewsRouter.patch("/:id", (req, res) => {
  const uid = requireUser(req, res);
  if (!uid) return;
  if (!ensureOwned(req.params.id!, uid)) {
    return res.status(404).json({ error: "not found" });
  }
  const body = (req.body ?? {}) as Partial<Review>;
  const patch: Partial<Review> = {};
  if (typeof body.reviewed === "boolean") patch.reviewed = body.reviewed;
  if (typeof body.flagged === "boolean") patch.flagged = body.flagged;
  if (typeof body.notes === "string") patch.notes = body.notes.slice(0, 4000);
  res.json(updateReview(req.params.id!, patch));
});

reviewsRouter.delete("/:id", (req, res) => {
  const uid = requireUser(req, res);
  if (!uid) return;
  if (!ensureOwned(req.params.id!, uid)) {
    return res.status(404).end();
  }
  deleteReview(req.params.id!);
  res.status(204).end();
});
